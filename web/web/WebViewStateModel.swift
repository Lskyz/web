//
//  WebViewStateModel.swift
//  설명: WKWebView 상태/히스토리/세션 저장·복원(지연로드) 관리 + 상세 디버그 로그
//

import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 세션 스냅샷 (저장/복원에 사용)
struct WebViewSession: Codable {
    let urls: [URL]       // 히스토리 전체 (back + current + forward)
    let currentIndex: Int // 현재 위치(= backList.count)
}

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 히스토리 캐시 엔트리
private class HistoryCacheEntry {
    let url: URL
    var title: String
    var lastAccessed: Date
    weak var webView: WKWebView?
    
    init(url: URL, title: String = "") {
        self.url = url
        self.title = title
        self.lastAccessed = Date()
    }
    
    func updateAccess() { lastAccessed = Date() }
}

// MARK: - 히스토리 캐시 매니저
private class HistoryCacheManager {
    static let shared = HistoryCacheManager()
    private init() {}
    
    private var cache: [URL: HistoryCacheEntry] = [:]
    private let maxCacheCount = 200
    
    func cacheEntry(for url: URL, title: String = "") {
        if let entry = cache[url] {
            if !title.isEmpty { entry.title = title }
            entry.updateAccess()
        } else {
            cache[url] = HistoryCacheEntry(url: url, title: title)
            pruneIfNeeded()
        }
    }
    
    func entry(for url: URL) -> HistoryCacheEntry? { cache[url] }
    
    private func pruneIfNeeded() {
        guard cache.count > maxCacheCount else { return }
        let sorted = cache.values.sorted(by: { $0.lastAccessed < $1.lastAccessed })
        let toRemove = sorted.prefix(cache.count - maxCacheCount/2)
        for e in toRemove { cache.removeValue(forKey: e.url) }
    }
    
    func clearCache() { cache.removeAll() }
}

