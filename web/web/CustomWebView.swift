//
//  CustomWebView.swift
//
//  🌐 통합된 SPA 네비게이션 + 로그인 리다이렉트 필터링
//  🎯 네이버 특화 로직을 범용으로 사용 (중복 제거)
//  🔒 로그인 관련 임시 페이지 히스토리 제외
//  🏄‍♂️ 피크(Peek) 방식 사파리 제스처 + 스냅샷 캐시 (안정적인 미리보기)
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import Foundation
import Security

// MARK: - 히스토리 페이지 스냅샷 관리
class HistorySnapshotCache: ObservableObject {
    private var snapshots: [String: UIImage] = [:]
    private let maxSnapshots = 20
    
    func saveSnapshot(for url: String, image: UIImage) {
        snapshots[url] = image
        
        // 최대 개수 초과 시 오래된 것 제거
        if snapshots.count > maxSnapshots {
            let oldestKey = snapshots.keys.first
            if let key = oldestKey {
                snapshots.removeValue(forKey: key)
            }
        }
        
        print("🖼️ 스냅샷 저장: \(url)")
    }
    
    func getSnapshot(for url: String) -> UIImage? {
        return snapshots[url]
    }
    
    func clearSnapshots() {
        snapshots.removeAll()
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

        // 🏄‍♂️ 사파리 스타일 제스처 설정
        context.coordinator.setupSafariStyleGestures(for: webView)

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

        // 🏄‍♂️ 사파리 스타일 제스처 제거
        coordinator.removeSafariStyleGestures(from: uiView)

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
            
            func­tion setupZoomFunction() {
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

        // 🏄‍♂️ 사파리 스타일 제스처 + 스냅샷 캐싱 (피크 방식)
        private var leftEdgeGesture: UIScreenEdgePanGestureRecognizer?
        private var rightEdgeGesture: UIScreenEdgePanGestureRecognizer?
        private var snapshotCache = HistorySnapshotCache()
        
        // 제스처 진행 중 오버레이
        private var gestureOverlayContainer: UIView?
        private var currentPageSnapshot: UIView?
        private var nextPageSnapshot: UIView?
        
        // 제스처 상태 (피크 방식)
        private var isGestureInProgress = false
        private var peekedRecord: PageRecord? // 미리 조회한 다음 페이지 레코드
        private var gestureType: GestureType?
        
        enum GestureType {
            case back, forward
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

        // MARK: - 🏄‍♂️ 사파리 스타일 제스처 설정
        func setupSafariStyleGestures(for webView: WKWebView) {
            // 제스처 오버레이 컨테이너 생성
            let overlayContainer = UIView()
            overlayContainer.backgroundColor = .clear
            overlayContainer.isUserInteractionEnabled = false
            overlayContainer.translatesAutoresizingMaskIntoConstraints = false
            webView.addSubview(overlayContainer)
            
            NSLayoutConstraint.activate([
                overlayContainer.topAnchor.constraint(equalTo: webView.topAnchor),
                overlayContainer.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
                overlayContainer.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
                overlayContainer.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
            ])
            
            self.gestureOverlayContainer = overlayContainer
            
            // 좌측 에지 제스처 (뒤로가기)
            let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            leftEdge.edges = .left
            leftEdge.delegate = self
            leftEdge.cancelsTouchesInView = false
            webView.addGestureRecognizer(leftEdge)
            self.leftEdgeGesture = leftEdge
            
            // 우측 에지 제스처 (앞으로가기)
            let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            rightEdge.edges = .right
            rightEdge.delegate = self
            rightEdge.cancelsTouchesInView = false
            webView.addGestureRecognizer(rightEdge)
            self.rightEdgeGesture = rightEdge
            
            // 우선순위 설정
            let scrollPan = webView.scrollView.panGestureRecognizer
            scrollPan.require(toFail: leftEdge)
            scrollPan.require(toFail: rightEdge)
            
            print("🏄‍♂️ 피크 방식 사파리 제스처 설정 완료")
        }
        
        func removeSafariStyleGestures(from webView: WKWebView) {
            if let gesture = leftEdgeGesture {
                webView.removeGestureRecognizer(gesture)
                self.leftEdgeGesture = nil
            }
            if let gesture = rightEdgeGesture {
                webView.removeGestureRecognizer(gesture)
                self.rightEdgeGesture = nil
            }
            gestureOverlayContainer?.removeFromSuperview()
            gestureOverlayContainer = nil
        }
        
        // MARK: - 🏄‍♂️ 에지 제스처 핸들러 (피크 방식)
        @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard let webView = gesture.view as? WKWebView,
                  let overlayContainer = gestureOverlayContainer else { return }
            
            let translation = gesture.translation(in: webView)
            let velocity = gesture.velocity(in: webView)
            let isLeftEdge = (gesture.edges == .left)
            
            switch gesture.state {
            case .began:
                let canNavigate = isLeftEdge ? parent.stateModel.canGoBack : parent.stateModel.canGoForward
                
                if canNavigate && !isGestureInProgress {
                    isGestureInProgress = true
                    gestureType = isLeftEdge ? .back : .forward
                    print("🏄‍♂️ 피크 제스처 시작: \(isLeftEdge ? "뒤로" : "앞으로")")
                    prepareGestureTransition(isBack: isLeftEdge, webView: webView, overlayContainer: overlayContainer)
                } else {
                    print("🏄‍♂️ 제스처 불가: \(isLeftEdge ? "뒤로" : "앞으로"), 진행중: \(isGestureInProgress)")
                    gesture.isEnabled = false
                    gesture.isEnabled = true
                }
                
            case .changed:
                guard isGestureInProgress else { return }
                
                let validMovement = isLeftEdge ? translation.x > 0 : translation.x < 0
                guard validMovement,
                      currentPageSnapshot != nil,
                      nextPageSnapshot != nil else { return }
                
                let progress = min(abs(translation.x) / UIScreen.main.bounds.width, 1.0)
                updateGestureTransition(progress: progress, translation: translation, isBack: isLeftEdge)
                
                // 중간 지점 햅틱
                if progress > 0.3 && progress < 0.35 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                
            case .ended:
                guard isGestureInProgress else { return }
                
                let velocityThreshold: CGFloat = 500
                let progress = abs(translation.x) / UIScreen.main.bounds.width
                
                let shouldComplete = progress > 0.3 || abs(velocity.x) > velocityThreshold
                
                if shouldComplete {
                    completeGestureTransition(isBack: isLeftEdge)
                } else {
                    cancelGestureTransition()
                }
                
            case .cancelled, .failed:
                if isGestureInProgress {
                    cancelGestureTransition()
                }
                
            default:
                break
            }
        }
        
        // MARK: - 헬퍼: 오버레이 배치와 z-order 고정
        // 🔧 스냅샷은 오토레이아웃 대신 frame으로 배치하고, zPosition으로 현재/다음 스택을 명시 고정
        private func layoutSnapshotsForTransition(_ overlay: UIView,
                                                  current: UIView,
                                                  next: UIView,
                                                  isBack: Bool) {
            overlay.layoutIfNeeded()
            let bounds = overlay.bounds
            let w = bounds.width
            let h = bounds.height
            
            current.frame = CGRect(x: 0, y: 0, width: w, height: h)
            next.frame    = CGRect(x: isBack ? -w : w, y: 0, width: w, height: h)
            
            // add 순서: next -> current (current가 위)
            overlay.addSubview(next)
            overlay.addSubview(current)
            
            // 명시적 z-order
            next.layer.zPosition = 0
            current.layer.zPosition = 1
        }
        
        // MARK: - 제스처 전환 준비 (피크 방식 - 히스토리 미변경)
        private func prepareGestureTransition(isBack: Bool, webView: WKWebView, overlayContainer: UIView) {
            // 🔧 전환 중 하단의 실제 웹뷰가 보이지 않도록 잠시 숨김(깜박임/티어링 방지)
            webView.isHidden = true
            
            // 1. 현재 페이지 스냅샷 먼저 생성
            webView.takeSnapshot(with: nil) { [weak self] currentImage, error in
                guard let self = self, let image = currentImage else {
                    self?.isGestureInProgress = false
                    webView.isHidden = false // 복구
                    return
                }
                
                DispatchQueue.main.async {
                    let currentSnapshot = UIImageView(image: image)
                    currentSnapshot.contentMode = .scaleAspectFill
                    currentSnapshot.clipsToBounds = true
                    
                    // 2. 🔍 피크(Peek): 다음 대상 레코드만 조회 (히스토리 변경 없음)
                    self.peekNextPageRecord(isBack: isBack, overlayContainer: overlayContainer)
                    
                    // nextPageSnapshot 준비가 끝날 때까지 대기 후 배치
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        guard let next = self.nextPageSnapshot else {
                            // next 준비 실패 시에도 현재 스냅샷은 최소 배치
                            overlayContainer.addSubview(currentSnapshot)
                            currentSnapshot.frame = overlayContainer.bounds
                            currentSnapshot.layer.zPosition = 1
                            self.currentPageSnapshot = currentSnapshot
                            return
                        }
                        self.layoutSnapshotsForTransition(overlayContainer,
                                                          current: currentSnapshot,
                                                          next: next,
                                                          isBack: isBack) // 🔧 frame 배치 + z-order 지정
                        self.currentPageSnapshot = currentSnapshot
                    }
                }
            }
        }
        
        // MARK: - 🔍 피크: 다음 대상 레코드 조회 (히스토리 미변경)
        private func peekNextPageRecord(isBack: Bool, overlayContainer: UIView) {
            let dataModel = parent.stateModel.dataModel
            var targetRecord: PageRecord?
            
            // 히스토리를 변경하지 않고 다음 대상만 조회
            if isBack && dataModel.canGoBack && dataModel.currentPageIndex > 0 {
                let backIndex = dataModel.currentPageIndex - 1
                if backIndex < dataModel.pageHistory.count {
                    targetRecord = dataModel.pageHistory[backIndex]
                }
            } else if !isBack && dataModel.canGoForward && dataModel.currentPageIndex < dataModel.pageHistory.count - 1 {
                let forwardIndex = dataModel.currentPageIndex + 1
                if forwardIndex < dataModel.pageHistory.count {
                    targetRecord = dataModel.pageHistory[forwardIndex]
                }
            }
            
            guard let record = targetRecord else {
                print("🏄‍♂️ 피크 실패: 대상 레코드 없음")
                createFallbackNextPageSnapshot(isBack: isBack, overlayContainer: overlayContainer, title: "페이지 없음", url: "")
                return
            }
            
            self.peekedRecord = record
            print("🏄‍♂️ 피크 성공: \(record.title) | \(record.url.absoluteString)")
            
            // 3. 캐시에서 스냅샷 찾기
            if let cachedSnapshot = snapshotCache.getSnapshot(for: record.url.absoluteString) {
                createNextPageSnapshotFromImage(isBack: isBack, overlayContainer: overlayContainer, image: cachedSnapshot)
                print("🖼️ 캐시된 스냅샷 사용: \(record.title)")
            } else {
                // 4. 스냅샷 없으면 타이틀 카드 생성
                createFallbackNextPageSnapshot(isBack: isBack, overlayContainer: overlayContainer, title: record.title, url: record.url.absoluteString)
                print("📄 타이틀 카드 생성: \(record.title)")
            }
        }
        
        // MARK: - 캐시된 이미지로 다음 페이지 스냅샷 생성
        private func createNextPageSnapshotFromImage(isBack: Bool, overlayContainer: UIView, image: UIImage) {
            let nextSnapshot = UIImageView(image: image)
            nextSnapshot.contentMode = .scaleAspectFill
            nextSnapshot.clipsToBounds = true
            // 🔧 frame 배치는 layoutSnapshotsForTransition 에서 수행
            self.nextPageSnapshot = nextSnapshot
        }
        
        // MARK: - 타이틀 카드로 다음 페이지 스냅샷 생성 (흰 화면 금지)
        private func createFallbackNextPageSnapshot(isBack: Bool, overlayContainer: UIView, title: String, url: String) {
            let cardView = UIView()
            cardView.backgroundColor = .systemBackground
            
            // 그라데이션 배경
            let gradientLayer = CAGradientLayer()
            gradientLayer.colors = [
                UIColor.systemBlue.withAlphaComponent(0.1).cgColor,
                UIColor.systemBackground.cgColor
            ]
            gradientLayer.startPoint = CGPoint(x: 0, y: 0)
            gradientLayer.endPoint = CGPoint(x: 1, y: 1)
            cardView.layer.addSublayer(gradientLayer)
            
            // 아이콘
            let iconView = UIImageView(image: UIImage(systemName: "safari"))
            iconView.contentMode = .scaleAspectFit
            iconView.tintColor = .systemBlue
            
            // 제목 라벨
            let titleLabel = UILabel()
            titleLabel.text = title.isEmpty ? "새 페이지" : title
            titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
            titleLabel.textColor = .label
            titleLabel.textAlignment = .center
            titleLabel.numberOfLines = 3
            
            // URL 라벨
            let urlLabel = UILabel()
            urlLabel.text = url.isEmpty ? "" : URL(string: url)?.host ?? url
            urlLabel.font = .systemFont(ofSize: 16, weight: .medium)
            urlLabel.textColor = .secondaryLabel
            urlLabel.textAlignment = .center
            urlLabel.numberOfLines = 2
            
            // 부제목
            let subtitleLabel = UILabel()
            subtitleLabel.text = isBack ? "이전 페이지" : "다음 페이지"
            subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
            subtitleLabel.textColor = .tertiaryLabel
            subtitleLabel.textAlignment = .center
            
            // 🔧 오토레이아웃 대신 autoresizingMask + frame 배치
            [iconView, titleLabel, urlLabel, subtitleLabel].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = true
                cardView.addSubview($0)
            }
            cardView.translatesAutoresizingMaskIntoConstraints = true
            
            // 배치: 레이아웃은 추후 frame 지정 시점에서 overlay.bounds 기준으로 계산
            // frame은 layoutSnapshotsForTransition에서 cardView 자체가 배치되고,
            // 내부 서브뷰는 아래에서 즉시 배치
            DispatchQueue.main.async {
                let b = self.gestureOverlayContainer?.bounds ?? .zero
                cardView.frame = CGRect(x: 0, y: 0, width: b.width, height: b.height)
                
                gradientLayer.frame = cardView.bounds
                let centerY = b.midY - 60
                iconView.frame = CGRect(x: b.midX - 40, y: centerY - 40, width: 80, height: 80)
                titleLabel.sizeToFit()
                titleLabel.center = CGPoint(x: b.midX, y: iconView.frame.maxY + 32)
               titleLabel.frame = CGRect(x: 40,y: iconView.frame.maxY + 20,width: b.width - 80,height: 28 * CGFloat(min(3, Int((titleLabel.intrinsicContentSize.width / (b.width - 80)).rounded(.up))))
)

urlLabel.frame = CGRect(
    x: 40,
    y: titleLabel.frame.maxY + 8,
    width: b.width - 80,
    height: 20
)
                subtitleLabel.sizeToFit()
                subtitleLabel.center = CGPoint(x: b.midX, y: urlLabel.frame.maxY + 18)
            }
            
            // 🔧 frame 배치는 layoutSnapshotsForTransition 에서 수행
            self.nextPageSnapshot = cardView
        }
        
