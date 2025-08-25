//
//  CustomWebView.swift
//
//  📸 캐싱 기반 부드러운 히스토리 네비게이션 + 조용한 백그라운드 새로고침
//  🎯 제스처 완료 시 커스텀 시스템과 웹뷰를 모두 정상 동기화
//  🌐 완전형 SPA 네비게이션 & DOM 변경 감지 훅 통합
//  🔧 제목 덮어쓰기 문제 해결 - titleObserver URL 검증 추가
//  📁 다운로드 기능 헬퍼 통합 완료 - 단방향 의존성 구현
//  🏊‍♂️ 웹뷰 풀 실제 연동 완료 - 생성/등록/재사용/정리
//  🚫 팝업 차단 시스템 완전 통합
//  🛡️ 캐시 실패 복구 시스템 추가 - 미리보기 무한 표시 방지
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import Foundation
import Security
import Photos

// MARK: - 고급 페이지 캐시 시스템 (부드러운 네비게이션용 강화)
class AdvancedPageCache: ObservableObject {
    struct CachedPage {
        let snapshot: UIImage
        let url: URL
        let title: String
        let timestamp: Date
    }
    
    private var pageCache: [String: CachedPage] = [:]
    private let maxCacheSize = 100 // ✅ 캐시 크기 증가 (히스토리 제한 해제에 맞춰)
    private let cacheQueue = DispatchQueue(label: "pageCache", qos: .userInitiated)
    
    func cachePage(url: URL, snapshot: UIImage, title: String) {
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            
            let cached = CachedPage(
                snapshot: snapshot,
                url: url,
                title: title,
                timestamp: Date()
            )
            
            self.pageCache[url.absoluteString] = cached
            
            // 캐시 크기 제한
            if self.pageCache.count > self.maxCacheSize {
                let oldest = self.pageCache.min { $0.value.timestamp < $1.value.timestamp }
                if let oldestKey = oldest?.key {
                    self.pageCache.removeValue(forKey: oldestKey)
                }
            }
            
            print("📸 페이지 캐시됨: \(title)")
        }
    }
    
    func getCachedPage(for url: URL) -> CachedPage? {
        return cacheQueue.sync {
            return pageCache[url.absoluteString]
        }
    }
    
    func clearAll() {
        cacheQueue.async { [weak self] in
            self?.pageCache.removeAll()
        }
    }
}