// MARK: - WebViewStateModel
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {

    var tabID: UUID?

    let navigationDidFinish = PassthroughSubject<Void, Never>()

    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }

            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            dbg("URL 업데이트 → \(url.absoluteString)")

            if isRestoringSession { return }

            // 커스텀 히스토리
            if currentIndexInStack < historyStack.count - 1 {
                historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
            }
            historyStack.append(url)
            currentIndexInStack = historyStack.count - 1

            // ✅ 가상 히스토리: 세부 주소 기록 보장
            if isUsingVirtualHistory {
                // 새로운 URL 추가 시 forward 항목 제거
                if virtualCurrentIndex < virtualHistoryStack.count - 1 {
                    virtualHistoryStack = Array(virtualHistoryStack.prefix(upTo: virtualCurrentIndex + 1))
                }
                // ✅ 중복 방지 로직 제거: 세부 주소를 항상 추가
                virtualHistoryStack.append(url)
                virtualCurrentIndex = virtualHistoryStack.count - 1
                // ✅ 버튼 상태 즉시 업데이트
                canGoBack = virtualCurrentIndex > 0
                canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
                let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
                dbg("🧩 V-HIST 업데이트: idx=\(virtualCurrentIndex), stack=\(virtualHistoryStack.count), canGoBack=\(canGoBack), canGoForward=\(canGoForward) | urls=[\(urlList)]")
            }

            WebViewStateModel.globalHistory.append(.init(url: url, title: url.host ?? "제목 없음", date: Date()))
            WebViewStateModel.saveGlobalHistory()
        }
    }

    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var showAVPlayer = false

    private var virtualHistoryStack: [URL] = []
    private var virtualCurrentIndex: Int = -1
    internal var isUsingVirtualHistory: Bool = false
    private var isNavigating: Bool = false

    var pendingSession: WebViewSession?

    private var historyStack: [URL] = []
    private var currentIndexInStack: Int = -1

    private(set) var isRestoringSession: Bool = false
    func beginSessionRestore() {
        isRestoringSession = true
        isNavigating = false
        dbg("🧭 RESTORE 시작 (가상히스토리 \(isUsingVirtualHistory ? "ON" : "OFF"))")
    }
    func finishSessionRestore() {
        isRestoringSession = false
        isNavigating = false
        dbg("🧭 RESTORE 종료 (가상히스토리 유지: \(isUsingVirtualHistory ? "ON" : "OFF"))")
    }

    weak var webView: WKWebView? {
        didSet {
            if let webView {
                dbg("🔗 webView 연결됨: canGoBack=\(webView.canGoBack) canGoForward=\(webView.canGoForward)")
            }
            if let _ = webView, let session = pendingSession {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.executeOptimizedRestore(session: session)
                }
            }
        }
    }

    var onLoadCompletion: (() -> Void)?

    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID()
        let url: URL
        let title: String
        let date: Date
    }

    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }

    private func addToHistory(url: URL, title: String) {
        WebViewStateModel.globalHistory.append(.init(url: url, title: title, date: Date()))
        WebViewStateModel.saveGlobalHistory()
    }

    func clearHistory() {
        WebViewStateModel.globalHistory = []
        WebViewStateModel.saveGlobalHistory()
        HistoryCacheManager.shared.clearCache()
        dbg("🧹 전역 방문 기록 삭제")
    }

    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
            TabPersistenceManager.debugMessages.append("[\(ts())] ☁️ 전역 방문 기록 저장: \(globalHistory.count)개")
        }
    }

    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
            TabPersistenceManager.debugMessages.append("[\(ts())] ☁️ 전역 방문 기록 로드: \(loaded.count)개")
        }
    }

    func saveSession() -> WebViewSession? {
        if let _ = webView {
            let urls = historyURLs.compactMap { URL(string: $0) }
            let idx = currentHistoryIndex
            guard !urls.isEmpty, idx >= 0, idx < urls.count else {
                dbg("💾 세션 저장 실패: webView 히스토리 없음")
                return nil
            }
            let urlList = urls.map { $0.absoluteString }.joined(separator: ", ")
            dbg("💾 세션 저장(webView): \(urls.count) URLs, 인덱스 \(idx) | urls=[\(urlList)]")
            return WebViewSession(urls: urls, currentIndex: idx)
        }

        if isUsingVirtualHistory {
            guard !virtualHistoryStack.isEmpty, virtualCurrentIndex >= 0 else {
                dbg("💾 세션 저장 실패: 가상 히스토리 없음")
                return nil
            }
            let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
            dbg("💾 세션 저장(가상): \(virtualHistoryStack.count) URLs, 인덱스 \(virtualCurrentIndex) | urls=[\(urlList)]")
            return WebViewSession(urls: virtualHistoryStack, currentIndex: virtualCurrentIndex)
        }

        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 또는 인덱스 없음")
            return nil
        }
        let urlList = historyStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("💾 세션 저장(fallback): \(historyStack.count) URLs, 인덱스 \(currentIndexInStack) | urls=[\(urlList)]")
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    func restoreSession(_ session: WebViewSession) {
        beginSessionRestore()
        
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, session.urls.count - 1))
        
        if !urls.isEmpty && urls.indices.contains(targetIndex) {
            virtualHistoryStack = urls
            virtualCurrentIndex = targetIndex
            isUsingVirtualHistory = true
            
            historyStack = urls
            currentIndexInStack = targetIndex
            
            pendingSession = session
            
            currentURL = urls[targetIndex]
            canGoBack = targetIndex > 0
            canGoForward = targetIndex < urls.count - 1
            let urlList = urls.map { $0.absoluteString }.joined(separator: ", ")
            dbg("🧭 RESTORE 준비: \(urls.count) URLs, 목표 idx \(targetIndex) | currentURL=\(urls[targetIndex].absoluteString) | canGoBack=\(canGoBack) canGoForward=\(canGoForward) | urls=[\(urlList)]")
        } else {
            currentURL = nil
            finishSessionRestore()
            dbg("🧭 RESTORE 실패: 유효한 URL/인덱스 없음")
        }
    }

    private func executeOptimizedRestore(session: WebViewSession) {
        guard let webView = webView else {
            dbg("🧭 RESTORE 실행 실패: webView 없음")
            return
        }
        
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, urls.count - 1))
        guard urls.indices.contains(targetIndex) else {
            dbg("🧭 RESTORE 실행 실패: 인덱스 범위 초과")
            finishSessionRestore()
            return
        }
        
        let targetURL = urls[targetIndex]
        currentURL = targetURL
        isNavigating = true
        let urlList = urls.map { $0.absoluteString }.joined(separator: ", ")
        dbg("🧭 RESTORE 실행: 마지막 페이지만 로드 → idx \(targetIndex) | \(targetURL.absoluteString) | currentURL=\(currentURL?.absoluteString ?? "nil") | canGoBack=\(canGoBack) canGoForward=\(canGoForward) | urls=[\(urlList)]")
        
        onLoadCompletion = { [weak self] in
            guard let self = self else { return }
            self.virtualCurrentIndex = targetIndex
            self.canGoBack = targetIndex > 0
            self.canGoForward = targetIndex < urls.count - 1
            if let url = webView.url {
                self.currentURL = url
            }
            self.isNavigating = false
            
            self.pendingSession = nil
            self.finishSessionRestore()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.navigationDidFinish.send(())
                let urlList = self.virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
                self.dbg("🧭 RESTORE 완료 신호 전송 (navigationDidFinish) | currentURL=\(self.currentURL?.absoluteString ?? "nil") | canGoBack=\(self.canGoBack) canGoForward=\(self.canGoForward) | urls=[\(urlList)]")
                self.logHistorySnapshot(reason: "RESTORE")
            }
        }
        
        webView.load(URLRequest(url: targetURL))
        HistoryCacheManager.shared.cacheEntry(for: targetURL)
    }

    var historyURLs: [String] {
        if isUsingVirtualHistory {
            return virtualHistoryStack.map { $0.absoluteString }
        }
        if let webView = webView {
            let back = webView.backForwardList.backList.map { $0.url.absoluteString }
            let current = webView.backForwardList.currentItem.map { [$0.url.absoluteString] } ?? []
            let forward = webView.backForwardList.forwardList.map { $0.url.absoluteString }
            return back + current + forward
        }
        return historyStack.map { $0.absoluteString }
    }

    var currentHistoryIndex: Int {
        if isUsingVirtualHistory {
            return max(0, min(virtualCurrentIndex, max(0, virtualHistoryStack.count - 1)))
        }
        if let webView = webView { return webView.backForwardList.backList.count }
        guard !historyStack.isEmpty,
              currentIndexInStack >= 0,
              currentIndexInStack < historyStack.count else { return 0 }
        return currentIndexInStack
    }

    func historyStackIfAny() -> [URL] {
        if isUsingVirtualHistory {
            return virtualHistoryStack
        }
        if let webView = webView {
            let back = webView.backForwardList.backList.map { $0.url }
            let current = webView.backForwardList.currentItem?.url
            let forward = webView.backForwardList.forwardList.map { $0.url }
            return back + (current.map { [$0] } ?? []) + forward
        }
        return historyStack
    }

    func currentIndexInSafeBounds() -> Int {
        if isUsingVirtualHistory {
            return max(0, min(virtualCurrentIndex, virtualHistoryStack.count - 1))
        }
        if let webView = webView { return webView.backForwardList.backList.count }
        guard !historyStack.isEmpty,
              currentIndexInStack >= 0,
              currentIndexInStack < historyStack.count else { return 0 }
        return currentIndexInStack
    }

    func goBack() {
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .back)
        } else {
            NotificationCenter.default.post(name: .init("WebViewGoBack"), object: nil)
        }
    }
    func goForward() {
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .forward)
        } else {
            NotificationCenter.default.post(name: .init("WebViewGoForward"), object: nil)
        }
    }
    func reload() { NotificationCenter.default.post(name: .init("WebViewReload"), object: nil) }

    private enum NavigationDirection { case back, forward }
    
    private func performVirtualNavigation(direction: NavigationDirection) {
        guard isUsingVirtualHistory, let webView = webView else {
            dbg("🧩 V-NAV 실패: 가상 히스토리 비활성 또는 webView 없음 | vhist=\(isUsingVirtualHistory) webView=\(webView != nil)")
            return
        }
        
        guard !isNavigating else {
            dbg("🧩 V-NAV 차단: 네비게이션 진행 중 | currentURL=\(currentURL?.absoluteString ?? "nil") | isNavigating=\(isNavigating)")
            return
        }
        
        let newIndex: Int
        switch direction {
        case .back:
            guard virtualCurrentIndex > 0 else {
                NotificationCenter.default.post(name: .init("WebViewNavigationBlocked"), object: nil, userInfo: ["message": "뒤로 갈 페이지가 없습니다"])
                let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
                dbg("⬅️ 가상 네비: 뒤로가기 불가 | vIndex=\(virtualCurrentIndex) | urls=[\(urlList)]")
                return
            }
            newIndex = virtualCurrentIndex - 1
        case .forward:
            guard virtualCurrentIndex < virtualHistoryStack.count - 1 else {
                NotificationCenter.default.post(name: .init("WebViewNavigationBlocked"), object: nil, userInfo: ["message": "앞으로 갈 페이지가 없습니다"])
                let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
                dbg("➡️ 가상 네비: 앞으로가기 불가 | vIndex=\(virtualCurrentIndex) vStack=\(virtualHistoryStack.count) | urls=[\(urlList)]")
                return
            }
            newIndex = virtualCurrentIndex + 1
        }
        
        let targetURL = virtualHistoryStack[newIndex]
        isNavigating = true
        currentURL = targetURL
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("🧩 V-NAV \(direction == .back ? "BACK" : "FWD") → idx \(newIndex) | \(targetURL.absoluteString) | currentURL=\(currentURL?.absoluteString ?? "nil") | canGoBack=\(canGoBack) canGoForward=\(canGoForward) | urls=[\(urlList)]")
        
        virtualCurrentIndex = newIndex
        canGoBack = virtualCurrentIndex > 0
        canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
        
        if webView.url != targetURL {
            webView.load(URLRequest(url: targetURL))
            HistoryCacheManager.shared.cacheEntry(for: targetURL)
        } else {
            isNavigating = false
            navigationDidFinish.send(())
            dbg("🧩 V-NAV 스킵: 동일 URL | targetURL=\(targetURL.absoluteString)")
        }
        
        let backList = Array(virtualHistoryStack.prefix(upTo: newIndex))
        let forwardList = Array(virtualHistoryStack.suffix(from: newIndex + 1))
        dbg("🧩 V-HIST SYNC: back=\(backList.count), forward=\(forwardList.count), current=\(targetURL.absoluteString) | urls=[\(urlList)]")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("🌐 LOAD 시작 → \(webView.url?.absoluteString ?? "(pending)") | restoring=\(isRestoringSession) vhist=\(isUsingVirtualHistory) | isNavigating=\(isNavigating) | urls=[\(urlList)]")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView
        
        // ✅ WKWebView의 backForwardList와 virtualHistoryStack 동기화
        if isUsingVirtualHistory {
            let backList = webView.backForwardList.backList.map { $0.url }
            let currentItem = webView.backForwardList.currentItem?.url
            let forwardList = webView.backForwardList.forwardList.map { $0.url }
            let webViewHistory = backList + (currentItem.map { [$0] } ?? []) + forwardList
            
            // ✅ 세부 주소 포함하도록 virtualHistoryStack 업데이트
            if !webViewHistory.isEmpty {
                virtualHistoryStack = webViewHistory
                virtualCurrentIndex = backList.count
                canGoBack = virtualCurrentIndex > 0
                canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
            }
        } else {
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
        }
        
        if let url = webView.url {
            currentURL = url
        }
        
        let title = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "제목 없음")
        
        if let finalURL = webView.url, !isRestoringSession {
            if WebViewStateModel.globalHistory.last?.url != finalURL {
                WebViewStateModel.globalHistory.append(.init(url: finalURL, title: title, date: Date()))
                WebViewStateModel.saveGlobalHistory()
                HistoryCacheManager.shared.cacheEntry(for: finalURL, title: title)
            }
        }
        
        isNavigating = false
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("🌐 LOAD 완료 → \(webView.url?.absoluteString ?? "nil") | restoring=\(isRestoringSession) vhist=\(isUsingVirtualHistory) | currentURL=\(currentURL?.absoluteString ?? "nil") | isNavigating=\(isNavigating) | canGoBack=\(canGoBack) canGoForward=\(canGoForward) | urls=[\(urlList)]")
        logHistorySnapshot(reason: "LOAD_FINISH")
        
        onLoadCompletion?()
        onLoadCompletion = nil
        
        navigationDidFinish.send(())
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("❌ 로드 실패(Provisional): \(error.localizedDescription) | isNavigating=\(isNavigating) | urls=[\(urlList)]")
        if isRestoringSession { finishSessionRestore() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("❌ 로드 실패(Navigation): \(error.localizedDescription) | isNavigating=\(isNavigating) | urls=[\(urlList)]")
        if isRestoringSession { finishSessionRestore() }
    }

    private func dbg(_ msg: String) {
        let id = tabID?.uuidString.prefix(6) ?? "noTab"
        let currentURLStr = currentURL?.absoluteString ?? "nil"
        let vHistCount = virtualHistoryStack.count
        let vIndex = virtualCurrentIndex
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)] \(msg) | currentURL=\(currentURLStr) | vHistory=\(vHistCount) | vIndex=\(vIndex) | isNavigating=\(isNavigating) | urls=[\(urlList)]")
    }

    private func logHistorySnapshot(reason: String) {
        if isUsingVirtualHistory {
            let list = virtualHistoryStack.map { $0.absoluteString }
            let idx = max(0, min(virtualCurrentIndex, max(0, list.count - 1)))
            let cur = list.indices.contains(idx) ? list[idx] : "(없음)"
            let urlList = list.joined(separator: ", ")
            dbg("🧩 V-HIST(\(reason)) ⏪\(idx) ▶︎\(max(0, list.count - idx - 1)) | \(cur) | urls=[\(urlList)]")
        } else if let wv = webView {
            let back = wv.backForwardList.backList.count
            let fwd = wv.backForwardList.forwardList.count
            let cur = wv.url?.absoluteString ?? "(없음)"
            let urlList = (wv.backForwardList.backList.map { $0.url.absoluteString } + [cur] + wv.backForwardList.forwardList.map { $0.url.absoluteString }).joined(separator: ", ")
            dbg("📜 H-HIST(\(reason)) ⏪\(back) ▶︎\(fwd) | \(cur) | urls=[\(urlList)]")
        } else {
            dbg("📜 HIST(\(reason)) 웹뷰 미연결")
        }
    }

    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel
        @State private var searchQuery: String = ""
        @Environment(\.dismiss) private var dismiss
        
        private var dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        private var filteredHistory: [HistoryEntry] {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return WebViewStateModel.globalHistory.sorted { $0.date > $1.date } }
            return WebViewStateModel.globalHistory
                .filter { $0.url.absoluteString.lowercased().contains(q) || $0.title.lowercased().contains(q) }
                .sorted { $0.date > $1.date }
        }

        init(state: WebViewStateModel) {
            self._state = ObservedObject(wrappedValue: state)
        }

        var body: some View {
            List {
                ForEach(filteredHistory) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title.isEmpty ? (item.url.host ?? "제목 없음") : item.title)
                            .font(.headline)
                        Text(item.url.absoluteString)
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(dateFormatter.string(from: item.date))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.currentURL = item.url
                        state.loadURLIfReady()
                        dismiss()
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("방문 기록")
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("모두 지우기") {
                        WebViewStateModel.globalHistory.removeAll()
                        WebViewStateModel.saveGlobalHistory()
                    }
                }
            }
            .onReceive(state.navigationDidFinish) { _ in
                print("HistoryPage: navigationDidFinish received, URL=\(state.currentURL?.absoluteString ?? "nil"), canGoBack=\(state.canGoBack), canGoForward=\(state.canGoForward)")
            }
        }

        func delete(at offsets: IndexSet) {
            let items = filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
            WebViewStateModel.saveGlobalHistory()
            TabPersistenceManager.debugMessages.append("[\(ts())] 🧹 방문 기록 삭제: \(targets.count)개")
        }
    }

    func loadURLIfReady() {
        guard let webView = webView, let url = currentURL else {
            dbg("🚫 loadURLIfReady 실패: webView 또는 URL 없음 | currentURL=\(currentURL?.absoluteString ?? "nil")")
            return
        }
        if webView.url != url {
            webView.load(URLRequest(url: url))
            HistoryCacheManager.shared.cacheEntry(for: url)
            let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
            dbg("🌐 loadURLIfReady: \(url.absoluteString) | urls=[\(urlList)]")
        }
    }
}