        // MARK: - 제스처 전환 업데이트 (동일)
        private func updateGestureTransition(progress: CGFloat, translation: CGPoint, isBack: Bool) {
            guard let currentSnapshot = currentPageSnapshot,
                  let nextSnapshot = nextPageSnapshot,
                  let overlay = gestureOverlayContainer else { return }
            
            let w = overlay.bounds.width
            
            // 🔧 좌우 이동 + 현재 페이지 살짝 스케일 다운
            let currentTx = translation.x
            let nextBaseX: CGFloat = isBack ? -w : w
            let nextTx = nextBaseX + translation.x
            
            currentSnapshot.transform = CGAffineTransform(translationX: currentTx, y: 0)
                .scaledBy(x: 1 - 0.05*progress, y: 1 - 0.05*progress)
            nextSnapshot.transform = CGAffineTransform(translationX: nextTx, y: 0)
            
            // 그림자 효과
            currentSnapshot.layer.shadowOpacity = Float(progress * 0.3)
            currentSnapshot.layer.shadowOffset = CGSize(width: isBack ? 5 : -5, height: 0)
            currentSnapshot.layer.shadowRadius = 10
        }
        
        // MARK: - 제스처 완료 (이때만 실제 네비게이션 실행)
        private func completeGestureTransition(isBack: Bool) {
            guard let currentSnapshot = currentPageSnapshot,
                  let nextSnapshot = nextPageSnapshot,
                  let overlay = gestureOverlayContainer else { return }
            
            let w = overlay.bounds.width
            
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.55) {
                if isBack {
                    currentSnapshot.transform = CGAffineTransform(translationX: w, y: 0)
                    nextSnapshot.transform = .identity
                } else {
                    currentSnapshot.transform = CGAffineTransform(translationX: -w, y: 0)
                    nextSnapshot.transform = .identity
                }
                currentSnapshot.layer.shadowOpacity = 0
            } completion: { _ in
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                
                // 🎯 이때만 실제 히스토리 네비게이션 실행
                if isBack {
                    self.parent.stateModel.goBack()
                } else {
                    self.parent.stateModel.goForward()
                }
                
                // 정리
                self.cleanupGestureTransition()
                
                // 🔧 WebView 표시 복구
                self.webView?.isHidden = false
                
                print("🏄‍♂️ 제스처 완료: \(isBack ? "뒤로" : "앞으로") - 실제 네비게이션 실행")
            }
        }
        
        // MARK: - 제스처 취소 (히스토리 변경 없으므로 단순 정리만)
        private func cancelGestureTransition() {
            guard let currentSnapshot = currentPageSnapshot,
                  let nextSnapshot = nextPageSnapshot,
                  let overlay = gestureOverlayContainer else {
                isGestureInProgress = false
                webView?.isHidden = false // 🔧 복구
                return
            }
            
            let w = overlay.bounds.width
            
            UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.35) {
                currentSnapshot.transform = .identity
                if self.gestureType == .back {
                    nextSnapshot.transform = CGAffineTransform(translationX: -w, y: 0)
                } else {
                    nextSnapshot.transform = CGAffineTransform(translationX:  w, y: 0)
                }
                currentSnapshot.layer.shadowOpacity = 0
            } completion: { _ in
                self.cleanupGestureTransition()
                self.webView?.isHidden = false // 🔧 복구
                print("🏄‍♂️ 제스처 취소 - 히스토리 미변경 상태 유지")
            }
        }
        
        // MARK: - 제스처 정리
        private func cleanupGestureTransition() {
            currentPageSnapshot?.removeFromSuperview()
            nextPageSnapshot?.removeFromSuperview()
            currentPageSnapshot = nil
            nextPageSnapshot = nil
            isGestureInProgress = false
            gestureType = nil
            peekedRecord = nil
        }
        
        // MARK: - UIGestureRecognizerDelegate
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return false
        }
        
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === leftEdgeGesture || gestureRecognizer === rightEdgeGesture {
                return !isGestureInProgress
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
                    
                    // 로딩 완료 시 현재 페이지 스냅샷 저장 (제스처 중이 아닐 때만)
                    if !isLoading && !self.isGestureInProgress {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.saveCurrentPageSnapshot(webView: webView)
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
                    if self.parent.stateModel.currentURL != url && !self.isGestureInProgress {
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
        
        // MARK: - 현재 페이지 스냅샷 저장
        private func saveCurrentPageSnapshot(webView: WKWebView) {
            guard let currentURL = parent.stateModel.currentURL else { return }
            
            webView.takeSnapshot(with: nil) { [weak self] image, error in
                if let image = image {
                    self?.snapshotCache.saveSnapshot(for: currentURL.absoluteString, image: image)
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
