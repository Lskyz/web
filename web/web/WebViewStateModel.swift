//
//  WebViewStateModel.swift
//  🎯 **캐싱 기반 부드러운 히스토리 네비게이션 + 조용한 백그라운드 새로고침**
//  ✅ 히스토리 네비게이션 중 새 페이지 추가 차단 강화
//  📁 다운로드 관련 코드 헬퍼로 이관 완료
//  🎯 히스토리 복원 플래그 DataModel 연동
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

// MARK: - WebViewStateModel (캐싱 기반 부드러운 네비게이션)
final class WebViewStateModel: NSObject, ObservableObject {

    var tabID: UUID?
    
    // ✅ 히스토리/세션 데이터 모델 참조
    @Published var dataModel = WebViewDataModel()
    
    // ✨ 순수 UI 상태만
    @Published var isLoading: Bool = false
    @Published var loadingProgress: Double = 0.0
    
    let navigationDidFinish = PassthroughSubject<Void, Never>()

    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }

            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")

            // ✅ 웹뷰 로드 조건 개선 - 즉석 네비게이션 시 로드하지 않음
            let shouldLoad = url != oldValue && 
                           !dataModel.isRestoringSession &&
                           !isNavigatingFromWebView &&
                           !dataModel.isHistoryNavigationActive() &&
                           !isInstantNavigation // 📸 즉석 네비게이션 시 로드 방지
            
            if shouldLoad {
                if let webView = webView {
                    webView.load(URLRequest(url: url))
                } else {
                    dbg("⚠️ 웹뷰가 없어서 로드 불가")
                }
            }
        }
    }
    
    // ✅ 웹뷰 내부 네비게이션 플래그
    internal var isNavigatingFromWebView: Bool = false
    
    // 📸 즉석 네비게이션 플래그 (네트워크 재요청 방지)
    internal var isInstantNavigation: Bool = false
    
    // 🎯 **새로 추가**: 조용한 새로고침 플래그 (로딩 인디케이터 숨김)
    internal var isSilentRefresh: Bool = false
    
    // 🎯 **핵심**: 웹뷰 네이티브 상태 완전 무시, 오직 우리 데이터만 사용!
    var canGoBack: Bool { 
        return dataModel.canGoBack
    }
    var canGoForward: Bool { 
        return dataModel.canGoForward
    }
    
    @Published var showAVPlayer = false
    
    // ✨ 데스크탑 모드 상태
    @Published var isDesktopMode: Bool = false {
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
    @Published var currentZoomLevel: Double = 0.5 {
        didSet {
            if oldValue != currentZoomLevel {
                applyZoomLevel()
            }
        }
    }
    
    weak var webView: WKWebView? {
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

    override init() {
        super.init()
        // tabID 연결
        dataModel.tabID = tabID
        dataModel.stateModel = self
        
        // 🎯 **핵심**: DataModel의 상태 변경만 감지, 웹뷰 상태는 무시
        setupDataModelObservation()
    }
    
    // MARK: - 🎯 **핵심 추가**: 웹뷰 네이티브 네비게이션 완전 제어
    
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

    // MARK: - DataModel과의 통신 메서드들
    
    func handleLoadingStart() {
        // 🎯 조용한 새로고침 시에는 로딩 인디케이터 표시 안함
        if !isInstantNavigation && !isSilentRefresh {
            isLoading = true
        }
    }
    
    func handleLoadingFinish() {
        // 🎯 조용한 새로고침 종료
        if !isInstantNavigation && !isSilentRefresh {
            isLoading = false
        }
        
        // 조용한 새로고침 플래그 리셋
        if isSilentRefresh {
            isSilentRefresh = false
            dbg("🤫 조용한 새로고침 완료")
        }
        
        // ✨ 데스크탑 모드일 때 줌 레벨 재적용
        if isDesktopMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.applyZoomLevel()
            }
        }
    }
    
    func handleLoadingError() {
        if !isInstantNavigation && !isSilentRefresh {
            isLoading = false
        }
        isSilentRefresh = false
    }
    
    func syncCurrentURL(_ url: URL) {
        if !isNavigatingFromWebView && !isInstantNavigation {
            isNavigatingFromWebView = true
            currentURL = url
            isNavigatingFromWebView = false
        }
    }
    
    func triggerNavigationFinished() {
        navigationDidFinish.send(())
    }
    
    // MARK: - 📸 즉석 네비게이션 제어 메서드
    
    func setInstantNavigation(_ value: Bool) {
        isInstantNavigation = value
        if value {
            dbg("📸 즉석 네비게이션 시작 - 네트워크 재요청 방지")
        } else {
            dbg("📸 즉석 네비게이션 종료")
        }
    }
    
    // 🎯 **새로 추가**: 조용한 새로고침 제어 메서드
    func setSilentRefresh(_ value: Bool) {
        isSilentRefresh = value
        if value {
            dbg("🤫 조용한 새로고침 시작 - 로딩 인디케이터 숨김")
        } else {
            dbg("🤫 조용한 새로고침 종료")
        }
    }
    
    // MARK: - 순수 에러 알림 처리
    
    func notifyError(_ error: Error, url: String) {
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
    
    func notifyHTTPError(_ statusCode: Int, url: String) {
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
    
    // MARK: - 📁 다운로드 처리 (헬퍼 호출로 변경)
    
    func handleDownloadDecision(_ navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // 헬퍼 함수 호출
        shouldDownloadResponse(navigationResponse, decisionHandler: decisionHandler)
    }

    // ✨ 줌 레벨 적용 메서드
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

    // ✨ 줌 레벨 설정 메서드 (외부에서 호출용)
    func setZoomLevel(_ level: Double) {
        let clampedLevel = max(0.3, min(3.0, level))
        currentZoomLevel = clampedLevel
    }

    // ✨ 로딩 중지 메서드
    func stopLoading() {
        webView?.stopLoading()
        isLoading = false
        isSilentRefresh = false
        dataModel.resetNavigationFlags()
    }

    func clearHistory() {
        dataModel.clearHistory()
    }

    // ✨ 데스크탑 모드 토글 메서드
    func toggleDesktopMode() {
        isDesktopMode.toggle()
    }

    // MARK: - 데이터 모델과 연동된 네비게이션 메서드들
    
    func updateCurrentPageTitle(_ title: String) {
        dataModel.updateCurrentPageTitle(title)
    }
    
    var currentPageRecord: PageRecord? {
        dataModel.currentPageRecord
    }

    // MARK: - 세션 저장/복원 (데이터 모델에 위임)
    
    func saveSession() -> WebViewSession? {
        alignIDsIfNeeded()
        return dataModel.saveSession()
    }

    func restoreSession(_ session: WebViewSession) {
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

    // MARK: - 🎯 **큐 기반 부드러운 히스토리 네비게이션** (DataModel 연동)
    
    func goBack() {
        guard canGoBack else { 
            dbg("❌ goBack 실패: canGoBack=false (DataModel 기준)")
            return 
        }
        
        // 🎯 **핵심 수정**: 큐 기반 네비게이션
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
        
        // ✅ **수정**: 플래그 리셋 시간을 2초로 연장 (큐 처리 완료 대기)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.isNavigatingFromWebView = false
            self.dbg("🔄 뒤로가기 플래그 리셋 완료")
        }
    }
    
    func goForward() {
        guard canGoForward else { 
            dbg("❌ goForward 실패: canGoForward=false (DataModel 기준)")
            return 
        }
        
        // 🎯 **핵심 수정**: 큐 기반 네비게이션
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
        
        // ✅ **수정**: 플래그 리셋 시간을 2초로 연장 (큐 처리 완료 대기)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.isNavigatingFromWebView = false
            self.dbg("🔄 앞으로가기 플래그 리셋 완료")
        }
    }
    
    // 🎯 **새로 추가**: 큐 기반 복원을 위한 메서드
    func performQueuedRestore(to url: URL) {
        // 📸 **중요**: 캐시 활용 부드러운 로딩
        performSmoothNavigation(to: url, webView: webView, direction: .back)
    }
    
    // 🎯 **새로 추가**: 캐싱 기반 부드러운 네비게이션 구현
    private enum NavigationDirection {
        case back, forward
    }
    
    private func performSmoothNavigation(to url: URL, webView: WKWebView?, direction: NavigationDirection) {
        guard let webView = webView else {
            dbg("⚠️ 웹뷰 없음 - 부드러운 네비게이션 스킵")
            return
        }
        
        // 1️⃣ 조용한 새로고침 플래그 설정 (로딩 인디케이터 숨김)
        setSilentRefresh(true)
        
        // 2️⃣ CustomWebView의 캐시에서 스냅샷 확인 및 즉시 표시 알림
        NotificationCenter.default.post(
            name: .init("ShowCachedPageBeforeLoad"),
            object: nil,
            userInfo: [
                "url": url,
                "direction": direction == .back ? "back" : "forward"
            ]
        )
        
        // 3️⃣ 백그라운드에서 조용히 실제 페이지 로드
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            webView.load(URLRequest(url: url))
            self.dbg("🤫 백그라운드 조용한 로드 시작: \(url.absoluteString)")
        }
    }
    
    // MARK: - 🏄‍♂️ 사파리 스타일 제스처 네비게이션 (캐싱 적용)
    
    func safariStyleGoBack(progress: Double = 1.0) {
        guard canGoBack else { return }
        
        // 햅틱 피드백
        if progress >= 1.0 {
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.impactOccurred()
            
            // 실제 뒤로가기 실행 (캐싱 적용)
            goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료 (캐싱)")
        }
    }
    
    func safariStyleGoForward(progress: Double = 1.0) {
        guard canGoForward else { return }
        
        // 햅틱 피드백
        if progress >= 1.0 {
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.impactOccurred()
            
            // 실제 앞으로가기 실행 (캐싱 적용)
            goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료 (캐싱)")
        }
    }
    
    func reload() { 
        guard let webView = webView else { return }
        webView.reload()
    }

    // MARK: - ✅ CustomWebView와 연동을 위한 메서드들
    
    /// CustomWebView에서 사용하는 isNavigatingFromWebView 플래그 제어
    func setNavigatingFromWebView(_ value: Bool) {
        self.isNavigatingFromWebView = value
    }
    
    // CustomWebView에서 호출할 수 있는 스와이프 감지 메서드 (단순화됨)
    func handleSwipeGestureDetected(to url: URL) {
        // 이제 커스텀 제스처로 직접 처리하므로 단순화
        guard !dataModel.isHistoryNavigationActive() else {
            return
        }
        
        dataModel.handleSwipeGestureDetected(to: url)
    }
    
    // ✅ 쿠키 동기화 처리
    func handleDidCommitNavigation(_ webView: WKWebView) {
        // 기존 쿠키 동기화 로직
        _installCookieSyncIfNeeded(for: webView)
        CookieSyncManager.syncAppToWebView(webView, completion: nil)
    }

    // MARK: - 기존 호환성 API (데이터 모델에 위임)
    
    var historyURLs: [String] {
        return dataModel.historyURLs
    }

    var currentHistoryIndex: Int {
        return dataModel.currentHistoryIndex
    }

    func historyStackIfAny() -> [URL] {
        return dataModel.historyStackIfAny()
    }

    func currentIndexInSafeBounds() -> Int {
        return dataModel.currentIndexInSafeBounds()
    }
    
    func loadURLIfReady() {
        if let url = currentURL, let webView = webView {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - ID 정렬
    private func alignIDsIfNeeded() {
        if dataModel.tabID != tabID {
            dataModel.tabID = tabID
            TabPersistenceManager.debugMessages.append("ID 정렬: dataModel.tabID <- \(String(tabID?.uuidString.prefix(8) ?? "nil"))")
        }
    }

    // MARK: - 🎯 강화된 디버그 메서드
    
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
        let instantState = isInstantNavigation ? "[📸INSTANT]" : ""
        let silentState = isSilentRefresh ? "[🤫SILENT]" : ""
        let restoreState = dataModel.isHistoryNavigationActive() ? "[🔄RESTORE]" : ""
        let queueState = dataModel.queueCount > 0 ? "[Q:\(dataModel.queueCount)]" : ""
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(flagState)\(instantState)\(silentState)\(restoreState)\(queueState) \(msg)")
    }
    
    // MARK: - 메모리 정리
    deinit {
        cancellables.removeAll()
    }
}

// MARK: - 쿠키 세션 공유 확장
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

extension WebViewStateModel: WKHTTPCookieStoreObserver {
    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        CookieSyncManager.syncWebToApp(cookieStore) {
            // 쿠키 동기화 완료
        }
    }
}

// MARK: - 전역 쿠키 동기화 추적
private let _cookieSyncInstalledModels = NSHashTable<AnyObject>.weakObjects()
