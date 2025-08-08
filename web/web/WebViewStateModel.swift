import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 히스토리 항목 구조체
struct HistoryEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    let url: URL
    var title: String
    let date: Date
    let navigationID: String
    
    enum CodingKeys: String, CodingKey {
        case id, url, title, date, navigationID
    }
    
    var debugDescription: String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return "[\(df.string(from: date))] \(url.absoluteString) (\(title), id: \(id.uuidString.prefix(6)))"
    }
}

// MARK: - 세션 스냅샷
struct WebViewSession: Codable {
    let history: [HistoryEntry]
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

// MARK: - WebViewStateModel
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID // let → var
    let navigationDidFinish = PassthroughSubject<Void, Never>()
    
    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL, oldValue != url, !isRestoringSession else { return }
            if !Thread.isMainThread {
                DispatchQueue.main.async { [weak self] in self?.currentURL = url }
                return
            }
            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            dbg("URL 업데이트 → \(url.absoluteString)")
            if !isInternalNavigation {
                updateHistoryStacks(with: url)
            }
        }
    }
    
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var showAVPlayer = false
    
    var historyURLs: [String] {
        virtualHistoryStack.map { $0.url.absoluteString }
    }
    
    var historyStack: [HistoryEntry] {
        virtualHistoryStack
    }
    
    var currentHistoryIndex: Int {
        virtualCurrentIndex
    }
    
    private var virtualHistoryStack: [HistoryEntry] = []
    private var virtualCurrentIndex: Int = -1
    private var legacyHistoryStack: [URL] = [] // historyStack → legacyHistoryStack
    private var currentIndexInStack: Int = -1
    private var isUsingVirtualHistory: Bool = true
    private var isInternalNavigation: Bool = false
    private var isNavigating: Bool = false
    private var navigationStartTime: TimeInterval = 0
    private var lastNavTapAt: TimeInterval = 0
    private let navTapMinInterval: TimeInterval = 0.3
    
    private(set) var isRestoringSession: Bool = false
    var pendingSession: WebViewSession?
    
    init(url: URL? = nil, tabID: UUID = UUID()) {
        self.tabID = tabID
        self.currentURL = url
        super.init()
        if let url = url {
            let entry = HistoryEntry(url: url, title: url.host ?? "제목 없음", date: Date(), navigationID: UUID().uuidString)
            virtualHistoryStack.append(entry)
            virtualCurrentIndex = 0
            legacyHistoryStack.append(url)
            currentIndexInStack = 0
            HistoryCacheManager.shared.cacheEntry(for: url, title: entry.title)
        }
    }
    
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
        if virtualCurrentIndex < virtualHistoryStack.count - 1 {
            virtualHistoryStack = Array(virtualHistoryStack.prefix(upTo: virtualCurrentIndex + 1))
        }
        let newEntry = HistoryEntry(url: url, title: url.host ?? "제목 없음", date: Date(), navigationID: UUID().uuidString)
        virtualHistoryStack.append(newEntry)
        virtualCurrentIndex = virtualHistoryStack.count - 1
        
        if currentIndexInStack < legacyHistoryStack.count - 1 {
            legacyHistoryStack = Array(legacyHistoryStack.prefix(upTo: currentIndexInStack + 1))
        }
        legacyHistoryStack.append(url)
        currentIndexInStack = legacyHistoryStack.count - 1
        
        updateNavigationButtons()
        let urlList = virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
        dbg("🧩 V-HIST 업데이트: idx=\(virtualCurrentIndex), stack=\(virtualHistoryStack.count) | entries=[\(urlList)]")
    }
    
    private func updateNavigationButtons() {
        canGoBack = virtualCurrentIndex > 0
        canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
        dbg("🧩 NAV 버튼 갱신: canGoBack=\(canGoBack), canGoForward=\(canGoForward), idx=\(virtualCurrentIndex), stackSize=\(virtualHistoryStack.count)")
    }
    
    func historyStackIfAny() -> [URL] {
        return virtualHistoryStack.map { $0.url }
    }
    
    func currentIndexInSafeBounds() -> Int {
        return max(0, min(virtualCurrentIndex, max(0, virtualHistoryStack.count - 1)))
    }
    
    private var kvURL: NSKeyValueObservation?
    private var kvIsLoading: NSKeyValueObservation?
    private var kvTitle: NSKeyValueObservation?
    
    private func removeObservers() {
        kvURL?.invalidate(); kvURL = nil
        kvIsLoading?.invalidate(); kvIsLoading = nil
        kvTitle?.invalidate(); kvTitle = nil
    }
    
    private func installObservers(on webView: WKWebView) {
        kvURL = webView.observe(\.url, options: [.new]) { [weak self] wv, change in
            guard let self = self, let url = wv.url, url.scheme != nil, url.absoluteString != "about:blank" else { return }
            DispatchQueue.main.async {
                if self.currentURL != url && !self.isRestoringSession {
                    self.isInternalNavigation = true
                    self.currentURL = url
                    self.isInternalNavigation = false
                }
            }
        }
        
        kvIsLoading = webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.updateNavigationButtons()
            }
        }
        
        kvTitle = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard let self = self, let url = wv.url else { return }
            DispatchQueue.main.async {
                if let index = self.virtualHistoryStack.firstIndex(where: { $0.url == url }) {
                    self.virtualHistoryStack[index].title = wv.title ?? url.host ?? "제목 없음"
                }
                HistoryCacheManager.shared.cacheEntry(for: url, title: wv.title ?? "")
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
                if let session = pendingSession {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.executeOptimizedRestore(session: session)
                    }
                }
            }
        }
    }
    
    var onLoadCompletion: (() -> Void)?
    
    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }
    
    func clearHistory() {
        WebViewStateModel.globalHistory = []
        WebViewStateModel.saveGlobalHistory()
        HistoryCacheManager.shared.clearCache()
        virtualHistoryStack = []
        virtualCurrentIndex = -1
        updateNavigationButtons()
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
    
    func saveSession() -> WebViewSession? {
        guard !virtualHistoryStack.isEmpty, virtualCurrentIndex >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 없음")
            return nil
        }
        let urlList = virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
        dbg("💾 세션 저장: \(virtualHistoryStack.count) 항목, 인덱스 \(virtualCurrentIndex) | entries=[\(urlList)]")
        return WebViewSession(history: virtualHistoryStack, currentIndex: virtualCurrentIndex)
    }
    
    func restoreSession(_ session: WebViewSession) {
        beginSessionRestore()
        
        let history = session.history.sorted { $0.date < $1.date }
        let targetIndex = max(0, min(session.currentIndex, history.count - 1))
        
        if !history.isEmpty && history.indices.contains(targetIndex) {
            virtualHistoryStack = history
            virtualCurrentIndex = targetIndex
            legacyHistoryStack = history.map { $0.url }
            currentIndexInStack = targetIndex
            
            let targetEntry = history[targetIndex]
            isInternalNavigation = true
            currentURL = targetEntry.url
            isInternalNavigation = false
            updateNavigationButtons()
            
            let urlList = history.map { $0.debugDescription }.joined(separator: ", ")
            dbg("🧭 RESTORE 준비: \(history.count) 항목, 목표 idx \(targetIndex) | entries=[\(urlList)]")
            
            if let webView = webView {
                executeOptimizedRestore(session: session)
            } else {
                pendingSession = session
            }
        } else {
            currentURL = nil
            finishSessionRestore()
            dbg("🧭 RESTORE 실패: 유효한 항목/인덱스 없음")
        }
    }
    
    private func executeOptimizedRestore(session: WebViewSession) {
        guard let webView = webView else {
            dbg("🧭 RESTORE 실행 실패: webView 없음")
            return
        }
        
        let history = session.history.sorted { $0.date < $1.date }
        let targetIndex = max(0, min(session.currentIndex, history.count - 1))
        guard history.indices.contains(targetIndex) else {
            dbg("🧭 RESTORE 실행 실패: 인덱스 범위 초과")
            finishSessionRestore()
            return
        }
        
        let targetEntry = history[targetIndex]
        isNavigating = true
        navigationStartTime = CACurrentMediaTime()
        
        dbg("🧭 RESTORE 실행: \(targetEntry.debugDescription)")
        
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
        
        webView.load(URLRequest(url: targetEntry.url))
        HistoryCacheManager.shared.cacheEntry(for: targetEntry.url, title: targetEntry.title)
    }
    
    func goBack() {
        guard !throttleTap(), !isNavigating, virtualCurrentIndex > 0, let webView = webView else {
            let urlList = virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
            dbg("⬅️ 가상 네비 실패: idx=\(virtualCurrentIndex), navigating=\(isNavigating), webView=\(webView != nil), stack=[\(urlList)]")
            return
        }
        
        virtualCurrentIndex -= 1
        let targetEntry = virtualHistoryStack[virtualCurrentIndex]
        isNavigating = true
        navigationStartTime = CACurrentMediaTime()
        
        isInternalNavigation = true
        currentURL = targetEntry.url
        isInternalNavigation = false
        
        webView.load(URLRequest(url: targetEntry.url))
        HistoryCacheManager.shared.cacheEntry(for: targetEntry.url, title: targetEntry.title)
        updateNavigationButtons()
        
        dbg("⬅️ V-NAV BACK → idx \(virtualCurrentIndex) (\(targetEntry.debugDescription))")
    }
    
    func goForward() {
        guard !throttleTap(), !isNavigating, virtualCurrentIndex < virtualHistoryStack.count - 1, let webView = webView else {
            let urlList = virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
            dbg("➡️ 가상 네비 실패: idx=\(virtualCurrentIndex)/\(virtualHistoryStack.count-1), navigating=\(isNavigating), webView=\(webView != nil), stack=[\(urlList)]")
            return
        }
        
        virtualCurrentIndex += 1
        let targetEntry = virtualHistoryStack[virtualCurrentIndex]
        isNavigating = true
        navigationStartTime = CACurrentMediaTime()
        
        isInternalNavigation = true
        currentURL = targetEntry.url
        isInternalNavigation = false
        
        webView.load(URLRequest(url: targetEntry.url))
        HistoryCacheManager.shared.cacheEntry(for: targetEntry.url, title: targetEntry.title)
        updateNavigationButtons()
        
        dbg("➡️ V-NAV FWD → idx \(virtualCurrentIndex) (\(targetEntry.debugDescription))")
    }
    
    func reload() {
        guard webView != nil else {
            dbg("🚫 reload 실패: webView 없음")
            return
        }
        NotificationCenter.default.post(name: .init("WebViewReload"), object: nil)
        dbg("🔄 reload 요청")
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
                let urlList = virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
                dbg("⬅️ 가상 네비: 뒤로가기 불가 (인덱스: \(virtualCurrentIndex), stack=[\(urlList)])")
                return
            }
            newIndex = virtualCurrentIndex - 1
        case .forward:
            guard virtualCurrentIndex < virtualHistoryStack.count - 1 else {
                NotificationCenter.default.post(name: .init("WebViewNavigationBlocked"),
                                               object: nil,
                                               userInfo: ["message": "앞으로 갈 페이지가 없습니다"])
                let urlList = virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
                dbg("➡️ 가상 네비: 앞으로가기 불가 (인덱스: \(virtualCurrentIndex)/\(virtualHistoryStack.count-1), stack=[\(urlList)])")
                return
            }
            newIndex = virtualCurrentIndex + 1
        }
        
        let targetEntry = virtualHistoryStack[newIndex]
        isNavigating = true
        navigationStartTime = CACurrentMediaTime()
        
        virtualCurrentIndex = newIndex
        updateNavigationButtons()
        
        dbg("🧩 V-NAV \(direction == .back ? "BACK" : "FWD") → idx \(newIndex) (\(targetEntry.debugDescription))")
        
        if webView.url == targetEntry.url {
            isNavigating = false
            navigationDidFinish.send(())
            dbg("🧩 V-NAV 스킵: 동일 URL")
        } else {
            isInternalNavigation = true
            currentURL = targetEntry.url
            isInternalNavigation = false
            webView.load(URLRequest(url: targetEntry.url))
            HistoryCacheManager.shared.cacheEntry(for: targetEntry.url, title: targetEntry.title)
        }
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        dbg("🌐 LOAD 시작 → \(webView.url?.absoluteString ?? "(pending)")")
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView
        
        if let url = webView.url, !isRestoringSession {
            if let index = virtualHistoryStack.firstIndex(where: { $0.url == url }) {
                virtualHistoryStack[index].title = webView.title ?? url.host ?? "제목 없음"
                dbg("🧩 V-HIST 제목 업데이트: \(virtualHistoryStack[index].debugDescription)")
            } else {
                if virtualCurrentIndex < virtualHistoryStack.count - 1 {
                    virtualHistoryStack = Array(virtualHistoryStack.prefix(upTo: virtualCurrentIndex + 1))
                }
                let newEntry = HistoryEntry(url: url, title: webView.title ?? url.host ?? "제목 없음", date: Date(), navigationID: UUID().uuidString)
                virtualHistoryStack.append(newEntry)
                virtualCurrentIndex = virtualHistoryStack.count - 1
                WebViewStateModel.globalHistory.append(newEntry)
                WebViewStateModel.saveGlobalHistory()
                legacyHistoryStack.append(url)
                currentIndexInStack = legacyHistoryStack.count - 1
                dbg("🧩 V-HIST 추가: \(newEntry.debugDescription)")
            }
        }
        
        updateNavigationButtons()
        
        if let url = webView.url {
            let title = webView.title ?? url.host ?? "제목 없음"
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
        let id = tabID.uuidString.prefix(6)
        let timestamp = ts()
        print("[\(timestamp)][\(id)] \(msg)")
    }
    
    func makeVideoScript() -> String {
        return """
        var videos = document.getElementsByTagName('video');
        for (var i = 0; i < videos.length; i++) {
            videos[i].addEventListener('click', function(e) {
                e.preventDefault();
                var src = this.currentSrc || this.src;
                if (src) {
                    window.webkit.messageHandlers.playVideo.postMessage(src);
                }
            });
        }
        """
    }
    
    func handleRefresh(_ webView: WKWebView) {
        webView.reload()
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
                state.dbg("HistoryPage: navigationDidFinish received")
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