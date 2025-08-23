//
//  WebViewStateModel.swift
//  🎯 **캐싱 기반 부드러운 히스토리 네비게이션 + 조용한 백그라운드 새로고침**
//  ✅ 히스토리 네비게이션 중 새 페이지 추가 차단 강화
//  📁 다운로드 관련 코드 헬퍼로 이관 완료
//  🎯 히스토리 복원 플래그 DataModel 연동
//  🛡️ 폴백 메커니즘 및 안정성 강화 추가
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

// MARK: - WebViewStateModel (캐싱 기반 부드러운 네비게이션 + 폴백 강화)
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

            // 🛡️ **폴백 강화**: 로드 조건 검사 및 폴백 메커니즘
            handleURLChange(url: url, oldURL: oldValue)
        }
    }
    
    // ✅ 웹뷰 내부 네비게이션 플래그
    internal var isNavigatingFromWebView: Bool = false
    
    // 📸 즉석 네비게이션 플래그 (네트워크 재요청 방지)
    internal var isInstantNavigation: Bool = false
    
    // 🎯 **새로 추가**: 조용한 새로고침 플래그 (로딩 인디케이터 숨김)
    internal var isSilentRefresh: Bool = false
    
    // 🛡️ **새로 추가**: 폴백 추적 및 강제 로딩
    private var fallbackAttempts: [String: Int] = [:]
    private var lastFailedURL: URL?
    private var navigationTimeoutTimer: Timer?
    
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
    
    // MARK: - 🛡️ **새로 추가**: URL 변경 처리 및 폴백 메커니즘
    
    private func handleURLChange(url: URL, oldURL: URL?) {
        let urlKey = url.absoluteString
        
        // URL 변경 감지 및 디버그 로그
        if url != oldURL {
            dbg("📍 URL 변경 감지: \(url.absoluteString)")
        }
        
        // 로드 조건 검사
        let loadingConditions = evaluateLoadingConditions(url: url, oldURL: oldURL)
        
        // 🛡️ 조건별 처리 및 폴백
        if loadingConditions.shouldLoad {
            // 정상 로딩 경로
            performWebViewLoad(url: url, reason: "정상조건")
            resetFallbackAttempts(for: urlKey)
        } else {
            // 로딩이 차단된 경우 - 구체적 원인 로깅 및 폴백 시도
            dbg("🚫 로딩 차단됨: \(loadingConditions.blockingReasons.joined(separator: ", "))")
            
            // 🛡️ 폴백 메커니즘 실행
            attemptFallbackLoading(url: url, blockingReasons: loadingConditions.blockingReasons)
        }
    }
    
    private func evaluateLoadingConditions(url: URL, oldURL: URL?) -> (shouldLoad: Bool, blockingReasons: [String]) {
        var blockingReasons: [String] = []
        
        // URL 동일성 체크
        if url == oldURL {
            blockingReasons.append("URL동일")
        }
        
        // 세션 복원 중
        if dataModel.isRestoringSession {
            blockingReasons.append("세션복원중")
        }
        
        // 웹뷰 내부 네비게이션
        if isNavigatingFromWebView {
            blockingReasons.append("웹뷰내부네비")
        }
        
        // 히스토리 네비게이션 활성
        if dataModel.isHistoryNavigationActive() {
            blockingReasons.append("히스토리네비활성")
        }
        
        // 즉석 네비게이션
        if isInstantNavigation {
            blockingReasons.append("즉석네비")
        }
        
        let shouldLoad = blockingReasons.isEmpty
        return (shouldLoad: shouldLoad, blockingReasons: blockingReasons)
    }
    
    private func attemptFallbackLoading(url: URL, blockingReasons: [String]) {
        let urlKey = url.absoluteString
        let currentAttempts = fallbackAttempts[urlKey] ?? 0
        
        // 🛡️ 최대 3회까지 폴백 시도
        guard currentAttempts < 3 else {
            dbg("❌ 폴백 시도 한계 초과: \(url.absoluteString)")
            return
        }
        
        fallbackAttempts[urlKey] = currentAttempts + 1
        dbg("🔄 폴백 시도 \(currentAttempts + 1)/3: \(blockingReasons.joined(separator: ","))")
        
        // 🛡️ 상황별 폴백 전략
        if blockingReasons.contains("히스토리네비활성") {
            // 히스토리 네비게이션 중이면 큐 완료 후 재시도
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.retryURLLoad(url: url, reason: "히스토리네비완료대기")
            }
        } else if blockingReasons.contains("세션복원중") {
            // 세션 복원 중이면 복원 완료 후 재시도
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.retryURLLoad(url: url, reason: "세션복원완료대기")
            }
        } else if blockingReasons.contains("웹뷰내부네비") || blockingReasons.contains("즉석네비") {
            // 내부 네비게이션 플래그 리셋 후 재시도
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.isNavigatingFromWebView = false
                self.isInstantNavigation = false
                self.retryURLLoad(url: url, reason: "플래그리셋후")
            }
        } else {
            // 기타 경우 강제 로딩
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performWebViewLoad(url: url, reason: "강제로딩", force: true)
            }
        }
    }
    
    private func retryURLLoad(url: URL, reason: String) {
        // 현재 URL과 일치하는 경우에만 재시도
        guard currentURL == url else {
            dbg("🔄 재시도 취소: URL 불일치 (\(reason))")
            return
        }
        
        // 로딩 조건 재평가
        let conditions = evaluateLoadingConditions(url: url, oldURL: nil)
        if conditions.shouldLoad {
            performWebViewLoad(url: url, reason: "재시도(\(reason))")
            resetFallbackAttempts(for: url.absoluteString)
        } else {
            dbg("🔄 재시도 실패: 여전히 차단됨 - \(conditions.blockingReasons.joined(separator: ","))")
            // 한 번 더 폴백 시도
            attemptFallbackLoading(url: url, blockingReasons: conditions.blockingReasons)
        }
    }
    
    private func performWebViewLoad(url: URL, reason: String, force: Bool = false) {
        guard let webView = webView else {
            dbg("⚠️ 웹뷰가 없어서 로드 불가 (\(reason))")
            return
        }
        
        // 🛡️ 웹뷰 상태 검증
        let webViewState = validateWebViewState(webView: webView)
        if !webViewState.isHealthy && !force {
            dbg("⚠️ 웹뷰 상태 불량 - 복구 시도 (\(reason))")
            // 웹뷰 복구 시도
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.performWebViewLoad(url: url, reason: "\(reason)+복구", force: true)
            }
            return
        }
        
        // 실제 로딩 수행
        webView.load(URLRequest(url: url))
        dbg("🌐 웹뷰 로딩 시작: \(url.absoluteString) (\(reason))")
        
        // 🛡️ 네비게이션 타임아웃 설정 (10초)
        setupNavigationTimeout(for: url)
    }
    
    private func validateWebViewState(webView: WKWebView) -> (isHealthy: Bool, issues: [String]) {
        var issues: [String] = []
        
        // 기본 상태 체크
        if webView.isLoading && webView.estimatedProgress == 0.0 {
            issues.append("무한로딩")
        }
        
        // URL 불일치 체크
        if let webViewURL = webView.url, let currentURL = currentURL {
            let webViewNormalized = PageRecord.normalizeURL(webViewURL)
            let currentNormalized = PageRecord.normalizeURL(currentURL)
            if webViewNormalized != currentNormalized {
                issues.append("URL불일치")
            }
        }
        
        let isHealthy = issues.isEmpty
        if !isHealthy {
            dbg("🩺 웹뷰 상태 검증: \(issues.joined(separator: ","))")
        }
        
        return (isHealthy: isHealthy, issues: issues)
    }
    
    private func setupNavigationTimeout(for url: URL) {
        // 이전 타이머 정리
        navigationTimeoutTimer?.invalidate()
        
        // 새 타이머 설정
        navigationTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            guard let self = self, self.currentURL == url else { return }
            
            // 타임아웃 처리
            self.dbg("⏰ 네비게이션 타임아웃: \(url.absoluteString)")
            self.handleNavigationTimeout(for: url)
        }
    }
    
    private func handleNavigationTimeout(for url: URL) {
        // 웹뷰 상태 재검증
        guard let webView = webView else { return }
        let validation = validateWebViewState(webView: webView)
        
        if !validation.isHealthy {
            dbg("🔧 타임아웃 후 웹뷰 복구 시도")
            // 강제 새로고침
            webView.reload()
        }
        
        lastFailedURL = url
    }
    
    private func resetFallbackAttempts(for urlKey: String) {
        fallbackAttempts.removeValue(forKey: urlKey)
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
        // 네비게이션 타이머 정리 (로딩이 시작되었으므로)
        navigationTimeoutTimer?.invalidate()
        
        // 🎯 조용한 새로고침 시에는 로딩 인디케이터 표시 안함
        if !isInstantNavigation && !isSilentRefresh {
            isLoading = true
        }
    }
    
    func handleLoadingFinish() {
        // 네비게이션 타이머 정리
        navigationTimeoutTimer?.invalidate()
        
        // 🎯 조용한 새로고침 종료
        if !isInstantNavigation && !isSilentRefresh {
            isLoading = false
        }
        
        // 조용한 새로고침 플래그 리셋
        if isSilentRefresh {
            isSilentRefresh = false
            dbg("🤫 조용한 새로고침 완료")
        }
        
        // 🛡️ 성공적인 로딩 후 상태 정리
        if let currentURL = currentURL {
            resetFallbackAttempts(for: currentURL.absoluteString)
            lastFailedURL = nil
        }
        
        // ✨ 데스크탑 모드일 때 줌 레벨 재적용
        if isDesktopMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.applyZoomLevel()
            }
        }
    }
    
    func handleLoadingError() {
        // 네비게이션 타이머 정리
        navigationTimeoutTimer?.invalidate()
        
        if !isInstantNavigation && !isSilentRefresh {
            isLoading = false
        }
        isSilentRefresh = false
        
        // 🛡️ 에러 발생 시 폴백 시도
        if let currentURL = currentURL {
            lastFailedURL = currentURL
            dbg("❌ 로딩 에러 발생, 폴백 고려: \(currentURL.absoluteString)")
        }
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
        navigationTimeoutTimer?.invalidate()
        webView?.stopLoading()
        isLoading = false
        isSilentRefresh = false
        dataModel.resetNavigationFlags()
    }

    func clearHistory() {
        dataModel.clearHistory()
        // 폴백 상태도 정리
        fallbackAttempts.removeAll()
        lastFailedURL = nil
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

    // MARK: - 🎯 **큐 기반 부드러운 히스토리 네비게이션** (DataModel 연동 + 폴백 강화)
    
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
    
    // 🎯 **새로 추가**: 큐 기반 복원을 위한 메서드 (폴백 강화)
    func performQueuedRestore(to url: URL) {
        // 📸 **중요**: 캐시 활용 부드러운 로딩 (폴백 포함)
        performSmoothNavigation(to: url, webView: webView, direction: .back)
    }
    
    // 🎯 **새로 추가**: 캐싱 기반 부드러운 네비게이션 구현 (폴백 강화)
    private enum NavigationDirection {
        case back, forward
    }
    
    private func performSmoothNavigation(to url: URL, webView: WKWebView?, direction: NavigationDirection) {
        guard let webView = webView else {
            dbg("⚠️ 웹뷰 없음 - 부드러운 네비게이션 스킵")
            // 🛡️ 폴백: 웹뷰가 없어도 URL은 동기화
            syncCurrentURL(url)
            return
        }
        
        // 🛡️ 웹뷰 상태 사전 검증
        let webViewValidation = validateWebViewState(webView: webView)
        
        // 1️⃣ 조용한 새로고침 플래그 설정 (로딩 인디케이터 숨김)
        setSilentRefresh(true)
        
        // 2️⃣ CustomWebView의 캐시에서 스냅샷 확인 및 즉시 표시 알림
        let cacheResult = showCachedPageIfAvailable(for: url, direction: direction)
        
        // 3️⃣ 백그라운드에서 조용히 실제 페이지 로드 (폴백 포함)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.performBackgroundLoad(webView: webView, url: url, 
                                     cacheAvailable: cacheResult, 
                                     webViewHealthy: webViewValidation.isHealthy)
        }
    }
    
    private func showCachedPageIfAvailable(for url: URL, direction: NavigationDirection) -> Bool {
        // 캐시 표시 요청
        NotificationCenter.default.post(
            name: .init("ShowCachedPageBeforeLoad"),
            object: nil,
            userInfo: [
                "url": url,
                "direction": direction == .back ? "back" : "forward"
            ]
        )
        
        // 🛡️ TODO: 실제 캐시 존재 여부를 확인하여 반환
        // 지금은 항상 true 반환 (CustomWebView에서 처리)
        return true
    }
    
    private func performBackgroundLoad(webView: WKWebView, url: URL, cacheAvailable: Bool, webViewHealthy: Bool) {
        dbg("🤫 백그라운드 조용한 로드 시작: \(url.absoluteString)")
        
        // 🛡️ 웹뷰가 건강하지 않은 경우 복구 시도
        if !webViewHealthy {
            dbg("⚠️ 웹뷰 상태 불량, 복구 후 로드")
            // 잠시 대기 후 재시도
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.performBackgroundLoad(webView: webView, url: url, cacheAvailable: cacheAvailable, webViewHealthy: true)
            }
            return
        }
        
        // 실제 로딩 수행
        webView.load(URLRequest(url: url))
        
        // 🛡️ 백그라운드 로딩 성공 여부 모니터링
        monitorBackgroundLoading(for: url)
    }
    
    private func monitorBackgroundLoading(for url: URL) {
        // 5초 후 백그라운드 로딩 결과 확인
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            guard let webView = self.webView,
                  self.currentURL == url else { return }
            
            // 실제 웹뷰 URL과 기대 URL 비교
            if let actualURL = webView.url {
                let expectedNormalized = PageRecord.normalizeURL(url)
                let actualNormalized = PageRecord.normalizeURL(actualURL)
                
                if expectedNormalized != actualNormalized && !webView.isLoading {
                    self.dbg("⚠️ 백그라운드 로딩 URL 불일치 감지")
                    self.dbg("   기대: \(expectedNormalized)")
                    self.dbg("   실제: \(actualNormalized)")
                    
                    // 🛡️ 폴백: 강제 재로딩
                    self.performForcedNavigation(to: url)
                }
            } else if !webView.isLoading {
                self.dbg("⚠️ 백그라운드 로딩 실패: 웹뷰 URL이 nil")
                
                // 🛡️ 폴백: 강제 재로딩
                self.performForcedNavigation(to: url)
            }
        }
    }
    
    private func performForcedNavigation(to url: URL) {
        dbg("🔧 강제 네비게이션 실행: \(url.absoluteString)")
        
        guard let webView = webView else { return }
        
        // 조용한 새로고침 해제
        setSilentRefresh(false)
        
        // 강제 로딩
        webView.load(URLRequest(url: url))
        
        // 타임아웃 설정
        setupNavigationTimeout(for: url)
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
        
        // 🛡️ 새로고침 시 상태 정리
        fallbackAttempts.removeAll()
        lastFailedURL = nil
        setSilentRefresh(false)
        
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
            performWebViewLoad(url: url, reason: "loadURLIfReady", force: true)
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
        let fallbackState = !fallbackAttempts.isEmpty ? "[🛡️FB:\(fallbackAttempts.count)]" : ""
        
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(flagState)\(instantState)\(silentState)\(restoreState)\(queueState)\(fallbackState) \(msg)")
    }
    
    // MARK: - 메모리 정리
    deinit {
        navigationTimeoutTimer?.invalidate()
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
