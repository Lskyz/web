
//  CustomWebView.swift
//
//  📸 캐싱 기반 부드러운 히스토리 네비게이션 + 조용한 백그라운드 새로고침
//  🎯 제스처 완료 시 커스텀 시스템과 웹뷰를 모두 정상 동기화
//  🌐 완전형 SPA 네비게이션 & DOM 변경 감지 훅 통합
//  🔧 **제목 덮어쓰기 문제 해결** - titleObserver URL 검증 추가
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import Foundation
import Security

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

        // WKWebView 설정
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.processPool = WKProcessPool()

        // 사용자 스크립트/메시지 핸들러 (헬퍼 호출)
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())
        controller.addUserScript(makeDesktopModeScript())
        controller.addUserScript(WebViewDataModel.makeSPANavigationScript()) // 🔧 수정: 단순화된 버전 사용
        controller.add(context.coordinator, name: "playVideo")
        controller.add(context.coordinator, name: "setZoom")
        controller.add(context.coordinator, name: "spaNavigation")
        config.userContentController = controller

        // ✨ 다운로드 지원 (iOS 14+)
        if #available(iOS 14.0, *) {
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        }

        // WKWebView 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        
        // 🎯 네이티브 제스처 완전 비활성화
        webView.allowsBackForwardNavigationGestures = false
        
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.decelerationRate = .normal

        // ✅ 하단 UI 겹치기를 위한 투명 처리 (헬퍼 호출)
        setupTransparentWebView(webView)

        // ✨ Delegate 연결
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        stateModel.webView = webView
        
        // ✨ 초기 사용자 에이전트 설정 (헬퍼 호출)
        updateUserAgentIfNeeded(webView: webView, stateModel: stateModel)

        // 📸 스냅샷 기반 제스처 설정 (커스텀 시스템과 완전 동기화)
        context.coordinator.setupSyncedSwipeGesture(for: webView)

        // 🎯 **새로 추가**: 캐시된 페이지 미리보기 시스템 설정
        context.coordinator.setupCachedPagePreview(for: webView)

        // Pull to Refresh (헬퍼 호출)
        setupPullToRefresh(for: webView, target: context.coordinator, action: #selector(Coordinator.handleRefresh(_:)))
        webView.scrollView.delegate = context.coordinator

        // ✨ 로딩 상태 동기화를 위한 KVO 옵저버 추가
        context.coordinator.setupLoadingObservers(for: webView)

        // 초기 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        } else {
            webView.load(URLRequest(url: URL(string: "about:blank")!))
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

        // 다운로드 진행률 UI 오버레이 구성 (헬퍼 호출)
        installDownloadOverlay(on: webView, 
                              overlayContainer: &context.coordinator.overlayContainer,
                              overlayTitleLabel: &context.coordinator.overlayTitleLabel,
                              overlayPercentLabel: &context.coordinator.overlayPercentLabel,
                              overlayProgress: &context.coordinator.overlayProgress)

        // 다운로드 관련 이벤트 옵저버 등록
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

        return webView
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

        // ✅ 하단 UI 겹치기를 위한 투명 설정 유지 (헬퍼 호출)
        maintainTransparentWebView(uiView)
        
        // ✨ 데스크탑 모드 변경 시 페이지 새로고침으로 스크립트 적용 (헬퍼 호출)
        updateDesktopModeIfNeeded(webView: uiView, stateModel: stateModel, lastDesktopMode: &context.coordinator.lastDesktopMode)
    }

    // MARK: - teardown
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // KVO 옵저버 제거
        coordinator.removeLoadingObservers(for: uiView)

        // 스크롤/델리게이트 해제
        uiView.scrollView.delegate = nil
        uiView.uiDelegate = nil
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

        // 모든 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {

        var parent: CustomWebView
        weak var webView: WKWebView?
        var filePicker: FilePicker?

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
        
        enum SwipeDirection {
            case back    // 뒤로가기 (왼쪽 에지에서)
            case forward // 앞으로가기 (오른쪽 에지에서)
        }

        // 다운로드 진행률 UI 구성 요소들
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
        }

        // MARK: - 🎯 **새로 추가**: 캐시된 페이지 미리보기 시스템
        
        func setupCachedPagePreview(for webView: WKWebView) {
            // 캐시된 페이지 미리보기용 컨테이너 생성
            let container = UIView()
            container.backgroundColor = .systemBackground
            container.isHidden = true
            container.translatesAutoresizingMaskIntoConstraints = false
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
            cachedPreviewContainer?.removeFromSuperview()
            cachedPreviewContainer = nil
            cachedPreviewImageView = nil
            isShowingCachedPreview = false
        }
        
        // 🎯 **핵심**: 히스토리 네비게이션 시 캐시된 페이지 먼저 표시
        @objc func handleShowCachedPageBeforeLoad(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let url = userInfo["url"] as? URL,
                  let _ = userInfo["direction"] as? String,
                  let _ = webView,
                  let container = cachedPreviewContainer,
                  let imageView = cachedPreviewImageView else { return }
            
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
                    print("📸 캐시된 페이지 즉시 표시: \(cachedPage.title)")
                    
                    // 실제 페이지 로딩 완료 시 숨김 처리를 위한 타이머
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.startWatchingForRealPageLoad()
                    }
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
                    
                    // 빠르게 실제 페이지로 전환
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.hideCachedPreview()
                    }
                }
            }
        }
        
        // 실제 페이지 로딩 완료 감지
        private func startWatchingForRealPageLoad() {
            // 로딩이 완료되면 캐시된 미리보기 숨김
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.isShowingCachedPreview && !self.parent.stateModel.isLoading {
                    self.hideCachedPreview()
                }
            }
        }
        
        // 캐시된 미리보기 숨김
        private func hideCachedPreview() {
            guard isShowingCachedPreview,
                  let container = cachedPreviewContainer else { return }
            
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
                container.alpha = 0.0
            } completion: { _ in
                container.isHidden = true
                self.isShowingCachedPreview = false
                print("📸 캐시된 미리보기 숨김 완료")
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
        
        // MARK: - 📸 수정된 스와이프 완료 (커스텀 시스템과 웹뷰 완전 동기화)
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
                // 햅틱 피드백
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                
                // 🎯 핵심 수정: 커스텀 시스템을 통한 정상적인 네비게이션
                // 이렇게 하면 주소창 동기화, SPA 훅, 로그인 폼 모두 정상 작동
                if direction == .back {
                    self.parent.stateModel.goBack()
                } else {
                    self.parent.stateModel.goForward()
                }
                
                self.cleanupSwipe()
                print("📸 동기화 제스처 완료: \(direction == .back ? "뒤로" : "앞으로")")
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

        // MARK: - ✨ 로딩 상태 동기화를 위한 KVO 설정 (조용한 새로고침 지원)
        func setupLoadingObservers(for webView: WKWebView) {
            loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
                guard let self = self else { return }
                let isLoading = change.newValue ?? false

                DispatchQueue.main.async {
                    // 🎯 조용한 새로고침 시에는 로딩 상태 변경하지 않음
                    if !self.parent.stateModel.isSilentRefresh && self.parent.stateModel.isLoading != isLoading {
                        self.parent.stateModel.isLoading = isLoading
                    }
                    
                    // 🎯 로딩 완료 시 캐시된 미리보기 숨김
                    if !isLoading && self.isShowingCachedPreview {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.hideCachedPreview()
                        }
                    }
                    
                    // 로딩 완료 시 현재 페이지 스냅샷 저장
                    if !isLoading && !self.isSwipeInProgress {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.saveCurrentPageToCache(webView: webView)
                        }
                    }
                }
            }

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

            urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
                guard let self = self, let newURL = change.newValue, let url = newURL else { return }

                DispatchQueue.main.async {
                    if self.parent.stateModel.currentURL != url && !self.isSwipeInProgress {
                        self.parent.stateModel.setNavigatingFromWebView(true)
                        self.parent.stateModel.currentURL = url
                        self.parent.stateModel.setNavigatingFromWebView(false)
                    }
                }
            }

            // 🔧 **제목 덮어쓰기 문제 해결**: titleObserver URL 검증 추가
            titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, change in
                guard let self = self, 
                      let title = change.newValue, 
                      let title = title, 
                      !title.isEmpty,
                      let currentURL = webView.url else { return }

                DispatchQueue.main.async {
                    // 🔧 **핵심 수정**: URL 기반으로 제목 업데이트
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

        // MARK: - 새 창 요청 처리
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }

        // MARK: 다운로드 이벤트 핸들러 (헬퍼 호출)
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