// MARK: - CustomWebView (UIViewRepresentable)
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool
    var onScroll: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - makeUIView
    func makeUIView(context: Context) -> WKWebView {
        // ✅ 오디오 세션 활성화 (헬퍼 호출)
        configureAudioSessionForMixing()

        // 🏊‍♂️ **핵심 1: 웹뷰 풀에서 재사용 시도**
        var webView: WKWebView?
        if let tabID = stateModel.tabID {
            webView = WebViewPool.shared.reuseWebView(for: tabID)
            TabPersistenceManager.debugMessages.append("🏊‍♂️ 웹뷰 풀 재사용 시도: 탭 \(String(tabID.uuidString.prefix(8)))")
        }
        
        // 재사용할 웹뷰가 없으면 새로 생성
        if webView == nil {
            // WKWebView 설정
            let config = WKWebViewConfiguration()
            config.allowsInlineMediaPlayback = true
            config.allowsPictureInPictureMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            config.websiteDataStore = WKWebsiteDataStore.default()
            config.processPool = WKProcessPool()

            // 📁 **다운로드 기능 헬퍼 통합**: iOS 14+ 다운로드 설정 강화
            if #available(iOS 14.0, *) {
                config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
                // ✅ 다운로드 허용 설정 추가
                config.preferences.javaScriptCanOpenWindowsAutomatically = true
                config.allowsInlineMediaPlayback = true
            }

            // 사용자 스크립트/메시지 핸들러 (헬퍼 호출)
            let controller = WKUserContentController()
            controller.addUserScript(makeVideoScript())
            controller.addUserScript(makeDesktopModeScript())
            controller.addUserScript(WebViewDataModel.makeSPANavigationScript()) // 🔧 수정: 단순화된 버전 사용
            controller.addUserScript(makeImageSaveScript()) // 📷 이미지 저장 스크립트 추가
            controller.add(context.coordinator, name: "playVideo")
            controller.add(context.coordinator, name: "setZoom")
            controller.add(context.coordinator, name: "spaNavigation")
            controller.add(context.coordinator, name: "saveImage") // 📷 이미지 저장 핸들러 추가
            config.userContentController = controller

            // WKWebView 생성
            webView = WKWebView(frame: .zero, configuration: config)
            TabPersistenceManager.debugMessages.append("🆕 새 웹뷰 생성: 탭 \(String(stateModel.tabID?.uuidString.prefix(8) ?? "unknown"))")
        }
        
        guard let finalWebView = webView else {
            fatalError("🚨 웹뷰 생성/재사용 실패")
        }
        
        // 🏊‍♂️ **핵심 2: 웹뷰 풀에 등록**
        if let tabID = stateModel.tabID {
            WebViewPool.shared.registerWebView(finalWebView, for: tabID)
            TabPersistenceManager.debugMessages.append("🏊‍♂️ 웹뷰 풀 등록: 탭 \(String(tabID.uuidString.prefix(8)))")
        }
        
        // 🎯 네이티브 제스처 완전 비활성화
        finalWebView.allowsBackForwardNavigationGestures = false
        
        finalWebView.scrollView.contentInsetAdjustmentBehavior = .never
        finalWebView.scrollView.decelerationRate = .normal

        // ✅ 하단 UI 겹치기를 위한 투명 처리 (헬퍼 호출)
        setupTransparentWebView(finalWebView)

        // ✨ Delegate 연결
        finalWebView.uiDelegate = context.coordinator
        
        // 📁 **수정**: NavigationDelegate는 DataModel이 처리 (WKNavigationDelegate 구현체)
        finalWebView.navigationDelegate = stateModel.dataModel
        
        // 📁 **다운로드 기능 헬퍼 호출**: iOS 14+ 다운로드 설정
        if #available(iOS 14.0, *) {
            setupWebViewDownloads(webView: finalWebView, stateModel: stateModel)
            TabPersistenceManager.debugMessages.append("📁 다운로드 기능 활성화 완료 (iOS 14+)")
        }
        
        context.coordinator.webView = finalWebView
        stateModel.webView = finalWebView
        
        // ✨ 초기 사용자 에이전트 설정 (헬퍼 호출)
        updateUserAgentIfNeeded(webView: finalWebView, stateModel: stateModel)

        // 📸 스냅샷 기반 제스처 설정 (커스텀 시스템과 완전 동기화)
        context.coordinator.setupSyncedSwipeGesture(for: finalWebView)

        // 🎯 **새로 추가**: 캐시된 페이지 미리보기 시스템 설정
        context.coordinator.setupCachedPagePreview(for: finalWebView)

        // Pull to Refresh (헬퍼 호출)
        setupPullToRefresh(for: finalWebView, target: context.coordinator, action: #selector(Coordinator.handleRefresh(_:)))
        finalWebView.scrollView.delegate = context.coordinator

        // ✨ 로딩 상태 동기화를 위한 KVO 옵저버 추가
        context.coordinator.setupLoadingObservers(for: finalWebView)

        // 초기 로드
        if let url = stateModel.currentURL {
            finalWebView.load(URLRequest(url: url))
        } else {
            finalWebView.load(URLRequest(url: URL(string: "about:blank")!))
        }

        // 외부 제어용 Notification 옵저버 등록
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleExternalOpenURL(_:)),
            name: .init("ExternalOpenURL"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.reloadWebView),
            name: .init("WebViewReload"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.goBack),
            name: .init("WebViewGoBack"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.goForward),
            name: .init("WebViewGoForward"),
            object: nil
        )

        // 🎯 **새로 추가**: 캐시된 페이지 로드 전 미리보기 옵저버
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleShowCachedPageBeforeLoad(_:)),
            name: .init("ShowCachedPageBeforeLoad"),
            object: nil
        )

        // 📁 **다운로드 오버레이 헬퍼 호출**
        installDownloadOverlay(on: finalWebView, 
                              overlayContainer: &context.coordinator.overlayContainer,
                              overlayTitleLabel: &context.coordinator.overlayTitleLabel,
                              overlayPercentLabel: &context.coordinator.overlayPercentLabel,
                              overlayProgress: &context.coordinator.overlayProgress)

        // 📁 **다운로드 관련 이벤트 옵저버 등록 (헬퍼와 연동)**
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadStart(_:)),
                                               name: .WebViewDownloadStart,
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadProgress(_:)),
                                               name: .WebViewDownloadProgress,
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadFinish(_:)),
                                               name: .WebViewDownloadFinish,
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadFailed(_:)),
                                               name: .WebViewDownloadFailed,
                                               object: nil)

        // 🎬 **PIP 관련 옵저버 등록**
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handlePIPStart(_:)),
                                               name: .init("StartPIPForTab"),
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handlePIPStop(_:)),
                                               name: .init("StopPIPForTab"),
                                               object: nil)

        return finalWebView
    }

    // MARK: - updateUIView
 func updateUIView(_ uiView: WKWebView, context: Context) {
    // 연결 상태 확인 및 재연결
    if uiView.uiDelegate !== context.coordinator {
        uiView.uiDelegate = context.coordinator
    }
    if context.coordinator.webView !== uiView {
        context.coordinator.webView = uiView
    }
    // ✅ navigationDelegate가 항상 dataModel로 연결되어 있어야 함
    if uiView.navigationDelegate !== stateModel.dataModel {
        uiView.navigationDelegate = stateModel.dataModel
    }

    // ✅ 하단 UI 겹치기를 위한 투명 설정 유지 (헬퍼 호출)
    maintainTransparentWebView(uiView)
    
    // ✨ 데스크탑 모드 변경 시 페이지 새로고침으로 스크립트 적용 (헬퍼 호출)
    updateDesktopModeIfNeeded(webView: uiView, stateModel: stateModel, lastDesktopMode: &context.coordinator.lastDesktopMode)
}


    // MARK: - teardown
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // 🏊‍♂️ **핵심 3: 웹뷰 해체 시 풀로 이동 (PIP 보호 고려)**
        if let tabID = coordinator.parent.stateModel.tabID {
            // 탭 닫기 처리 (PIP 보호 확인)
            _ = WebViewPool.shared.handleTabClose(tabID)
            TabPersistenceManager.debugMessages.append("🏊‍♂️ 웹뷰 해체 - 풀 처리: 탭 \(String(tabID.uuidString.prefix(8)))")
        }

        // KVO 옵저버 제거
        coordinator.removeLoadingObservers(for: uiView)

        // 스크롤/델리게이트 해제
        uiView.scrollView.delegate = nil
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil // 📁 네비게이션 델리게이트도 해제
        coordinator.webView = nil

        // 📸 제스처 제거
        coordinator.removeSyncedSwipeGesture(from: uiView)

        // 🎯 캐시된 페이지 미리보기 시스템 해제
        coordinator.teardownCachedPagePreview()

        // 오디오 세션 비활성화 (헬퍼 호출)
        deactivateAudioSession()

        // 메시지 핸들러 제거
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "playVideo")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "setZoom")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "spaNavigation")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "saveImage")

        // 모든 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {

        var parent: CustomWebView
        weak var webView: WKWebView?

        // ✨ 데스크탑 모드 변경 감지용 플래그
        var lastDesktopMode: Bool = false

        // 📸 고급 페이지 캐시 (애니메이션용)
        private var pageCache = AdvancedPageCache()
        private var leftEdgeGesture: UIScreenEdgePanGestureRecognizer?
        private var rightEdgeGesture: UIScreenEdgePanGestureRecognizer?
        
        // 제스처 오버레이
        private var gestureContainer: UIView?
        private var currentPageView: UIImageView?
        private var nextPageView: UIView?
        
        // 제스처 상태
        private var isSwipeInProgress = false
        private var swipeDirection: SwipeDirection?
        private var targetPageRecord: PageRecord?
        
        // 🎯 **새로 추가**: 캐시된 페이지 미리보기 시스템
        private var cachedPreviewContainer: UIView?
        private var cachedPreviewImageView: UIImageView?
        private var isShowingCachedPreview = false
        
        // 🛡️ **핵심 추가**: 캐시 실패 복구 시스템
        private var cachedPreviewTimer: Timer?
        private var cachedPreviewStartTime: Date?
        private var expectedNavigationURL: URL?
        
        enum SwipeDirection {
            case back    // 뒤로가기 (왼쪽 에지에서)
            case forward // 앞으로가기 (오른쪽 에지에서)
        }

        // 📁 **다운로드 진행률 UI 구성 요소들 (헬퍼가 관리)**
        var overlayContainer: UIVisualEffectView?
        var overlayTitleLabel: UILabel?
        var overlayPercentLabel: UILabel?
        var overlayProgress: UIProgressView?

        // ✨ KVO 옵저버들
        private var loadingObserver: NSKeyValueObservation?
        private var urlObserver: NSKeyValueObservation?
        private var titleObserver: NSKeyValueObservation?
        private var progressObserver: NSKeyValueObservation?

        init(_ parent: CustomWebView) {
            self.parent = parent
            self.lastDesktopMode = parent.stateModel.isDesktopMode
            super.init()
        }

        deinit {
            removeLoadingObservers(for: webView)
            NotificationCenter.default.removeObserver(self)
            
            // 🛡️ 캐시 복구 타이머 정리
            cachedPreviewTimer?.invalidate()
            cachedPreviewTimer = nil
        }

        // MARK: - 🎬 **PIP 이벤트 핸들러 추가**
        
        @objc func handlePIPStart(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let tabID = userInfo["tabID"] as? UUID,
                  let url = userInfo["url"] as? URL,
                  tabID == parent.stateModel.tabID else { return }
            
            // PIP 시작 - PIPManager에 알림
            PIPManager.shared.startPIP(for: tabID, with: url)
            TabPersistenceManager.debugMessages.append("🎬 PIP 시작 요청 수신: 탭 \(String(tabID.uuidString.prefix(8)))")
        }
        
        @objc func handlePIPStop(_ notification: Notification) {
            guard let tabID = parent.stateModel.tabID else { return }
            
            // PIP 종료 - PIPManager에 알림
            PIPManager.shared.stopPIP()
            TabPersistenceManager.debugMessages.append("🎬 PIP 종료 요청 수신: 탭 \(String(tabID.uuidString.prefix(8)))")
        }

        // MARK: - 🎯 **새로 추가**: 캐시된 페이지 미리보기 시스템
        
        func setupCachedPagePreview(for webView: WKWebView) {
    // 캐시된 페이지 미리보기용 컨테이너 생성
    let container = UIView()
    container.backgroundColor = .systemBackground
    container.isHidden = true
    container.translatesAutoresizingMaskIntoConstraints = false
    container.isUserInteractionEnabled = false // ✅ 미리보기가 터치를 가로채지 않도록 비활성화
    webView.addSubview(container)
    
    NSLayoutConstraint.activate([
        container.topAnchor.constraint(equalTo: webView.topAnchor),
        container.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
        container.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
        container.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
    ])
    
    // 캐시된 이미지뷰
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(imageView)
    
    NSLayoutConstraint.activate([
        imageView.topAnchor.constraint(equalTo: container.topAnchor),
        imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
    
    self.cachedPreviewContainer = container
    self.cachedPreviewImageView = imageView
    
    print("📸 캐시된 페이지 미리보기 시스템 설정 완료")
}

        
        func teardownCachedPagePreview() {
            // 🛡️ 타이머 정리
            cachedPreviewTimer?.invalidate()
            cachedPreviewTimer = nil
            
            cachedPreviewContainer?.removeFromSuperview()
            cachedPreviewContainer = nil
            cachedPreviewImageView = nil
            isShowingCachedPreview = false
            cachedPreviewStartTime = nil
            expectedNavigationURL = nil
        }
        
        // 🎯 **핵심**: 히스토리 네비게이션 시 캐시된 페이지 먼저 표시 + 🛡️ 복구 시스템
        @objc func handleShowCachedPageBeforeLoad(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let url = userInfo["url"] as? URL,
                  let _ = userInfo["direction"] as? String,
                  let _ = webView,
                  let container = cachedPreviewContainer,
                  let imageView = cachedPreviewImageView else { return }
            
            // 🛡️ 이전 복구 타이머 정리
            cachedPreviewTimer?.invalidate()
            cachedPreviewTimer = nil
            
            // 예상 네비게이션 URL 설정
            expectedNavigationURL = url
            
            // 캐시에서 해당 페이지 찾기
            if let cachedPage = pageCache.getCachedPage(for: url) {
                DispatchQueue.main.async {
                    // 캐시된 이미지 설정
                    imageView.image = cachedPage.snapshot
                    
                    // 미리보기 컨테이너 표시
                    container.isHidden = false
                    container.alpha = 0.0
                    
                    // 부드럽게 페이드 인
                    UIView.animate(withDuration: 0.2) {
                        container.alpha = 1.0
                    }
                    
                    self.isShowingCachedPreview = true
                    self.cachedPreviewStartTime = Date()
                    print("📸 캐시된 페이지 즉시 표시: \(cachedPage.title)")
                    
                    // 🛡️ **핵심**: 복구 시스템 시작
                    self.startCacheRecoverySystem(expectedURL: url)
                }
            } else {
                print("📸 캐시된 페이지 없음: \(url.absoluteString)")
                
                // 캐시가 없으면 로딩 인디케이터 대신 빈 페이지 표시
                DispatchQueue.main.async {
                    imageView.image = nil
                    container.backgroundColor = .systemBackground
                    container.isHidden = false
                    container.alpha = 0.0
                    
                    UIView.animate(withDuration: 0.1) {
                        container.alpha = 1.0
                    }
                    
                    self.isShowingCachedPreview = true
                    self.cachedPreviewStartTime = Date()
                    self.expectedNavigationURL = url
                    
                    // 🛡️ 캐시 없을 때도 복구 시스템 시작 (더 빠른 전환)
                    self.startCacheRecoverySystem(expectedURL: url, fastMode: true)
                }
            }
        }
        
        // 🛡️ **핵심 추가**: 캐시 실패 복구 시스템
        private func startCacheRecoverySystem(expectedURL: URL, fastMode: Bool = false) {
            // 기존 타이머 정리
            cachedPreviewTimer?.invalidate()
            
            // 복구 시간 설정 (캐시 있으면 4초, 없으면 1초)
            let recoveryDelay: TimeInterval = fastMode ? 1.0 : 4.0
            
            cachedPreviewTimer = Timer.scheduledTimer(withTimeInterval: recoveryDelay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                
                print("🛡️ 캐시 복구 시스템 작동: \(recoveryDelay)초 후 실제 페이지 미표시")
                
                // 여전히 캐시 미리보기가 표시 중이면 복구 조치
                if self.isShowingCachedPreview {
                    self.performCacheRecovery(expectedURL: expectedURL)
                }
            }
        }
        
        // 🛡️ 캐시 복구 실행
        private func performCacheRecovery(expectedURL: URL) {
            TabPersistenceManager.debugMessages.append("🛡️ 캐시 실패 복구 시작: \(expectedURL.absoluteString)")
            
            // 1. 캐시된 미리보기 즉시 숨김
            self.hideCachedPreview(immediate: true)
            
            // 2. 웹뷰 강제 리로드
            guard let webView = self.webView else { return }
            
            DispatchQueue.main.async {
                // 현재 URL이 예상과 다르거나 로딩이 안되고 있으면 강제 로드
                let currentURL = webView.url
                let needsForcedLoad = currentURL?.absoluteString != expectedURL.absoluteString || 
                                    (!webView.isLoading && !self.parent.stateModel.isLoading)
                
                if needsForcedLoad {
                    TabPersistenceManager.debugMessages.append("🛡️ 강제 페이지 로드 실행: \(expectedURL.absoluteString)")
                    
                    // 조용한 새로고침 플래그 해제하고 일반 로드
                    self.parent.stateModel.setSilentRefresh(false)
                    self.parent.stateModel.setInstantNavigation(false)
                    
                    // 새 요청으로 강제 로드
                    let request = URLRequest(url: expectedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10.0)
                    webView.load(request)
                    
                    TabPersistenceManager.debugMessages.append("🛡️ 캐시 무시하고 강제 로드 완료")
                } else {
                    TabPersistenceManager.debugMessages.append("🛡️ 페이지 로딩 정상 진행 중, 대기")
                }
            }
        }
        
        // 실제 페이지 로딩 완료 감지 (기존 로직 개선)
        private func startWatchingForRealPageLoad() {
            // 🛡️ 다중 체크 시스템으로 강화
            let checkIntervals: [TimeInterval] = [0.5, 1.0, 2.0] // 0.5초, 1초, 2초 후 체크
            
            for (index, interval) in checkIntervals.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                    guard let self = self else { return }
                    
                    // 로딩이 완료되고 URL이 일치하면 미리보기 숨김
                    if self.isShowingCachedPreview && !self.parent.stateModel.isLoading {
                        if let expectedURL = self.expectedNavigationURL,
                           let currentURL = self.webView?.url,
                           currentURL.absoluteString == expectedURL.absoluteString {
                            
                            print("🛡️ 실제 페이지 로딩 완료 감지 (\(index + 1)차): \(currentURL.absoluteString)")
                            self.hideCachedPreview()
                            return
                        }
                    }
                    
                    // 마지막 체크에서도 실패하면 복구 시스템 호출
                    if index == checkIntervals.count - 1 && self.isShowingCachedPreview {
                        if let expectedURL = self.expectedNavigationURL {
                            print("🛡️ 최종 체크 실패, 복구 시스템 호출")
                            self.performCacheRecovery(expectedURL: expectedURL)
                        }
                    }
                }
            }
        }
        
        // 캐시된 미리보기 숨김 (개선)
        private func hideCachedPreview(immediate: Bool = false) {
            guard isShowingCachedPreview,
                  let container = cachedPreviewContainer else { return }
            
            // 🛡️ 복구 타이머 정리
            cachedPreviewTimer?.invalidate()
            cachedPreviewTimer = nil
            
            let duration = immediate ? 0.0 : 0.3
            
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseInOut) {
                container.alpha = 0.0
            } completion: { _ in
                container.isHidden = true
                self.isShowingCachedPreview = false
                self.cachedPreviewStartTime = nil
                self.expectedNavigationURL = nil
                
                let hideType = immediate ? "즉시" : "부드럽게"
                print("📸 캐시된 미리보기 숨김 완료 (\(hideType))")
            }
        }

        // MARK: - 📸 수정된 제스처 설정 (커스텀 시스템과 완전 동기화)
        func setupSyncedSwipeGesture(for webView: WKWebView) {
            // 제스처 컨테이너 생성
            let container = UIView()
            container.backgroundColor = .clear
            container.isUserInteractionEnabled = false
            container.translatesAutoresizingMaskIntoConstraints = false
            webView.addSubview(container)
            
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: webView.topAnchor),
                container.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
                container.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
            ])
            
            self.gestureContainer = container
            
            // 왼쪽 에지 제스처 (뒤로가기)
            let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleSyncedEdgeGesture(_:)))
            leftEdge.edges = .left
            leftEdge.delegate = self
            webView.addGestureRecognizer(leftEdge)
            self.leftEdgeGesture = leftEdge
            
            // 오른쪽 에지 제스처 (앞으로가기)
            let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleSyncedEdgeGesture(_:)))
            rightEdge.edges = .right
            rightEdge.delegate = self
            webView.addGestureRecognizer(rightEdge)
            self.rightEdgeGesture = rightEdge
            
            print("📸 커스텀 시스템 동기화 제스처 설정 완료")
        }
        
        func removeSyncedSwipeGesture(from webView: WKWebView) {
            if let gesture = leftEdgeGesture {
                webView.removeGestureRecognizer(gesture)
                self.leftEdgeGesture = nil
            }
            if let gesture = rightEdgeGesture {
                webView.removeGestureRecognizer(gesture)
                self.rightEdgeGesture = nil
            }
            gestureContainer?.removeFromSuperview()
            gestureContainer = nil
        }
        
        // MARK: - 📸 수정된 에지 제스처 핸들러 (완전 동기화)
        @objc private func handleSyncedEdgeGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard let webView = gesture.view as? WKWebView,
                  let container = gestureContainer else { return }
            
            let translation = gesture.translation(in: webView)
            let velocity = gesture.velocity(in: webView)
            let isLeftEdge = (gesture.edges == .left)
            
            switch gesture.state {
            case .began:
                let direction: SwipeDirection = isLeftEdge ? .back : .forward
                let canNavigate = direction == .back ? parent.stateModel.canGoBack : parent.stateModel.canGoForward
                
                if canNavigate && !isSwipeInProgress {
                    isSwipeInProgress = true
                    swipeDirection = direction
                    print("📸 동기화 제스처 시작: \(direction == .back ? "뒤로" : "앞으로")")
                    
                    startSyncedSwipePreview(direction: direction, webView: webView, container: container)
                } else {
                    print("📸 제스처 불가: \(direction == .back ? "뒤로" : "앞으로")")
                }
                
            case .changed:
                guard isSwipeInProgress,
                      let direction = swipeDirection else { return }
                
                // 에지 방향에 맞는 이동만 허용
                let validMovement = (direction == .back && translation.x > 0) || (direction == .forward && translation.x < 0)
                if !validMovement { return }
                
                let progress = min(abs(translation.x) / webView.bounds.width, 1.0)
                updateSyncedSwipePreview(progress: progress, translation: translation, direction: direction)
                
                // 30% 지점에서 햅틱
                if progress > 0.3 && progress < 0.35 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                
            case .ended:
                guard isSwipeInProgress else { return }
                
                let progress = abs(translation.x) / webView.bounds.width
                let shouldComplete = progress > 0.4 || abs(velocity.x) > 800
                
                if shouldComplete {
                    completeSyncedSwipe(webView: webView)
                } else {
                    cancelSyncedSwipe(webView: webView)
                }
                
            case .cancelled, .failed:
                if isSwipeInProgress {
                    cancelSyncedSwipe(webView: webView)
                }
                
            default:
                break
            }
        }
        
        // MARK: - 동기화된 스와이프 미리보기 시작
        private func startSyncedSwipePreview(direction: SwipeDirection, webView: WKWebView, container: UIView) {
            // 현재 페이지 스냅샷 생성
            webView.takeSnapshot(with: nil) { [weak self] image, error in
                guard let self = self, let image = image else {
                    self?.isSwipeInProgress = false
                    return
                }
                
                // 📸 현재 페이지 캐시에 저장
                if let url = self.parent.stateModel.currentURL,
                   let title = webView.title {
                    self.pageCache.cachePage(url: url, snapshot: image, title: title)
                }
                
                DispatchQueue.main.async {
                    self.showSyncedSwipePreview(currentImage: image, direction: direction, container: container)
                }
            }
        }
        
        private func showSyncedSwipePreview(currentImage: UIImage, direction: SwipeDirection, container: UIView) {
            // 현재 페이지 이미지뷰
            let currentView = UIImageView(image: currentImage)
            currentView.contentMode = .scaleAspectFill
            currentView.clipsToBounds = true
            currentView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(currentView)
            
            NSLayoutConstraint.activate([
                currentView.topAnchor.constraint(equalTo: container.topAnchor),
                currentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                currentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                currentView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            
            self.currentPageView = currentView
            
            // 다음 페이지 찾기 (커스텀 히스토리에서)
            let dataModel = parent.stateModel.dataModel
            var targetRecord: PageRecord?
            
            if direction == .back && dataModel.canGoBack && dataModel.currentPageIndex > 0 {
                targetRecord = dataModel.pageHistory[dataModel.currentPageIndex - 1]
            } else if direction == .forward && dataModel.canGoForward && dataModel.currentPageIndex < dataModel.pageHistory.count - 1 {
                targetRecord = dataModel.pageHistory[dataModel.currentPageIndex + 1]
            }
            
            self.targetPageRecord = targetRecord
            
            // 다음 페이지 뷰 생성 (캐시 우선 사용)
            let nextView = createCachedNextPageView(for: targetRecord, direction: direction)
            container.addSubview(nextView)
            
            NSLayoutConstraint.activate([
                nextView.topAnchor.constraint(equalTo: container.topAnchor),
                nextView.widthAnchor.constraint(equalTo: container.widthAnchor),
                nextView.heightAnchor.constraint(equalTo: container.heightAnchor),
                direction == .back ?
                    nextView.trailingAnchor.constraint(equalTo: container.leadingAnchor) :
                    nextView.leadingAnchor.constraint(equalTo: container.trailingAnchor)
            ])
            
            self.nextPageView = nextView
            container.layoutIfNeeded()
        }
        
        private func createCachedNextPageView(for record: PageRecord?, direction: SwipeDirection) -> UIView {
            guard let record = record else {
                return createEmptyPageView(direction: direction)
            }
            
            // 캐시된 스냅샷 확인
            if let cachedPage = pageCache.getCachedPage(for: record.url) {
                let imageView = UIImageView(image: cachedPage.snapshot)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                print("📸 캐시된 스냅샷 사용: \(record.title)")
                return imageView
            }
            
            // 캐시가 없으면 페이지 정보 카드 생성
            return createPageInfoCard(for: record, direction: direction)
        }
        
        private func createPageInfoCard(for record: PageRecord, direction: SwipeDirection) -> UIView {
            let cardView = UIView()
            cardView.backgroundColor = .systemBackground
            
            // 제목
            let titleLabel = UILabel()
            titleLabel.text = record.title
            titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
            titleLabel.textAlignment = .center
            titleLabel.numberOfLines = 0
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            
            // URL
            let urlLabel = UILabel()
            urlLabel.text = record.url.host ?? record.url.absoluteString
            urlLabel.font = .systemFont(ofSize: 16)
            urlLabel.textColor = .secondaryLabel
            urlLabel.textAlignment = .center
            urlLabel.numberOfLines = 2
            urlLabel.translatesAutoresizingMaskIntoConstraints = false
            
            // 아이콘
            let iconView = UIImageView(image: UIImage(systemName: "safari"))
            iconView.tintColor = .systemBlue
            iconView.contentMode = .scaleAspectFit
            iconView.translatesAutoresizingMaskIntoConstraints = false
            
            // 방향 표시
            let directionLabel = UILabel()
            directionLabel.text = direction == .back ? "← 이전 페이지" : "다음 페이지 →"
            directionLabel.font = .systemFont(ofSize: 14, weight: .medium)
            directionLabel.textColor = .systemBlue
            directionLabel.textAlignment = .center
            directionLabel.translatesAutoresizingMaskIntoConstraints = false
            
            cardView.addSubview(iconView)
            cardView.addSubview(titleLabel)
            cardView.addSubview(urlLabel)
            cardView.addSubview(directionLabel)
            
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor, constant: -60),
                iconView.widthAnchor.constraint(equalToConstant: 60),
                iconView.heightAnchor.constraint(equalToConstant: 60),
                
                titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 20),
                titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 40),
                titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -40),
                
                urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
                urlLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 40),
                urlLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -40),
                
                directionLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 20),
                directionLabel.centerXAnchor.constraint(equalTo: cardView.centerXAnchor)
            ])
            
            return cardView
        }
        
        private func createEmptyPageView(direction: SwipeDirection) -> UIView {
            let emptyView = UIView()
            emptyView.backgroundColor = .systemBackground
            
            let label = UILabel()
            label.text = "더 이상 페이지가 없습니다"
            label.font = .systemFont(ofSize: 18)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            
            emptyView.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor)
            ])
            
            return emptyView
        }
        
        // MARK: - 스와이프 미리보기 업데이트
        private func updateSyncedSwipePreview(progress: CGFloat, translation: CGPoint, direction: SwipeDirection) {
            guard let currentView = currentPageView,
                  let nextView = nextPageView else { return }
            
            let screenWidth = UIScreen.main.bounds.width
            
            // 현재 페이지 이동
            currentView.transform = CGAffineTransform(translationX: translation.x, y: 0)
            
            // 다음 페이지 이동
            if direction == .back {
                // 뒤로가기: 이전 페이지가 따라옴
                nextView.transform = CGAffineTransform(translationX: -screenWidth + translation.x, y: 0)
            } else {
                // 앞으로가기: 다음 페이지가 따라옴
                nextView.transform = CGAffineTransform(translationX: screenWidth + translation.x, y: 0)
            }
        }
        
        
        // MARK: - 📸 수정된 스와이프 완료 (WebKit 실제 이동 + 캐시 미리보기 선표출)
