//
//  CustomWebView.swift
//
//  📸 스냅샷 기반 애니메이션 + 커스텀 히스토리 시스템 완전 동기화
//  🎯 제스처 완료 시 커스텀 시스템과 웹뷰를 모두 정상 동기화
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import Foundation
import Security

// MARK: - 고급 페이지 캐시 시스템
class AdvancedPageCache: ObservableObject {
    struct CachedPage {
        let snapshot: UIImage
        let url: URL
        let title: String
        let timestamp: Date
    }
    
    private var pageCache: [String: CachedPage] = [:]
    private let maxCacheSize = 20
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

// MARK: - 다운로드 진행 알림 이름 정의
extension Notification.Name {
    static let WebViewDownloadStart    = Notification.Name("WebViewDownloadStart")
    static let WebViewDownloadProgress = Notification.Name("WebViewDownloadProgress")
    static let WebViewDownloadFinish   = Notification.Name("WebViewDownloadFinish")
    static let WebViewDownloadFailed   = Notification.Name("WebViewDownloadFailed")
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
        // ✅ 오디오 세션 활성화
        configureAudioSessionForMixing()

        // WKWebView 설정
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.processPool = WKProcessPool()

        // 사용자 스크립트/메시지 핸들러
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())
        controller.addUserScript(makeDesktopModeScript())
        controller.addUserScript(makeUnifiedSPANavigationScript())
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

        // ✅ 하단 UI 겹치기를 위한 투명 처리
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never 
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero

        // ✨ Delegate 연결
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        stateModel.webView = webView
        
        // ✨ 초기 사용자 에이전트 설정
        context.coordinator.updateUserAgentIfNeeded()

        // 📸 스냅샷 기반 제스처 설정 (커스텀 시스템과 완전 동기화)
        context.coordinator.setupSyncedSwipeGesture(for: webView)

        // Pull to Refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refreshControl
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

        // 다운로드 진행률 UI 오버레이 구성
        context.coordinator.installDownloadOverlay(on: webView)

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

        // ✅ 하단 UI 겹치기를 위한 투명 설정 유지
        if uiView.isOpaque { uiView.isOpaque = false }
        if uiView.backgroundColor != .clear { uiView.backgroundColor = .clear }
        if uiView.scrollView.backgroundColor != .clear { uiView.scrollView.backgroundColor = .clear }
        uiView.scrollView.isOpaque = false
        
        // ✨ 데스크탑 모드 변경 시 페이지 새로고침으로 스크립트 적용
        context.coordinator.updateDesktopModeIfNeeded()
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

        // 오디오 세션 비활성화
        coordinator.parent.deactivateAudioSession()

