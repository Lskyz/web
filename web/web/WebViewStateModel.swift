//
//  WebViewStateModel.swift (오류 수정 버전)
//  주요 수정사항:
//  1) KVO 옵저버 URL 옵셔널 처리 수정 (중복 언래핑 제거)
//  2) 누락된 헬퍼 메서드 추가 (historyStackIfAny, currentIndexInSafeBounds)
//  3) 경고 사항들 수정
//

import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 세션 스냅샷 (저장/복원에 사용)
struct WebViewSession: Codable {
    let urls: [URL]
    let currentIndex: Int
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

// MARK: - WebViewStateModel (수정 버전)
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID?
    let navigationDidFinish = PassthroughSubject<Void, Never>()

    // ✅ currentURL 중복 추가 방지 개선
    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL, oldValue != url else { return }
            
            if !Thread.isMainThread {
                DispatchQueue.main.async { [weak self] in self?.currentURL = url }
                return
            }

            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            dbg("URL 업데이트 → \(url.absoluteString)")

            // 세션 복원 중이면 히스토리 누적 방지
            if isRestoringSession { return }
            
            // ✅ URL 변경이 실제 새로운 페이지 로드에 의한 것인지 확인
            if !isInternalNavigation {
                updateHistoryStacks(with: url)
            }