private func completeSyncedSwipe(webView: WKWebView) {
    guard let currentView = currentPageView,
          let nextView = nextPageView,
          let direction = swipeDirection else { return }
    
    UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
        let screenWidth = UIScreen.main.bounds.width
        
        if direction == .back {
            currentView.transform = CGAffineTransform(translationX: screenWidth, y: 0)
            nextView.transform = .identity
        } else {
            currentView.transform = CGAffineTransform(translationX: -screenWidth, y: 0)
            nextView.transform = .identity
        }
    } completion: { _ in
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // ✅ 이동 대상 URL로 캐시 미리보기 먼저 노출
        if let record = self.targetPageRecord {
            NotificationCenter.default.post(
                name: .init("ShowCachedPageBeforeLoad"),
                object: nil,
                userInfo: [
                    "url": record.url,
                    "direction": (direction == .back ? "back" : "forward")
                ]
            )
        }
        
        // ✅ 실제 WebKit 히스토리 이동을 수행 (주소만 바뀌고 화면이 안 바뀌던 문제의 근본 해결)
        if direction == .back {
            if webView.canGoBack {
                webView.goBack()
            } else if let r = self.targetPageRecord {
                let req = URLRequest(
                    url: r.url,
                    cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                    timeoutInterval: 10
                )
                webView.load(req) // 백스택이 비어 있으면 강제 로드
            }
        } else {
            if webView.canGoForward {
                webView.goForward()
            } else if let r = self.targetPageRecord {
                let req = URLRequest(
                    url: r.url,
                    cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                    timeoutInterval: 10
                )
                webView.load(req) // 포워드스택이 비어 있으면 강제 로드
            }
        }
        
        // ❗ stateModel.goBack()/goForward()는 호출하지 않음.
        //    WebKit이 실제 네비게이션을 수행하고,
        //    KVO/url/title/navDelegate에서 상태가 동기화됨.
        
        self.cleanupSwipe()
        print("📸 동기화 제스처 완료(실제 네비게이션 수행): \(direction == .back ? "뒤로" : "앞으로")")
    }
}

        
        // MARK: - 📸 수정된 스와이프 취소
        private func cancelSyncedSwipe(webView: WKWebView) {
            guard let currentView = currentPageView,
                  let nextView = nextPageView,
                  let direction = swipeDirection else { return }
            
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
                currentView.transform = .identity
                
                let screenWidth = UIScreen.main.bounds.width
                if direction == .back {
                    nextView.transform = CGAffineTransform(translationX: -screenWidth, y: 0)
                } else {
                    nextView.transform = CGAffineTransform(translationX: screenWidth, y: 0)
                }
            } completion: { _ in
                self.cleanupSwipe()
                print("📸 동기화 제스처 취소")
            }
        }
        
        // MARK: - 스와이프 정리
        private func cleanupSwipe() {
            currentPageView?.removeFromSuperview()
            nextPageView?.removeFromSuperview()
            currentPageView = nil
            nextPageView = nil
            isSwipeInProgress = false
            swipeDirection = nil
            targetPageRecord = nil
        }
        
        // MARK: - UIGestureRecognizerDelegate
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 에지 제스처는 스크롤과 충돌하지 않음
            return true
        }
        
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === leftEdgeGesture || gestureRecognizer === rightEdgeGesture {
                return !isSwipeInProgress
            }
            return true
        }

       func setupLoadingObservers(for webView: WKWebView) {
    loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
        guard let self = self else { return }
        let isLoading = change.newValue ?? false

        DispatchQueue.main.async {
            // ✅ [추가] 실제 로딩이 '시작'되면 캐시 미리보기를 즉시 내린다.
            // - 이유: isLoading=true 신호가 들어왔다는 것은 WebKit이 실제 페인트/커밋을 진행한다는 뜻.
            //         이 타이밍에 미리보기를 계속 띄워두면 복구 타이머와 경합하거나 화면을 가리는 착시가 발생한다.
            if isLoading && self.isShowingCachedPreview {
                self.hideCachedPreview(immediate: false)
            }

            // 🎯 조용한 새로고침 시에는 로딩 상태 변경하지 않음 (기존 보존)
            if !self.parent.stateModel.isSilentRefresh && self.parent.stateModel.isLoading != isLoading {
                self.parent.stateModel.isLoading = isLoading
            }
            
            // 🛡️ 로딩 '완료' 시 캐시 미리보기 마무리 처리 (기존 보존)
            if !isLoading && self.isShowingCachedPreview {
                if let expectedURL = self.expectedNavigationURL,
                   let currentURL = webView.url {
                    if currentURL.absoluteString == expectedURL.absoluteString {
                        // URL 일치 → 자연스러운 페이드아웃
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.hideCachedPreview()
                        }
                    } else {
                        // URL 불일치 → 복구 루트 (기존 보존)
                        self.performCacheRecovery(expectedURL: expectedURL)
                    }
                } else {
                    // URL 정보 없음 → 안전하게 숨김 (기존 보존)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.hideCachedPreview()
                    }
                }
            }
            
            // 로딩 완료 후 현재 페이지 스냅샷 저장 (기존 보존)
            if !isLoading && !self.isSwipeInProgress {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.saveCurrentPageToCache(webView: webView)
                }
            }
        }
    }

    // 진행률 KVO (기존 보존)
    progressObserver = webView.observe(\.estimatedProgress, options: [.new, .initial]) { [weak self] webView, change in
        guard let self = self else { return }
        let progress = change.newValue ?? 0.0

        DispatchQueue.main.async {
            // 🎯 조용한 새로고침 시에는 진행률 업데이트하지 않음
            if !self.parent.stateModel.isSilentRefresh {
                let newProgress = max(0.0, min(1.0, progress))
                self.parent.stateModel.loadingProgress = newProgress
            }
        }
    }

    // URL KVO (기존 보존)
    urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
        guard let self = self, let newURL = change.newValue, let url = newURL else { return }

        DispatchQueue.main.async {
            if self.parent.stateModel.currentURL != url && !self.isSwipeInProgress {
                self.parent.stateModel.setNavigatingFromWebView(true)
                self.parent.stateModel.currentURL = url
                self.parent.stateModel.setNavigatingFromWebView(false)
                
                // 미리보기 성공 확인 로그 등 (기존 보존)
                if self.isShowingCachedPreview,
                   let expectedURL = self.expectedNavigationURL,
                   url.absoluteString == expectedURL.absoluteString {
                    print("🛡️ URL 변경으로 캐시 미리보기 성공 확인: \(url.absoluteString)")
                }
            }
        }
    }

    // Title KVO (기존 보존)
    titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, change in
        guard let self = self,
              let title = change.newValue,
              let title = title,
              !title.isEmpty,
              let currentURL = webView.url else { return }

        DispatchQueue.main.async {
            // 🔧 URL 기반 제목 업데이트 (기존 보존)
            self.parent.stateModel.dataModel.updatePageTitle(for: currentURL, title: title)
        }
    }
}



        func removeLoadingObservers(for webView: WKWebView?) {
            loadingObserver?.invalidate()
            urlObserver?.invalidate()
            titleObserver?.invalidate()
            progressObserver?.invalidate()
            loadingObserver = nil
            urlObserver = nil
            titleObserver = nil
            progressObserver = nil
        }
        
        // MARK: - 📸 현재 페이지를 캐시에 저장 (스냅샷만)
        private func saveCurrentPageToCache(webView: WKWebView) {
            guard let currentURL = parent.stateModel.currentURL,
                  let title = webView.title else { return }
            
            // 스냅샷만 캐시 (HTML은 제거)
            webView.takeSnapshot(with: nil) { [weak self] image, error in
                guard let self = self, let snapshot = image else { return }
                
                DispatchQueue.main.async {
                    self.pageCache.cachePage(url: currentURL, snapshot: snapshot, title: title)
                }
            }
        }

        // MARK: - 🌐 통합된 JS 메시지 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo" {
                if let urlString = message.body as? String, let url = URL(string: urlString) {
                    DispatchQueue.main.async {
                        self.parent.playerURL = url
                        self.parent.showAVPlayer = true
                        
                        // 🎬 **PIP 시작 알림 추가**
                        if let tabID = self.parent.stateModel.tabID {
                            PIPManager.shared.startPIP(for: tabID, with: url)
                            TabPersistenceManager.debugMessages.append("🎬 비디오 재생으로 PIP 시작: 탭 \(String(tabID.uuidString.prefix(8)))")
                        }
                    }
                }
            } else if message.name == "setZoom" {
                if let data = message.body as? [String: Any],
                   let zoom = data["zoom"] as? Double {
                    DispatchQueue.main.async {
                        self.parent.stateModel.currentZoomLevel = zoom
                    }
                }
            } else if message.name == "spaNavigation" {
                if let data = message.body as? [String: Any],
                   let type = data["type"] as? String,
                   let urlString = data["url"] as? String,
                   let url = URL(string: urlString) {
                    
                    let title = data["title"] as? String ?? ""
                    let timestamp = data["timestamp"] as? Double ?? Date().timeIntervalSince1970 * 1000
                    let shouldExclude = data["shouldExclude"] as? Bool ?? false
                    let siteType = data["siteType"] as? String ?? "unknown"
                    
                    DispatchQueue.main.async {
                        if shouldExclude {
                            return
                        }
                        
                        self.parent.stateModel.dataModel.handleSPANavigation(
                            type: type,
                            url: url,
                            title: title,
                            timestamp: timestamp,
                            siteType: siteType
                        )
                    }
                }
            }
        }

        // MARK: Pull to Refresh (헬퍼 호출)
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            handleWebViewRefresh(sender, webView: webView)
        }

        // MARK: 외부 URL 오픈
        @objc func handleExternalOpenURL(_ note: Notification) {
            guard
                let userInfo = note.userInfo,
                let url = userInfo["url"] as? URL,
                let webView = webView
            else { return }
            webView.load(URLRequest(url: url))
        }

        // MARK: 네비게이션 명령
        @objc func reloadWebView() { 
            webView?.reload()
        }
        @objc func goBack() { 
            parent.stateModel.goBack()
        }
        @objc func goForward() { 
            parent.stateModel.goForward()
        }

        // MARK: 스크롤 전달
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll?(scrollView.contentOffset.y)
        }

        // ✅ SSL 인증서 경고 처리 (헬퍼 호출)
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            handleSSLChallenge(webView: webView, challenge: challenge, stateModel: parent.stateModel, completionHandler: completionHandler)
        }

        // MARK: - 🚫 **핵심 추가: 팝업 차단 시스템 통합**
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            
            let sourceURL = webView.url
            let targetURL = navigationAction.request.url
            
            // 🚫 **팝업 차단 확인**
            if PopupBlockManager.shared.shouldBlockPopup(from: sourceURL, targetURL: targetURL) {
                // 팝업 차단 및 알림 발송
                PopupBlockManager.shared.blockPopup(from: sourceURL, targetURL: targetURL)
                
                TabPersistenceManager.debugMessages.append("🚫 팝업 차단됨: \(targetURL?.absoluteString ?? "알 수 없음")")
                
                // 팝업 차단 - nil 반환으로 새 창 생성 방지
                return nil
            }
            
            // 팝업 허용 - 현재 웹뷰에서 로드
            TabPersistenceManager.debugMessages.append("✅ 팝업 허용: \(targetURL?.absoluteString ?? "알 수 없음")")
            webView.load(navigationAction.request)
            return nil
        }
        
        // MARK: - 📷 이미지 저장 컨텍스트 메뉴 처리
        
        /// 웹뷰 컨텍스트 메뉴 커스터마이징
        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            
            // 이미지 요소인지 확인
            guard let url = elementInfo.linkURL ?? extractImageURL(from: elementInfo) else {
                completionHandler(nil)
                return
            }
            
            let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                return self.createImageContextMenu(for: url, webView: webView)
            }
            
            completionHandler(configuration)
        }
        
        /// 이미지 URL 추출
        private func extractImageURL(from elementInfo: WKContextMenuElementInfo) -> URL? {
            // iOS 15+에서 사용 가능한 방법
            if #available(iOS 15.0, *) {
                return elementInfo.linkURL
            }
            return nil
        }
        
        /// 이미지 컨텍스트 메뉴 생성
        private func createImageContextMenu(for url: URL, webView: WKWebView) -> UIMenu {
            var actions: [UIAction] = []
            
            // 이미지 저장 액션
            let saveAction = UIAction(
                title: "사진에 저장",
                image: UIImage(systemName: "square.and.arrow.down"),
                handler: { [weak self] _ in
                    self?.saveImageToPhotoLibrary(from: url)
                }
            )
            actions.append(saveAction)
            
            // 이미지 복사 액션
            let copyAction = UIAction(
                title: "이미지 복사",
                image: UIImage(systemName: "doc.on.doc"),
                handler: { [weak self] _ in
                    self?.copyImageToPasteboard(from: url)
                }
            )
            actions.append(copyAction)
            
            // 이미지 공유 액션
            let shareAction = UIAction(
                title: "공유",
                image: UIImage(systemName: "square.and.arrow.up"),
                handler: { [weak self] _ in
                    self?.shareImage(from: url)
                }
            )
            actions.append(shareAction)
            
            return UIMenu(title: "", children: actions)
        }
        
        /// 사진 라이브러리에 이미지 저장
        private func saveImageToPhotoLibrary(from url: URL) {
            // 1. 권한 확인
            checkPhotoLibraryPermission { [weak self] granted in
                guard granted else {
                    self?.showPermissionAlert()
                    return
                }
                
                // 2. 이미지 다운로드 및 저장
                self?.downloadAndSaveImage(from: url)
            }
        }
        
        /// 사진 라이브러리 권한 확인
        private func checkPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            
            switch status {
            case .authorized, .limited:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    DispatchQueue.main.async {
                        completion(newStatus == .authorized || newStatus == .limited)
                    }
                }
            @unknown default:
                completion(false)
            }
        }
        
        /// 이미지 다운로드 및 저장
        private func downloadAndSaveImage(from url: URL) {
            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.showErrorAlert(message: "이미지 다운로드 실패: \(error.localizedDescription)")
                        TabPersistenceManager.debugMessages.append("📷 이미지 다운로드 실패: \(error.localizedDescription)")
                        return
                    }
                    
                    guard let data = data, let image = UIImage(data: data) else {
                        self?.showErrorAlert(message: "이미지 변환에 실패했습니다.")
                        TabPersistenceManager.debugMessages.append("📷 이미지 변환 실패")
                        return
                    }
                    
                    self?.saveImageToLibrary(image)
                }
            }.resume()
        }
        
        /// 실제 이미지 저장
        private func saveImageToLibrary(_ image: UIImage) {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { [weak self] success, error in
                DispatchQueue.main.async {
                    if success {
                        self?.showSuccessAlert()
                        TabPersistenceManager.debugMessages.append("📷 이미지 저장 성공")
                    } else {
                        let errorMsg = error?.localizedDescription ?? "알 수 없는 오류"
                        self?.showErrorAlert(message: "이미지 저장 실패: \(errorMsg)")
                        TabPersistenceManager.debugMessages.append("📷 이미지 저장 실패: \(errorMsg)")
                    }
                }
            }
        }
        
        /// 이미지를 클립보드에 복사
        private func copyImageToPasteboard(from url: URL) {
            URLSession.shared.dataTask(with: url) { data, response, error in
                DispatchQueue.main.async {
                    guard let data = data, let image = UIImage(data: data) else {
                        TabPersistenceManager.debugMessages.append("📷 이미지 복사 실패")
                        return
                    }
                    
                    UIPasteboard.general.image = image
                    TabPersistenceManager.debugMessages.append("📷 이미지 클립보드 복사 완료")
                    
                    // 성공 피드백
                    let feedback = UIImpactFeedbackGenerator(style: .light)
                    feedback.impactOccurred()
                }
            }.resume()
        }
        
        /// 이미지 공유
        private func shareImage(from url: URL) {
            URLSession.shared.dataTask(with: url) { data, response, error in
                DispatchQueue.main.async {
                    guard let data = data, let image = UIImage(data: data) else {
                        TabPersistenceManager.debugMessages.append("📷 이미지 공유 실패")
                        return
                    }
                    
                    guard let topVC = getTopViewController() else { return }
                    
                    let activityVC = UIActivityViewController(activityItems: [image, url], applicationActivities: nil)
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    activityVC.popoverPresentationController?.sourceRect = topVC.view.bounds
                    
                    topVC.present(activityVC, animated: true)
                    TabPersistenceManager.debugMessages.append("📷 이미지 공유 시트 표시")
                }
            }.resume()
        }

       // MARK: - 알림 메시지들
        
        private func showPermissionAlert() {
            guard let topVC = getTopViewController() else { return }
            
            let alert = UIAlertController(
                title: "사진 접근 권한 필요",
                message: "이미지를 사진 앱에 저장하려면 사진 접근 권한이 필요합니다.\n\n설정 > 개인정보 보호 및 보안 > 사진에서 권한을 허용해주세요.",
                preferredStyle: .alert
            )
            
            alert.addAction(UIAlertAction(title: "설정으로 이동", style: .default) { _ in
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            })
            
            alert.addAction(UIAlertAction(title: "취소", style: .cancel))
            
            topVC.present(alert, animated: true)
        }
        
        private func showErrorAlert(message: String) {
            guard let topVC = getTopViewController() else { return }
            
            let alert = UIAlertController(
                title: "오류",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "확인", style: .default))
            topVC.present(alert, animated: true)
        }
        
        private func showSuccessAlert() {
            guard let topVC = getTopViewController() else { return }
            
            let alert = UIAlertController(
                title: "완료",
                message: "이미지가 사진 앱에 저장되었습니다.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "확인", style: .default))
            topVC.present(alert, animated: true)
            
            // 성공 피드백
            let feedback = UINotificationFeedbackGenerator()
            feedback.notificationOccurred(.success)
        }

        // MARK: 📁 **다운로드 이벤트 핸들러 (헬퍼 호출)**
        @objc func handleDownloadStart(_ note: Notification) {
            let filename = note.userInfo?["filename"] as? String
            showOverlay(filename: filename, overlayContainer: overlayContainer, overlayTitleLabel: overlayTitleLabel, overlayPercentLabel: overlayPercentLabel, overlayProgress: overlayProgress)
        }

        @objc func handleDownloadProgress(_ note: Notification) {
            let progress = note.userInfo?["progress"] as? Double ?? 0
            updateOverlay(progress: progress, overlayProgress: overlayProgress, overlayPercentLabel: overlayPercentLabel)
        }

        @objc func handleDownloadFinish(_ note: Notification) {
            hideOverlay(overlayContainer: overlayContainer)
        }

        @objc func handleDownloadFailed(_ note: Notification) {
            hideOverlay(overlayContainer: overlayContainer)
        }
    }
}