        // 메시지 핸들러 제거
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "playVideo")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "setZoom")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "spaNavigation")

        // 모든 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - 🌐 통합된 SPA 네비게이션 스크립트
    private func makeUnifiedSPANavigationScript() -> WKUserScript {
        let scriptSource = """
        // 🌐 통합된 SPA 네비게이션 감지
        (function() {
            'use strict';
            
            console.log('🌐 통합된 SPA 네비게이션 훅 초기화');
            
            const originalPushState = history.pushState;
            const originalReplaceState = history.replaceState;
            
            let currentSPAState = {
                url: window.location.href,
                title: document.title,
                timestamp: Date.now(),
                state: history.state
            };
            
            const EXCLUDE_PATTERNS = [
                /\\/login/i, /\\/signin/i, /\\/auth/i, /\\/oauth/i, /\\/sso/i,
                /\\/redirect/i, /\\/callback/i, /\\/nid\\.naver\\.com/i,
                /\\/accounts\\.google\\.com/i, /\\/facebook\\.com\\/login/i,
                /\\/twitter\\.com\\/oauth/i, /returnUrl=/i, /redirect_uri=/i, /continue=/i
            ];
            
            function shouldExcludeFromHistory(url) {
                return EXCLUDE_PATTERNS.some(pattern => pattern.test(url));
            }
            
            function detectSiteType(url) {
                const urlObj = new URL(url, window.location.origin);
                const host = urlObj.hostname.toLowerCase();
                const path = urlObj.pathname.toLowerCase();
                
                let pattern = 'unknown';
                if (path.match(/\\/[^/]+\\/\\d+\\/\\d+/)) {
                    pattern = '3level_numeric';
                } else if (path.match(/\\/[^/]+\\/\\d+$/)) {
                    pattern = '2level_numeric';
                } else if (path.match(/\\/[^/]+\\/[^/]+\\/\\d+/)) {
                    pattern = '3level_mixed';
                } else if (path.match(/\\/[^/]+\\/[^/]+$/)) {
                    pattern = '2level_text';
                } else if (path.match(/\\/[^/]+$/)) {
                    pattern = '1level';
                }
                
                return `${host}_${pattern}`;
            }
            
            function notifyNavigation(type, url, title, state) {
                if (shouldExcludeFromHistory(url)) {
                    console.log(`🔒 히스토리 제외: ${url} (${type})`);
                    return;
                }
                
                const siteType = detectSiteType(url);
                
                const message = {
                    type: type,
                    url: url,
                    title: title || document.title,
                    state: state,
                    timestamp: Date.now(),
                    userAgent: navigator.userAgent,
                    referrer: document.referrer,
                    siteType: siteType,
                    shouldExclude: false
                };
                
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.spaNavigation) {
                    window.webkit.messageHandlers.spaNavigation.postMessage(message);
                    console.log(`🌐 SPA ${type}: ${siteType} | ${url}`);
                }
            }
            
            history.pushState = function(state, title, url) {
                console.log('🌐 pushState 감지:', url);
                const result = originalPushState.call(this, state, title, url);
                
                const newURL = new URL(url || window.location.href, window.location.origin).href;
                if (newURL !== currentSPAState.url) {
                    currentSPAState = {
                        url: newURL,
                        title: title || document.title,
                        timestamp: Date.now(),
                        state: state
                    };
                    
                    setTimeout(() => {
                        notifyNavigation('push', newURL, document.title, state);
                    }, 150);
                }
                
                return result;
            };
            
            history.replaceState = function(state, title, url) {
                console.log('🌐 replaceState 감지:', url);
                const result = originalReplaceState.call(this, state, title, url);
                
                const newURL = new URL(url || window.location.href, window.location.origin).href;
                if (newURL !== currentSPAState.url) {
                    currentSPAState = {
                        url: newURL,
                        title: title || document.title,
                        timestamp: Date.now(),
                        state: state
                    };
                    
                    setTimeout(() => {
                        notifyNavigation('replace', newURL, document.title, state);
                    }, 150);
                }
                
                return result;
            };
            
            window.addEventListener('popstate', function(event) {
                console.log('🌐 popstate 감지:', window.location.href);
                
                const newURL = window.location.href;
                if (newURL !== currentSPAState.url) {
                    currentSPAState = {
                        url: newURL,
                        title: document.title,
                        timestamp: Date.now(),
                        state: event.state
                    };
                    
                    setTimeout(() => {
                        notifyNavigation('pop', newURL, document.title, event.state);
                    }, 100);
                }
            });
            
            window.addEventListener('hashchange', function(event) {
                console.log('🌐 hashchange 감지:', window.location.href);
                
                const newURL = window.location.href;
                if (newURL !== currentSPAState.url) {
                    currentSPAState = {
                        url: newURL,
                        title: document.title,
                        timestamp: Date.now(),
                        state: history.state
                    };
                    
                    setTimeout(() => {
                        notifyNavigation('hash', newURL, document.title, history.state);
                    }, 100);
                }
            });
            
            console.log('✅ 통합된 SPA 네비게이션 훅 설정 완료');
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - ✨ 데스크탑 모드 강제 JS 스크립트
    private func makeDesktopModeScript() -> WKUserScript {
        let scriptSource = """
        (function() {
            'use strict';
            
            window.desktopModeEnabled = false;
            window.desktopModeApplied = false;
            
            window.toggleDesktopMode = function(enabled) {
                window.desktopModeEnabled = enabled;
                
                if (enabled && !window.desktopModeApplied) {
                    applyDesktopMode();
                } else if (!enabled && window.desktopModeApplied) {
                    removeDesktopMode();
                }
            };
            
            function applyDesktopMode() {
                if (window.desktopModeApplied) return;
                window.desktopModeApplied = true;
                
                Object.defineProperty(screen, 'width', { 
                    get: function() { return 1920; },
                    configurable: false
                });
                Object.defineProperty(screen, 'height', { 
                    get: function() { return 1080; },
                    configurable: false
                });
                
                Object.defineProperty(window, 'innerWidth', { 
                    get: function() { return 1920; },
                    configurable: false
                });
                Object.defineProperty(window, 'innerHeight', { 
                    get: function() { return 1080; },
                    configurable: false
                });
                
                Object.defineProperty(window, 'ontouchstart', { 
                    get: function() { return undefined; },
                    configurable: false
                });
                
                setupZoomFunction();
                console.log('✅ 데스크탑 모드 적용 완료');
            }
            
            function setupZoomFunction() {
                window.setPageZoom = function(scale) {
                    scale = Math.max(0.3, Math.min(3.0, scale));
                    
                    requestAnimationFrame(() => {
                        document.body.style.transform = `scale(${scale})`;
                        document.body.style.transformOrigin = '0 0';
                        document.body.style.width = `${100/scale}%`;
                        document.body.style.height = `${100/scale}%`;
                        
                        window.currentZoomLevel = scale;
                        
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.setZoom) {
                            window.webkit.messageHandlers.setZoom.postMessage({
                                zoom: scale,
                                action: 'update'
                            });
                        }
                    });
                };
            }
            
            console.log('✅ 데스크탑 모드 스크립트 로드됨');
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - 사용자 스크립트 (비디오 클릭 → AVPlayer)
    private func makeVideoScript() -> WKUserScript {
        let scriptSource = """
        function processVideos(doc) {
            [...doc.querySelectorAll('video')].forEach(video => {
                video.muted = true;
                video.volume = 0;
                video.setAttribute('muted','true');

                if (!video.hasAttribute('nativeAVPlayerListener')) {
                    video.addEventListener('click', () => {
                        window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
                    });
                    video.setAttribute('nativeAVPlayerListener', 'true');
                }

                if (document.pictureInPictureEnabled &&
                    !video.disablePictureInPicture &&
                    !document.pictureInPictureElement) {
                    try { video.requestPictureInPicture().catch(() => {}); } catch (e) {}
                }
            });
        }

        processVideos(document);
        setInterval(() => {
            processVideos(document);
            [...document.querySelectorAll('iframe')].forEach(iframe => {
                try {
                    const doc = iframe.contentDocument || iframe.contentWindow?.document;
                    if (doc) processVideos(doc);
                } catch (e) {}
            });
        }, 1000);
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    // MARK: - 오디오 세션
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {

        var parent: CustomWebView
        weak var webView: WKWebView?
        var filePicker: FilePicker?

        // ✨ 데스크탑 모드 변경 감지용 플래그
        private var lastDesktopMode: Bool = false

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
        
        enum SwipeDirection {
            case back    // 뒤로가기 (왼쪽 에지에서)
            case forward // 앞으로가기 (오른쪽 에지에서)
        }

        // 다운로드 진행률 UI 구성 요소들
        private var overlayContainer: UIVisualEffectView?
        private var overlayTitleLabel: UILabel?
        private var overlayPercentLabel: UILabel?
        private var overlayProgress: UIProgressView?

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
        
        // ✨ 사용자 에이전트 업데이트 메서드
        func updateUserAgentIfNeeded() {
            guard let webView = webView else { return }
            
            if parent.stateModel.isDesktopMode {
                let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
                webView.customUserAgent = desktopUA
            } else {
                webView.customUserAgent = nil
            }
        }
        
        // ✨ 데스크탑 모드 변경 감지 및 적용
        func updateDesktopModeIfNeeded() {
            guard let webView = webView else { return }
            
            updateUserAgentIfNeeded()
            
            if parent.stateModel.isDesktopMode != lastDesktopMode {
                lastDesktopMode = parent.stateModel.isDesktopMode
                
                let script = "if (window.toggleDesktopMode) { window.toggleDesktopMode(\(parent.stateModel.isDesktopMode)); }"
                webView.evaluateJavaScript(script) { result, error in
                    if let error = error {
                        print("데스크탑 모드 토글 실패: \(error)")
                    }
                }
            }
        }

        // MARK: - ✨ 로딩 상태 동기화를 위한 KVO 설정
        func setupLoadingObservers(for webView: WKWebView) {
            loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
                guard let self = self else { return }
                let isLoading = change.newValue ?? false

                DispatchQueue.main.async {
                    if self.parent.stateModel.isLoading != isLoading {
                        self.parent.stateModel.isLoading = isLoading
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
                    let newProgress = max(0.0, min(1.0, progress))
                    self.parent.stateModel.loadingProgress = newProgress
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

            titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, change in
                guard let self = self, let title = change.newValue, let title = title, !title.isEmpty else { return }

                DispatchQueue.main.async {
                    self.parent.stateModel.updateCurrentPageTitle(title)
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
            
            // 스냅샷만 캐처 (HTML은 제거)
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

        // MARK: Pull to Refresh
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                sender.endRefreshing()
            }
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

        // ✅ SSL 인증서 경고 처리
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

            let host = challenge.protectionSpace.host

            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {

                guard let serverTrust = challenge.protectionSpace.serverTrust else {
                    completionHandler(.performDefaultHandling, nil)
                    return
                }

                var error: CFError?
                let isValid = SecTrustEvaluateWithError(serverTrust, &error)

                if isValid {
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                    return
                }

                DispatchQueue.main.async {
                    guard let topVC = self.topMostViewController() else {
                        completionHandler(.performDefaultHandling, nil)
                        return
                    }

                    let alert = UIAlertController(
                        title: "보안 연결 경고", 
                        message: "\(host)의 보안 인증서에 문제가 있습니다.\n\n• 인증서가 만료되었거나\n• 자체 서명된 인증서이거나\n• 신뢰할 수 없는 기관에서 발급되었습니다.\n\n그래도 계속 방문하시겠습니까?",
                        preferredStyle: .alert
                    )

                    alert.addAction(UIAlertAction(title: "무시하고 방문", style: .destructive) { _ in
                        let credential = URLCredential(trust: serverTrust)
                        completionHandler(.useCredential, credential)
                    })

                    alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                        completionHandler(.cancelAuthenticationChallenge, nil)

                        if let tabID = self.parent.stateModel.tabID {
                            NotificationCenter.default.post(
                                name: Notification.Name("webViewDidFailLoad"),
                                object: nil,
                                userInfo: [
                                    "tabID": tabID.uuidString,
                                    "sslError": true,
                                    "url": "https://\(host)"
                                ]
                            )
                        }
                    })

                    topVC.present(alert, animated: true)
                }
                return
            }

            completionHandler(.performDefaultHandling, nil)
        }

        private func topMostViewController() -> UIViewController? {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first,
                  let root = window.rootViewController else { return nil }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            return top
        }

        // MARK: - 새 창 요청 처리
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            webView.load(navigationAction.request)
            return nil
        }

        // MARK: - 다운로드 진행률 오버레이
        func installDownloadOverlay(on webView: WKWebView) {
            guard overlayContainer == nil else { return }

            let blur = UIBlurEffect(style: .systemThinMaterial)
            let container = UIVisualEffectView(effect: blur)
            container.translatesAutoresizingMaskIntoConstraints = false
            container.alpha = 0.0
            container.layer.cornerRadius = 10
            container.clipsToBounds = true

            let title = UILabel()
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = .preferredFont(forTextStyle: .caption1)
            title.textColor = .label
            title.text = "다운로드 준비 중..."

            let percent = UILabel()
            percent.translatesAutoresizingMaskIntoConstraints = false
            percent.font = .preferredFont(forTextStyle: .caption1)
            percent.textColor = .secondaryLabel
            percent.text = "0%"

            let progress = UIProgressView(progressViewStyle: .bar)
            progress.translatesAutoresizingMaskIntoConstraints = false
            progress.progress = 0.0

            container.contentView.addSubview(title)
            container.contentView.addSubview(percent)
            container.contentView.addSubview(progress)

            webView.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                container.trailingAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                container.topAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.topAnchor, constant: 12),

                title.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 12),
                title.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: 10),

                percent.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -12),
                percent.centerYAnchor.constraint(equalTo: title.centerYAnchor),

                progress.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 12),
                progress.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -12),
                progress.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
                progress.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -10),
                progress.heightAnchor.constraint(equalToConstant: 3)
            ])

            overlayContainer = container
            overlayTitleLabel = title
            overlayPercentLabel = percent
            overlayProgress = progress
        }

        private func showOverlay(filename: String?) {
            overlayTitleLabel?.text = filename ?? "다운로드 중"
            overlayPercentLabel?.text = "0%"
            overlayProgress?.setProgress(0.0, animated: false)
            UIView.animate(withDuration: 0.2) { self.overlayContainer?.alpha = 1.0 }
        }

        private func updateOverlay(progress: Double) {
            overlayProgress?.setProgress(Float(progress), animated: true)
            let pct = max(0, min(100, Int(progress * 100)))
            overlayPercentLabel?.text = "\(pct)%"
        }

        private func hideOverlay() {
            UIView.animate(withDuration: 0.2) { self.overlayContainer?.alpha = 0.0 }
        }

        // MARK: 다운로드 이벤트 핸들러
        @objc func handleDownloadStart(_ note: Notification) {
            let filename = note.userInfo?["filename"] as? String
            showOverlay(filename: filename)
        }

        @objc func handleDownloadProgress(_ note: Notification) {
            let progress = note.userInfo?["progress"] as? Double ?? 0
            updateOverlay(progress: progress)
        }

        @objc func handleDownloadFinish(_ note: Notification) {
            hideOverlay()
        }

        @objc func handleDownloadFailed(_ note: Notification) {
            hideOverlay()
        }
    }
}

// MARK: - 파일 선택 헬퍼
@available(iOS 14.0, *)
class FilePicker: NSObject, UIDocumentPickerDelegate {
    let completionHandler: ([URL]?) -> Void

    init(completionHandler: @escaping ([URL]?) -> Void) {
        self.completionHandler = completionHandler
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completionHandler(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completionHandler(nil)
    }
}

// MARK: - CookieSyncManager (쿠키 세션 공유)
enum CookieSyncManager {
    static func syncAppToWebView(_ webView: WKWebView, completion: (() -> Void)? = nil) {
        let appCookies = HTTPCookieStorage.shared.cookies ?? []
        guard !appCookies.isEmpty else { completion?(); return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        appCookies.forEach { cookie in
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { completion?() }
    }

    static func syncWebToApp(_ store: WKHTTPCookieStore, completion: (() -> Void)? = nil) {
        store.getAllCookies { cookies in
            let appStorage = HTTPCookieStorage.shared
            cookies.forEach { appStorage.setCookie($0) }
            completion?()
        }
    }
}