//
//  WebViewStateModel.swift
//  🎯 **단순화된 상태 관리 모델**
//  ✅ 복원 로직을 DataModel로 완전 이관
//  🚫 캐시 시스템 및 조용한 새로고침 제거
//  🔧 enum 기반 상태 관리로 단순화
//  📁 다운로드 관련 코드 헬퍼로 이관 완료
//  🎯 **BFCache 통합 - 제스처 로직 제거**
//  🔄 **BFCache 연동 개선 - 캐시 우선 복원**
//  🔧 **접근권한 수정 - public/internal 명시적 지정**
//

import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - WebViewStateModel (단순화된 상태 관리)
public final class WebViewStateModel: NSObject, ObservableObject {

    public var tabID: UUID?
    
    // ✅ 히스토리/세션 데이터 모델 참조
    @Published public var dataModel = WebViewDataModel()
    
    // ✨ 순수 UI 상태만
    @Published public var isLoading: Bool = false
    @Published public var loadingProgress: Double = 0.0
    
    public let navigationDidFinish = PassthroughSubject<Void, Never>()

    @Published public var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }

            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")

            // ✅ 웹뷰 로드 조건 단순화
            let shouldLoad = url != oldValue && 
                           !dataModel.restoreState.isActive &&
                           !isNavigatingFromWebView
            
            if shouldLoad {
                if let webView = webView {
                    webView.load(URLRequest(url: url))
                } else {
                    dbg("⚠️ 웹뷰가 없어서 로드 불가")
                }
            }
        }
    }
    
    // ✅ 웹뷰 내부 네비게이션 플래그 - 🔧 internal로 명시
    internal var isNavigatingFromWebView: Bool = false
    
    // 🎯 **핵심**: 웹뷰 네이티브 상태 완전 무시, 오직 우리 데이터만 사용!
    public var canGoBack: Bool { 
        return dataModel.canGoBack
    }
    public var canGoForward: Bool { 
        return dataModel.canGoForward
    }
    
    @Published public var showAVPlayer = false
    
    // ✨ 데스크탑 모드 상태
    @Published public var isDesktopMode: Bool = false {
        didSet {
            if oldValue != isDesktopMode {
                // 사용자 에이전트 변경을 위해 페이지 새로고침
                if let webView = webView {
                    updateUserAgentIfNeeded(webView: webView, stateModel: self)
                    webView.reload()
                }
            }
        }
    }

    // ✨ 줌 레벨 관리 (데스크탑 모드용)
    @Published public var currentZoomLevel: Double = 0.5 {
        didSet {
            if oldValue != currentZoomLevel {
                applyZoomLevel()
            }
        }
    }
    
    public weak var webView: WKWebView? {
        didSet {
            if let webView = webView {
                // DataModel에 NavigationDelegate 설정
                webView.navigationDelegate = dataModel
                dataModel.stateModel = self
                
                // 🎯 **핵심**: 웹뷰 네이티브 네비게이션 완전 비활성화
                setupWebViewNavigation(webView)
            }
        }
    }
    
    // ✨ 네비게이션 상태 변경 감지용 Cancellable
    private var cancellables = Set<AnyCancellable>()

    public override init() {
        super.init()
        // tabID 연결
        dataModel.tabID = tabID
        dataModel.stateModel = self
        
        // 🎯 **핵심**: DataModel의 상태 변경만 감지, 웹뷰 상태는 무시
        setupDataModelObservation()
    }
    
    // MARK: - 🎯 **핵심**: 웹뷰 네이티브 네비게이션 완전 제어
    
    private func setupWebViewNavigation(_ webView: WKWebView) {
        // 🚫 네이티브 제스처 비활성화 (이미 CustomWebView에서 설정됨)
        webView.allowsBackForwardNavigationGestures = false
        
        // 🎯 네이티브 히스토리 조작 방지를 위한 추가 설정
        dbg("🎯 웹뷰 네이티브 네비게이션 완전 제어 설정")
    }
    
    // MARK: - 🎯 **핵심**: 데이터 모델만 관찰, 웹뷰 네이티브 상태 무시
    private func setupDataModelObservation() {
        // DataModel의 canGoBack, canGoForward 변경을 감지하여 UI 업데이트
        dataModel.$canGoBack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.objectWillChange.send()
                self?.dbg("🎯 DataModel canGoBack 변경: \(newValue)")
            }
            .store(in: &cancellables)
        
        dataModel.$canGoForward
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.objectWillChange.send()
                self?.dbg("🎯 DataModel canGoForward 변경: \(newValue)")
            }
            .store(in: &cancellables)
    }

    // MARK: - DataModel과의 통신 메서드들 - 🔧 public 접근권한 명시
    
    public func handleLoadingStart() {
        isLoading = true
    }
    
    public func handleLoadingFinish() {
        isLoading = false
        
        // ✨ 데스크탑 모드일 때 줌 레벨 재적용
        if isDesktopMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.applyZoomLevel()
            }
        }
    }
    
    public func handleLoadingError() {
        isLoading = false
    }
    
    public func syncCurrentURL(_ url: URL) {
        if !isNavigatingFromWebView {
            isNavigatingFromWebView = true
            currentURL = url
            isNavigatingFromWebView = false
        }
    }
    
    public func triggerNavigationFinished() {
        navigationDidFinish.send(())
    }
    
    // MARK: - 순수 에러 알림 처리 - 🔧 public 접근권한 명시
    
    public func notifyError(_ error: Error, url: String) {
        guard let tabID = tabID else { return }
        
        NotificationCenter.default.post(
            name: Notification.Name("webViewDidFailLoad"),
            object: nil,
            userInfo: [
                "tabID": tabID.uuidString,
                "error": error,
                "url": url
            ]
        )
    }
    
    public func notifyHTTPError(_ statusCode: Int, url: String) {
        guard let tabID = tabID else { return }
        
        NotificationCenter.default.post(
            name: Notification.Name("webViewDidFailLoad"),
            object: nil,
            userInfo: [
                "tabID": tabID.uuidString,
                "statusCode": statusCode,
                "url": url
            ]
        )
    }
    
    // MARK: - 📁 다운로드 처리 (헬퍼 호출로 변경) - 🔧 public 접근권한 명시
    
    public func handleDownloadDecision(_ navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // 헬퍼 함수 호출
        shouldDownloadResponse(navigationResponse, decisionHandler: decisionHandler)
    }

    // ✨ 줌 레벨 적용 메서드 - 🔧 private 유지
    private func applyZoomLevel() {
        guard let webView = webView, isDesktopMode else { return }
        
        let jsScript = """
        if (window.setPageZoom) {
            window.setPageZoom(\(currentZoomLevel));
        }
        """
        
        webView.evaluateJavaScript(jsScript) { [weak self] result, error in
            if let error = error {
                self?.dbg("❌ 줌 적용 실패: \(error.localizedDescription)")
            } else {
                self?.dbg("🔍 줌 레벨 적용: \(String(format: "%.1f", self?.currentZoomLevel ?? 0.5))x")
            }
        }
    }

    // ✨ 줌 레벨 설정 메서드 (외부에서 호출용) - 🔧 public 접근권한 명시
    public func setZoomLevel(_ level: Double) {
        let clampedLevel = max(0.3, min(3.0, level))
        currentZoomLevel = clampedLevel
    }

    // ✨ 로딩 중지 메서드 - 🔧 public 접근권한 명시
    public func stopLoading() {
        webView?.stopLoading()
        isLoading = false
        dataModel.resetNavigationFlags()
    }

    public func clearHistory() {
        dataModel.clearHistory()
    }

    // ✨ 데스크탑 모드 토글 메서드 - 🔧 public 접근권한 명시
    public func toggleDesktopMode() {
        isDesktopMode.toggle()
    }

    // MARK: - 데이터 모델과 연동된 네비게이션 메서드들 - 🔧 public 접근권한 명시
    
    public func updateCurrentPageTitle(_ title: String) {
        dataModel.updateCurrentPageTitle(title)
    }
    
    public var currentPageRecord: PageRecord? {
        dataModel.currentPageRecord
    }

    // MARK: - 세션 저장/복원 (데이터 모델에 위임) - 🔧 public 접근권한 명시
    
    public func saveSession() -> WebViewSession? {
        alignIDsIfNeeded()
        return dataModel.saveSession()
    }

    public func restoreSession(_ session: WebViewSession) {
        dbg("🔄 === 세션 복원 시작 ===")
        
        dataModel.restoreSession(session)
        
        if let currentRecord = dataModel.currentPageRecord {
            isNavigatingFromWebView = true
            currentURL = currentRecord.url
            isNavigatingFromWebView = false
            
            dbg("🔄 세션 복원: \(dataModel.pageHistory.count)개 페이지, 현재 '\(currentRecord.title)'")
        } else {
            currentURL = nil
            dbg("🔄 세션 복원 실패: 유효한 페이지 없음")
        }
        
        if let webView = webView, let url = currentURL {
            // 🎯 새 URLRequest로 완전히 새로 로드
            webView.load(URLRequest(url: url))
        }
        
        dataModel.finishSessionRestore()
    }

    // MARK: - 🎯 **단순화된 히스토리 네비게이션** (DataModel에 완전 위임) - 🔧 public 접근권한 명시
    
    public func goBack() {
        guard canGoBack else { 
            dbg("❌ goBack 실패: canGoBack=false (DataModel 기준)")
            return 
        }
        
        // 🎯 **핵심 수정**: DataModel 큐 시스템 사용
        isNavigatingFromWebView = true
        
        if let record = dataModel.navigateBack() {
            // ✅ currentURL 즉시 동기화
            currentURL = record.url
            
            // 🎯 강제 UI 업데이트 (웹뷰 상태와 무관하게)
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
            
            dbg("⬅️ 뒤로가기 큐 추가 성공: '\(record.title)' [DataModel 인덱스: \(dataModel.currentPageIndex)/\(dataModel.pageHistory.count)]")
        } else {
            dbg("❌ 뒤로가기 실패: DataModel에서 nil 반환")
        }
        
        // ✅ 플래그 리셋
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isNavigatingFromWebView = false
            self.dbg("🔄 뒤로가기 플래그 리셋 완료")
        }
    }
    
    public func goForward() {
        guard canGoForward else { 
            dbg("❌ goForward 실패: canGoForward=false (DataModel 기준)")
            return 
        }
        
        // 🎯 **핵심 수정**: DataModel 큐 시스템 사용
        isNavigatingFromWebView = true
        
        if let record = dataModel.navigateForward() {
            // ✅ currentURL 즉시 동기화
            currentURL = record.url
            
            // 🎯 강제 UI 업데이트 (웹뷰 상태와 무관하게)
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
            
            dbg("➡️ 앞으로가기 큐 추가 성공: '\(record.title)' [DataModel 인덱스: \(dataModel.currentPageIndex)/\(dataModel.pageHistory.count)]")
        } else {
            dbg("❌ 앞으로가기 실패: DataModel에서 nil 반환")
        }
        
        // ✅ 플래그 리셋
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isNavigatingFromWebView = false
            self.dbg("🔄 앞으로가기 플래그 리셋 완료")
        }
    }
    
    // 🔄 **BFCache 연동 개선**: 캐시 우선 복원, 없으면 새로 로드 - 🔧 internal 접근권한으로 수정
    internal func performQueuedRestore(to url: URL) {
        guard let webView = webView,
              let tabID = tabID,
              let currentRecord = dataModel.currentPageRecord else {
            dbg("⚠️ 웹뷰/tabID/레코드 없음 - 복원 스킵")
            return
        }
        
        let pageID = currentRecord.id
        
        // 🔄 **핵심 수정**: BFCache에 스냅샷이 있는지 확인 - 🔧 안전한 접근 방식 사용
        if let bfCacheSystem = getBFCacheSystem() {
            if bfCacheSystem.hasCache(for: pageID) {
                dbg("🔄 BFCache 스냅샷 발견 - BFCache 복원 시도: \(url.absoluteString)")
                
                // BFCache 복원 시도
                if let snapshot = bfCacheSystem.retrieveSnapshot(for: pageID) {
                    snapshot.restore(to: webView) { [weak self] success in
                        if success {
                            self?.dbg("✅ BFCache 복원 성공: \(currentRecord.title)")
                        } else {
                            self?.dbg("⚠️ BFCache 복원 실패 - fallback 새로 로드")
                            // BFCache 복원 실패 시 새로 로드
                            DispatchQueue.main.async {
                                webView.load(URLRequest(url: url))
                            }
                        }
                    }
                } else {
                    dbg("❌ BFCache 스냅샷 조회 실패 - 새로 로드")
                    webView.load(URLRequest(url: url))
                }
            } else {
                dbg("🔄 BFCache 스냅샷 없음 - 새로 로드: \(url.absoluteString)")
                // 캐시가 없으면 새로 로드
                webView.load(URLRequest(url: url))
            }
        } else {
            dbg("🔄 BFCache 시스템 접근 불가 - 새로 로드: \(url.absoluteString)")
            // BFCache 시스템에 접근할 수 없으면 새로 로드
            webView.load(URLRequest(url: url))
        }
    }
    
    // 🔧 **접근권한 수정**: BFCache 시스템에 안전하게 접근하는 헬퍼 메서드
    private func getBFCacheSystem() -> BFCacheTransitionSystem? {
        // BFCacheTransitionSystem이 사용 가능한지 확인 후 반환
        return BFCacheTransitionSystem.shared
    }
    
    // 🎯 **BFCache 통합 - 제스처 관련 메서드 모두 제거**
    // safariStyleGoBack - 제거됨 (BFCacheTransitionSystem으로 이관)
    // safariStyleGoForward - 제거됨 (BFCacheTransitionSystem으로 이관)
    // handleSwipeGestureDetected - 제거됨 (BFCacheTransitionSystem으로 이관)
    
    public func reload() { 
        guard let webView = webView else { return }
        webView.reload()
    }

    // MARK: - ✅ CustomWebView와 연동을 위한 메서드들 - 🔧 public 접근권한 명시
    
    /// CustomWebView에서 사용하는 isNavigatingFromWebView 플래그 제어
    public func setNavigatingFromWebView(_ value: Bool) {
        self.isNavigatingFromWebView = value
    }
    
    // ✅ 쿠키 동기화 처리 - 🔧 public 접근권한 명시
    public func handleDidCommitNavigation(_ webView: WKWebView) {
        // 기존 쿠키 동기화 로직
        _installCookieSyncIfNeeded(for: webView)
        CookieSyncManager.syncAppToWebView(webView, completion: nil)
    }

    // MARK: - 기존 호환성 API (데이터 모델에 위임) - 🔧 public 접근권한 명시
    
    public var historyURLs: [String] {
        return dataModel.historyURLs
    }

    public var currentHistoryIndex: Int {
        return dataModel.currentHistoryIndex
    }

    public func historyStackIfAny() -> [URL] {
        return dataModel.historyStackIfAny()
    }

    public func currentIndexInSafeBounds() -> Int {
        return dataModel.currentIndexInSafeBounds()
    }
    
    public func loadURLIfReady() {
        if let url = currentURL, let webView = webView {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - ID 정렬 - 🔧 private 유지
    private func alignIDsIfNeeded() {
        if dataModel.tabID != tabID {
            dataModel.tabID = tabID
            TabPersistenceManager.debugMessages.append("ID 정렬: dataModel.tabID <- \(String(tabID?.uuidString.prefix(8) ?? "nil"))")
        }
    }

    // MARK: - 🎯 단순화된 디버그 메서드 - 🔧 private 유지
    
    private func dbg(_ msg: String) {
        let id: String
        if let tabID = tabID {
            id = String(tabID.uuidString.prefix(6))
        } else {
            id = "noTab"
        }
        
        // 🎯 네비게이션 상태도 함께 로깅
        let navState = "B:\(dataModel.canGoBack ? "✅" : "❌") F:\(dataModel.canGoForward ? "✅" : "❌")"
        let flagState = isNavigatingFromWebView ? "[🚩FLAG]" : ""
        let restoreState = dataModel.restoreState.isActive ? "[\(dataModel.restoreState)]" : ""
        let queueState = dataModel.queueCount > 0 ? "[Q:\(dataModel.queueCount)]" : ""
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(flagState)\(restoreState)\(queueState) \(msg)")
    }
    
    // MARK: - 메모리 정리
    deinit {
        cancellables.removeAll()
    }
}

// MARK: - 쿠키 세션 공유 확장 - 🔧 접근권한 수정
extension WebViewStateModel {
    private func _installCookieSyncIfNeeded(for webView: WKWebView) {
        if _cookieSyncInstalledModels.contains(self) { return }
        _cookieSyncInstalledModels.add(self)

        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.add(self)

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSHTTPCookieManagerCookiesChanged"),
            object: HTTPCookieStorage.shared,
            queue: .main
        ) { [weak webView] _ in
            guard let webView = webView else { return }
            CookieSyncManager.syncAppToWebView(webView, completion: nil)
        }
    }
}

// 🔧 **접근권한 수정**: WKHTTPCookieStoreObserver 프로토콜 준수 명시적으로 public
extension WebViewStateModel: WKHTTPCookieStoreObserver {
    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        CookieSyncManager.syncWebToApp(cookieStore) {
            // 쿠키 동기화 완료
        }
    }
}

// MARK: - 전역 쿠키 동기화 추적 - 🔧 fileprivate 유지
fileprivate let _cookieSyncInstalledModels = NSHashTable<AnyObject>.weakObjects()
