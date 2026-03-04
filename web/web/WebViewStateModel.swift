import Foundation
import Combine
import SwiftUI
import WebKit

fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

private var kvoContext = 0

// MARK: - WebViewStateModel
// 역할: UI 상태 관리 + 네비게이션 명령
// canGoBack/canGoForward는 WebKit KVO로 직접 관리 — 커스텀 배열 drift 없음
final class WebViewStateModel: NSObject, ObservableObject {
    var tabID: UUID?
    @Published var dataModel = WebViewDataModel()
    private var dataModelCancellable: AnyCancellable?

    @Published var isLoading: Bool = false
    @Published var loadingProgress: Double = 0.0
    @Published var currentPageTitle: String = ""

    let navigationDidFinish = PassthroughSubject<Void, Never>()
    var pendingInteractionStateData: Data?
    private var pendingURLToLoad: URL?

    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { pendingURLToLoad = nil; return }
            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            let shouldLoad = url != oldValue && !isNavigatingFromWebView
            if shouldLoad { pendingURLToLoad = url; loadURLIfReady() }
        }
    }

    internal var isNavigatingFromWebView: Bool = false

    // KVO 기반 — WebKit backForwardList가 단일 진실 공급원
    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }

    @Published var showAVPlayer = false

    @Published var isDesktopMode: Bool = false {
        didSet {
            guard oldValue != isDesktopMode, let webView = webView else { return }
            updateUserAgentIfNeeded(webView: webView, stateModel: self)
            webView.reload()
        }
    }

    @Published var currentZoomLevel: Double = 0.5 {
        didSet { if oldValue != currentZoomLevel { applyZoomLevel() } }
    }

    weak var webView: WKWebView? {
        didSet {
            oldValue?.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoBack))
            oldValue?.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoForward))

            if let webView = webView {
                webView.navigationDelegate = dataModel
                dataModel.stateModel = self
                webView.allowsBackForwardNavigationGestures = false

                webView.addObserver(self, forKeyPath: #keyPath(WKWebView.canGoBack),
                                    options: .new, context: &kvoContext)
                webView.addObserver(self, forKeyPath: #keyPath(WKWebView.canGoForward),
                                    options: .new, context: &kvoContext)
            }
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard context == &kvoContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    override init() {
        super.init()
        dataModel.tabID = tabID
        dataModel.stateModel = self
        dataModelCancellable = dataModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - 로딩 상태

    func handleLoadingStart() { isLoading = true }

    func handleLoadingFinish() {
        isLoading = false
        if isDesktopMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.applyZoomLevel() }
        }
    }

    func handleLoadingError() { isLoading = false }

    func syncCurrentURL(_ url: URL) {
        guard !isNavigatingFromWebView else { return }
        isNavigatingFromWebView = true
        currentURL = url
        isNavigatingFromWebView = false

        if let record = dataModel.findMetadataRecord(for: url) {
            syncCurrentPageTitle(record.title, fallbackURL: url)
        } else {
            syncCurrentPageTitle(nil, fallbackURL: url)
        }
    }

    func triggerNavigationFinished() { navigationDidFinish.send(()) }

    func syncCurrentPageTitle(_ title: String?, fallbackURL: URL? = nil) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedURL = fallbackURL ?? webView?.url ?? currentURL
        let safeTitle = trimmed.isEmpty ? (resolvedURL?.host ?? "제목 없음") : trimmed

        guard currentPageTitle != safeTitle else { return }
        currentPageTitle = safeTitle
    }

    // MARK: - 에러 알림

    func notifyError(_ error: Error, url: String) {
        guard let tabID = tabID else { return }
        NotificationCenter.default.post(name: Notification.Name("webViewDidFailLoad"), object: nil,
            userInfo: ["tabID": tabID.uuidString, "error": error, "url": url])
    }

    func notifyHTTPError(_ statusCode: Int, url: String) {
        guard let tabID = tabID else { return }
        NotificationCenter.default.post(name: Notification.Name("webViewDidFailLoad"), object: nil,
            userInfo: ["tabID": tabID.uuidString, "statusCode": statusCode, "url": url])
    }

    // MARK: - 네비게이션 (WebKit backForwardList 직접 사용)

    func goBack() {
        guard canGoBack, let webView = webView else { return }
        if let currentRecord = dataModel.currentPageRecord {
            if let tabID = tabID {
                BFCacheTransitionSystem.shared.captureSnapshot(
                    pageRecord: currentRecord, webView: webView, type: .forceUpdate, tabID: tabID
                )
            }
        }
        webView.goBack()
        dbg("⬅️ goBack()")
    }

    func goForward() {
        guard canGoForward, let webView = webView else { return }
        if let currentRecord = dataModel.currentPageRecord {
            if let tabID = tabID {
                BFCacheTransitionSystem.shared.captureSnapshot(
                    pageRecord: currentRecord, webView: webView, type: .forceUpdate, tabID: tabID
                )
            }
        }
        webView.goForward()
        dbg("➡️ goForward()")
    }

    func reload() { webView?.reload() }

    func stopLoading() {
        webView?.stopLoading()
        isLoading = false
    }

    func performQueuedRestore(to url: URL) {
        guard let webView = webView else { return }
        webView.load(URLRequest(url: url))
        dbg("🔄 복원 로드: \(url.absoluteString)")
    }

    // MARK: - 세션

    func saveSession() -> WebViewSession? {
        alignIDsIfNeeded()
        return dataModel.saveSession()
    }

    func restoreSession(_ session: WebViewSession) {
        dbg("🔄 세션 복원 시작")
        dataModel.restoreSession(session)
        if let currentRecord = dataModel.currentPageRecord {
            isNavigatingFromWebView = true
            currentURL = currentRecord.url
            isNavigatingFromWebView = false
        } else if let firstRecord = session.pageRecords.first {
            isNavigatingFromWebView = true
            currentURL = firstRecord.url
            isNavigatingFromWebView = false
        }
        dataModel.finishSessionRestore()
    }

    // MARK: - 다운로드

    func handleDownloadDecision(_ navigationResponse: WKNavigationResponse,
                                decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        shouldDownloadResponse(navigationResponse, decisionHandler: decisionHandler)
    }

    // MARK: - 데스크탑/줌

    func toggleDesktopMode() { isDesktopMode.toggle() }

    func setZoomLevel(_ level: Double) { currentZoomLevel = max(0.3, min(3.0, level)) }

    private func applyZoomLevel() {
        guard let webView = webView, isDesktopMode else { return }
        webView.evaluateJavaScript("if (window.setPageZoom) { window.setPageZoom(\(currentZoomLevel)); }")
    }

    // MARK: - 히스토리 점프 (WKBackForwardList 우선, fallback URL 로드)

    func navigateToHistoryRecord(_ record: PageRecord) {
        guard let webView = webView else { return }
        let allItems = webView.backForwardList.backList + webView.backForwardList.forwardList
        if let item = allItems.first(where: { $0.url == record.url }) {
            webView.go(to: item)
            dbg("⏪ 히스토리 점프 (BF): \(record.url.absoluteString)")
        } else {
            webView.load(URLRequest(url: record.url))
            dbg("⏪ 히스토리 점프 (URL fallback): \(record.url.absoluteString)")
        }
    }

    // MARK: - 히스토리 패스스루

    func updateCurrentPageTitle(_ title: String) {
        dataModel.updateCurrentPageTitle(title)
        syncCurrentPageTitle(title)
    }
    func clearHistory() { dataModel.clearHistory() }

    var currentPageRecord: PageRecord? { dataModel.currentPageRecord }
    var historyURLs: [String] { dataModel.historyURLs }
    var currentHistoryIndex: Int { dataModel.currentHistoryIndex }
    func historyStackIfAny() -> [URL] { dataModel.historyStackIfAny() }
    func currentIndexInSafeBounds() -> Int { dataModel.currentIndexInSafeBounds() }

    // MARK: - CustomWebView 인터페이스

    func setNavigatingFromWebView(_ value: Bool) { isNavigatingFromWebView = value }

    func handleDidCommitNavigation(_ webView: WKWebView) {
        _installCookieSyncIfNeeded(for: webView)
        CookieSyncManager.syncAppToWebView(webView, completion: nil)
    }

    func loadURLIfReady() {
        guard let targetURL = pendingURLToLoad ?? currentURL,
              let webView = webView else { return }
        if webView.url == targetURL && !webView.isLoading {
            pendingURLToLoad = nil; return
        }
        pendingURLToLoad = nil
        webView.load(URLRequest(url: targetURL))
        dbg("🌐 로드: \(targetURL.absoluteString)")
    }

    // MARK: - 유틸

    private func alignIDsIfNeeded() {
        if dataModel.tabID != tabID { dataModel.tabID = tabID }
    }

    private func dbg(_ msg: String) {
        let id = tabID.map { String($0.uuidString.prefix(6)) } ?? "noTab"
        let nav = "B:\(canGoBack ? "✅" : "❌") F:\(canGoForward ? "✅" : "❌")"
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(nav)] \(msg)")
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoBack))
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoForward))
    }
}

// MARK: - 쿠키 동기화
extension WebViewStateModel {
    func _installCookieSyncIfNeeded(for webView: WKWebView) {
        if _cookieSyncInstalledModels.contains(self) { return }
        _cookieSyncInstalledModels.add(self)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.add(self)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSHTTPCookieManagerCookiesChanged"),
            object: HTTPCookieStorage.shared, queue: .main
        ) { [weak webView] _ in
            guard let webView = webView else { return }
            CookieSyncManager.syncAppToWebView(webView, completion: nil)
        }
    }
}

extension WebViewStateModel: WKHTTPCookieStoreObserver {
    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        CookieSyncManager.syncWebToApp(cookieStore) {}
    }
}

private let _cookieSyncInstalledModels = NSHashTable<AnyObject>.weakObjects()