            // 전역 히스토리 업데이트 (중복 방지)
            if WebViewStateModel.globalHistory.last?.url != url {
                WebViewStateModel.globalHistory.append(.init(url: url, title: url.host ?? "제목 없음", date: Date()))
                WebViewStateModel.saveGlobalHistory()
            }
        }
    }

    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var showAVPlayer = false

    // ====== 가상 히스토리 관리 ======
    private var virtualHistoryStack: [URL] = []
    private var virtualCurrentIndex: Int = -1
    internal var isUsingVirtualHistory: Bool = false
    
    // ✅ 내부 네비게이션 플래그 (중복 히스토리 추가 방지용)
    private var isInternalNavigation: Bool = false

    // ✅ 네비게이션 상태 관리 개선
    private var isNavigating: Bool = false
    private var navigationStartTime: TimeInterval = 0

    // ✅ 디바운스 시간 단축 (220ms → 100ms)
    private var lastNavTapAt: TimeInterval = 0
    private let navTapMinInterval: TimeInterval = 0.1 // 100ms로 단축

    // 지연 복원 세션
    var pendingSession: WebViewSession?

    // 기본 커스텀 히스토리
    private var historyStack: [URL] = []
    private var currentIndexInStack: Int = -1

    // 세션 복원 상태
    private(set) var isRestoringSession: Bool = false
    
    func beginSessionRestore() {
        isRestoringSession = true
        isNavigating = false
        dbg("🧭 RESTORE 시작")
    }
    
    func finishSessionRestore() {
        isRestoringSession = false
        isNavigating = false
        dbg("🧭 RESTORE 종료")
    }

    private func updateHistoryStacks(with url: URL) {
        if currentIndexInStack < historyStack.count - 1 {
            historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
        }
        historyStack.append(url)
        currentIndexInStack = historyStack.count - 1

        if isUsingVirtualHistory {
            if virtualCurrentIndex < virtualHistoryStack.count - 1 {
                virtualHistoryStack = Array(virtualHistoryStack.prefix(upTo: virtualCurrentIndex + 1))
            }
            virtualHistoryStack.append(url)
            virtualCurrentIndex = virtualHistoryStack.count - 1
            updateNavigationButtons()
            
            let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
            dbg("🧩 V-HIST 업데이트: idx=\(virtualCurrentIndex), stack=\(virtualHistoryStack.count) | urls=[\(urlList)]")
        }
    }
    
    private func updateNavigationButtons() {
        if isUsingVirtualHistory {
            canGoBack = virtualCurrentIndex > 0
            canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
        } else {
            if webView != nil {
                canGoBack = webView?.canGoBack ?? false
                canGoForward = webView?.canGoForward ?? false
            }
        }
    }

    func historyStackIfAny() -> [URL] {
        if isUsingVirtualHistory {
            return virtualHistoryStack
        }
        if let webView = webView {
            let back = webView.backForwardList.backList.map { $0.url }
            let current = webView.backForwardList.currentItem.map { [$0.url] } ?? []
            let forward = webView.backForwardList.forwardList.map { $0.url }
            return back + current + forward
        }
        return historyStack
    }
    
    func currentIndexInSafeBounds() -> Int {
        if isUsingVirtualHistory {
            return max(0, min(virtualCurrentIndex, max(0, virtualHistoryStack.count - 1)))
        }
        if let webView = webView { 
            return webView.backForwardList.backList.count 
        }
        return max(0, min(currentIndexInStack, max(0, historyStack.count - 1)))
    }

    // ====== KVO 관리 ======
    private var kvCanGoBack: NSKeyValueObservation?
    private var kvCanGoForward: NSKeyValueObservation?
    private var kvURL: NSKeyValueObservation?
    private var kvIsLoading: NSKeyValueObservation?
    private var kvTitle: NSKeyValueObservation?

    private func removeObservers() {
        kvCanGoBack?.invalidate(); kvCanGoBack = nil
        kvCanGoForward?.invalidate(); kvCanGoForward = nil
        kvURL?.invalidate(); kvURL = nil
        kvIsLoading?.invalidate(); kvIsLoading = nil
        kvTitle?.invalidate(); kvTitle = nil
    }

    private func installObservers(on webView: WKWebView) {
        kvCanGoBack = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if !self.isUsingVirtualHistory {
                    self.canGoBack = wv.canGoBack
                }
            }
        }
        
        kvCanGoForward = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if !self.isUsingVirtualHistory {
                    self.canGoForward = wv.canGoForward
                }
            }
        }
        
        // ✅ 수정된 URL KVO 옵저버 (중복 언래핑 제거)
        kvURL = webView.observe(\.url, options: [.new]) { [weak self] wv, change in
            guard let self = self else { return }
            guard let validURL = (change.newValue ?? wv.url) else { return }
            
            DispatchQueue.main.async {
                if validURL.scheme != nil,
                   validURL.absoluteString != "about:blank",
                   self.currentURL != validURL {
                    self.isInternalNavigation = true
                    self.currentURL = validURL
                    self.isInternalNavigation = false
                }
            }
        }
        
        kvIsLoading = webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            self?.updateNavigationButtons()
        }
        
        kvTitle = webView.observe(\.title, options: [.new]) { _, wv in
            if let u = wv.url {
                HistoryCacheManager.shared.cacheEntry(for: u, title: wv.title ?? "")
            }
        }
    }

    weak var webView: WKWebView? {
        didSet {
            if oldValue !== webView {
                removeObservers()
            }
            if let webView {
                dbg("🔗 webView 연결됨")
                installObservers(on: webView)
                updateNavigationButtons()
            }
            if webView != nil, let session = pendingSession {
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

    func clearHistory() {
        WebViewStateModel.globalHistory = []
        WebViewStateModel.saveGlobalHistory()
        HistoryCacheManager.shared.clearCache()
        dbg("🧹 전역 방문 기록 삭제")
    }

    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
        }
    }

    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
        }
    }

    // MARK: - 세션 저장/복원
    func saveSession() -> WebViewSession? {
        if isUsingVirtualHistory {
            guard !virtualHistoryStack.isEmpty, virtualCurrentIndex >= 0 else {
                dbg("💾 세션 저장 실패: 가상 히스토리 없음")
                return nil
            }
            let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
            dbg("💾 세션 저장(가상): \(virtualHistoryStack.count) URLs, 인덱스 \(virtualCurrentIndex) | urls=[\(urlList)]")
            return WebViewSession(urls: virtualHistoryStack, currentIndex: virtualCurrentIndex)
        }
        
        if webView != nil {
            let urls = historyURLs.compactMap { URL(string: $0) }
            let idx = currentHistoryIndex
            guard !urls.isEmpty, idx >= 0, idx < urls.count else {
                dbg("💾 세션 저장 실패: webView 히스토리 없음")
                return nil
            }
            dbg("💾 세션 저장(webView): \(urls.count) URLs, 인덱스 \(idx)")
            return WebViewSession(urls: urls, currentIndex: idx)
        }

        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 없음")
            return nil
        }
        dbg("💾 세션 저장(fallback): \(historyStack.count) URLs")
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    func restoreSession(_ session: WebViewSession) {
        beginSessionRestore()
        
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, urls.count - 1))
        
        if !urls.isEmpty && urls.indices.contains(targetIndex) {
            virtualHistoryStack = urls
            virtualCurrentIndex = targetIndex
            isUsingVirtualHistory = true
            
            historyStack = urls
            currentIndexInStack = targetIndex
            
            pendingSession = session
            
            isInternalNavigation = true
            currentURL = urls[targetIndex]
            isInternalNavigation = false
            
            updateNavigationButtons()
            
            let urlList = urls.map { $0.absoluteString }.joined(separator: ", ")
            dbg("🧭 RESTORE 준비: \(urls.count) URLs, 목표 idx \(targetIndex) | urls=[\(urlList)]")
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
        isNavigating = true
        navigationStartTime = CACurrentMediaTime()
        
        dbg("🧭 RESTORE 실행: \(targetURL.absoluteString)")
        
        onLoadCompletion = { [weak self] in
            guard let self = self else { return }
            
            self.virtualCurrentIndex = targetIndex
            self.updateNavigationButtons()
            
            if let url = webView.url {
                self.isInternalNavigation = true
                self.currentURL = url
                self.isInternalNavigation = false
            }
            
            self.isNavigating = false
            self.pendingSession = nil
            self.finishSessionRestore()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.navigationDidFinish.send(())
                self.dbg("🧭 RESTORE 완료")
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
        return max(0, min(currentIndexInStack, max(0, historyStack.count - 1)))
    }

    func goBack() {
        guard !throttleTap() else {
            dbg("⬅️ 뒤로가기 차단: 연속 탭")
            return
        }
        guard !isNavigating else {
            dbg("⬅️ 뒤로가기 차단: 네비게이션 진행 중")
            return
        }
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .back)
        } else {
            isNavigating = true
            navigationStartTime = CACurrentMediaTime()
            NotificationCenter.default.post(name: .init("WebViewGoBack"), object: nil)
            dbg("⬅️ 네이티브 뒤로가기 실행")
        }
    }

    func goForward() {
        guard !throttleTap() else {
            dbg("➡️ 앞으로가기 차단: 연속 탭")
            return
        }
        guard !isNavigating else {
            dbg("➡️ 앞으로가기 차단: 네비게이션 진행 중")
            return
        }
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .forward)
        } else {
            isNavigating = true
            navigationStartTime = CACurrentMediaTime()
            NotificationCenter.default.post(name: .init("WebViewGoForward"), object: nil)
            dbg("➡️ 네이티브 앞으로가기 실행")
        }
    }

    func reload() {
        NotificationCenter.default.post(name: .init("WebViewReload"), object: nil)
    }

    private func throttleTap() -> Bool {
        let now = CACurrentMediaTime()
        defer { lastNavTapAt = now }
        return (now - lastNavTapAt) < navTapMinInterval
    }

    private enum NavigationDirection { case back, forward }
    
    private func performVirtualNavigation(direction: NavigationDirection) {
        guard isUsingVirtualHistory, let webView = webView else {
            dbg("🧩 V-NAV 실패: 가상 히스토리 비활성 또는 webView 없음")
            return
        }
        
        let newIndex: Int
        switch direction {
        case .back:
            guard virtualCurrentIndex > 0 else {
                NotificationCenter.default.post(name: .init("WebViewNavigationBlocked"), 
                                               object: nil, 
                                               userInfo: ["message": "뒤로 갈 페이지가 없습니다"])
                dbg("⬅️ 가상 네비: 뒤로가기 불가 (인덱스: \(virtualCurrentIndex))")
                return
            }
            newIndex = virtualCurrentIndex - 1
        case .forward:
            guard virtualCurrentIndex < virtualHistoryStack.count - 1 else {
                NotificationCenter.default.post(name: .init("WebViewNavigationBlocked"), 
                                               object: nil, 
                                               userInfo: ["message": "앞으로 갈 페이지가 없습니다"])
                dbg("➡️ 가상 네비: 앞으로가기 불가 (인덱스: \(virtualCurrentIndex)/\(virtualHistoryStack.count-1))")
                return
            }
            newIndex = virtualCurrentIndex + 1
        }
        
        let targetURL = virtualHistoryStack[newIndex]
        isNavigating = true
        navigationStartTime = CACurrentMediaTime()
        
        virtualCurrentIndex = newIndex
        updateNavigationButtons()
        
        dbg("🧩 V-NAV \(direction == .back ? "BACK" : "FWD") → idx \(newIndex) (\(targetURL.absoluteString))")
        
        if webView.url == targetURL {
            isNavigating = false
            navigationDidFinish.send(())
            dbg("🧩 V-NAV 스킵: 동일 URL")
        } else {
            isInternalNavigation = true
            currentURL = targetURL
            isInternalNavigation = false
            webView.load(URLRequest(url: targetURL))
            HistoryCacheManager.shared.cacheEntry(for: targetURL)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        dbg("🌐 LOAD 시작 → \(webView.url?.absoluteString ?? "(pending)")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView

        if isUsingVirtualHistory && !isRestoringSession {
            let backList = webView.backForwardList.backList.map { $0.url }
            let currentItem = webView.backForwardList.currentItem?.url
            let forwardList = webView.backForwardList.forwardList.map { $0.url }
            let webViewHistory = backList + (currentItem.map { [$0] } ?? []) + forwardList
            if !webViewHistory.isEmpty && webViewHistory.count >= virtualHistoryStack.count {
                let oldCount = virtualHistoryStack.count
                virtualHistoryStack = webViewHistory
                virtualCurrentIndex = backList.count
                dbg("🧩 V-HIST 동기화: \(oldCount) → \(webViewHistory.count) URLs")
            }
        }
        
        updateNavigationButtons()
        
        if let url = webView.url {
            let title = (webView.title?.isEmpty == false) ? webView.title! : (url.host ?? "제목 없음")
            if !isRestoringSession && WebViewStateModel.globalHistory.last?.url != url {
                WebViewStateModel.globalHistory.append(.init(url: url, title: title, date: Date()))
                WebViewStateModel.saveGlobalHistory()
            }
            HistoryCacheManager.shared.cacheEntry(for: url, title: title)
            if currentURL != url {
                isInternalNavigation = true
                currentURL = url
                isInternalNavigation = false
            }
        }
        
        isNavigating = false
        let navigationTime = CACurrentMediaTime() - navigationStartTime
        dbg("🌐 LOAD 완료 → \(webView.url?.absoluteString ?? "nil") (소요시간: \(String(format: "%.3f", navigationTime))초)")
        
        onLoadCompletion?()
        onLoadCompletion = nil
        navigationDidFinish.send(())
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        dbg("❌ 로드 실패(Provisional): \(error.localizedDescription)")
        if isRestoringSession { finishSessionRestore() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        dbg("❌ 로드 실패(Navigation): \(error.localizedDescription)")
        if isRestoringSession { finishSessionRestore() }
    }

    func loadURLIfReady() {
        guard let webView = webView, let url = currentURL else {
            dbg("🚫 loadURLIfReady 실패: webView 또는 URL 없음")
            return
        }
        if webView.url != url {
            isNavigating = true
            navigationStartTime = CACurrentMediaTime()
            webView.load(URLRequest(url: url))
            HistoryCacheManager.shared.cacheEntry(for: url)
            dbg("🌐 loadURLIfReady: \(url.absoluteString)")
        }
    }

    private func dbg(_ msg: String) {
        let id = tabID?.uuidString.prefix(6) ?? "noTab"
        let timestamp = ts()
        print("[\(timestamp)][\(id)] \(msg)")
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
                print("HistoryPage: navigationDidFinish received")
            }
        }

        func delete(at offsets: IndexSet) {
            let items = filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
            WebViewStateModel.saveGlobalHistory()
        }
    }
}
