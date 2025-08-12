//
//  CustomWebView.swift
//
//  ✅ 스마트 주소창 & 한글 에러 메시지와 완벽 연동
//  ✨ 데스크탑 모드 강화: JS 주입으로 강제 데스크탑 환경 구현
//  🔄 WKNavigationDelegate는 WebViewDataModel로 이동됨
//  ✨ 제스처와 하단 버튼 완벽 동기화 - 커스텀 제스처로 해결!
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import Foundation
import Security

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
        // ✨ 데스크탑 모드 스크립트 항상 주입 (내부에서 조건 확인)
        controller.addUserScript(makeDesktopModeScript())
        controller.add(context.coordinator, name: "playVideo")
        // ✨ 확대/축소 메시지 핸들러 추가
        controller.add(context.coordinator, name: "setZoom")
        config.userContentController = controller

        // ✨ 다운로드 지원 (iOS 14+)
        if #available(iOS 14.0, *) {
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        }

        // WKWebView 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        
        // 🎯 네이티브 제스처 완전 비활성화 - 동기화 문제 해결의 핵심!
        webView.allowsBackForwardNavigationGestures = false
        
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.decelerationRate = .normal

        // ✅ 하단 UI 겹치기를 위한 투명 처리
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero

        // ✨ Delegate 연결 (NavigationDelegate는 DataModel이 담당)
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        stateModel.webView = webView  // 이때 자동으로 dataModel.navigationDelegate 설정됨
        
        // ✨ 초기 사용자 에이전트 설정
        context.coordinator.updateUserAgentIfNeeded()

        // 🎯 커스텀 제스처 추가 - 완벽한 동기화!
        context.coordinator.setupCustomGestures(for: webView)

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
        
        // 🎯 네비게이션 상태 KVO 제거됨 - 이제 완전히 우리 시스템만으로 관리!

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
        // 연결 상태 확인 및 재연결 (NavigationDelegate는 DataModel이 담당하므로 제거)
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
        // 🎯 네비게이션 옵저버 제거됨 - 이제 웹뷰 상태 무시

        // 스크롤/델리게이트 해제 (NavigationDelegate는 DataModel이 관리하므로 제거)
        uiView.scrollView.delegate = nil
        uiView.uiDelegate = nil
        coordinator.webView = nil

        // 🎯 커스텀 제스처 제거
        coordinator.removeCustomGestures(from: uiView)

        // 오디오 세션 비활성화
        coordinator.parent.deactivateAudioSession()

        // 메시지 핸들러 제거
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "playVideo")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "setZoom")

        // 모든 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - ✨ 데스크탑 모드 강제 JS 스크립트 (조건부 실행)
    private func makeDesktopModeScript() -> WKUserScript {
        let scriptSource = """
        // ✨ 데스크탑 모드 관리 스크립트
        (function() {
            'use strict';
            
            // 전역 변수로 상태 관리
            window.desktopModeEnabled = false;
            window.desktopModeApplied = false;
            
            // 데스크탑 모드 토글 함수
            window.toggleDesktopMode = function(enabled) {
                window.desktopModeEnabled = enabled;
                
                if (enabled && !window.desktopModeApplied) {
                    applyDesktopMode();
                } else if (!enabled && window.desktopModeApplied) {
                    removeDesktopMode();
                }
            };
            
            // 데스크탑 모드 적용
            function applyDesktopMode() {
                if (window.desktopModeApplied) return;
                window.desktopModeApplied = true;
                
                // 1. 화면 크기를 데스크탑으로 속이기
                Object.defineProperty(screen, 'width', { 
                    get: function() { return 1920; },
                    configurable: false
                });
                Object.defineProperty(screen, 'height', { 
                    get: function() { return 1080; },
                    configurable: false
                });
                Object.defineProperty(screen, 'availWidth', { 
                    get: function() { return 1920; },
                    configurable: false
                });
                Object.defineProperty(screen, 'availHeight', { 
                    get: function() { return 1040; },
                    configurable: false
                });
                
                // 2. 윈도우 크기를 데스크탑으로 속이기
                Object.defineProperty(window, 'innerWidth', { 
                    get: function() { return 1920; },
                    configurable: false
                });
                Object.defineProperty(window, 'innerHeight', { 
                    get: function() { return 1080; },
                    configurable: false
                });
                Object.defineProperty(window, 'outerWidth', { 
                    get: function() { return 1920; },
                    configurable: false
                });
                Object.defineProperty(window, 'outerHeight', { 
                    get: function() { return 1080; },
                    configurable: false
                });
                
                // 3. 터치 이벤트 비활성화
                Object.defineProperty(window, 'ontouchstart', { 
                    get: function() { return undefined; },
                    configurable: false
                });
                Object.defineProperty(window, 'ontouchmove', { 
                    get: function() { return undefined; },
                    configurable: false
                });
                Object.defineProperty(window, 'ontouchend', { 
                    get: function() { return undefined; },
                    configurable: false
                });
                
                // 4. maxTouchPoints를 0으로 설정
                if (navigator.maxTouchPoints !== undefined) {
                    Object.defineProperty(navigator, 'maxTouchPoints', { 
                        get: function() { return 0; },
                        configurable: false
                    });
                }
                
                // 5. CSS 미디어 쿼리 속이기
                const originalMatchMedia = window.matchMedia;
                window.matchMedia = function(query) {
                    if (query.includes('hover: none') || 
                        query.includes('pointer: coarse') ||
                        query.includes('max-width: 768px') ||
                        query.includes('max-width: 1024px') ||
                        query.includes('orientation: portrait')) {
                        return { matches: false, media: query, addListener: function(){}, removeListener: function(){} };
                    }
                    
                    if (query.includes('hover: hover') || 
                        query.includes('pointer: fine') ||
                        query.includes('min-width: 1200px')) {
                        return { matches: true, media: query, addListener: function(){}, removeListener: function(){} };
                    }
                    
                    return originalMatchMedia.call(this, query);
                };
                
                // 6. DeviceMotionEvent와 DeviceOrientationEvent 비활성화
                window.DeviceMotionEvent = undefined;
                window.DeviceOrientationEvent = undefined;
                
                // 7. Viewport 메타태그 조작
                fixViewport();
                
                // 8. 줌 기능 구현
                setupZoomFunction();
                
                // 9. 초기 줌 설정
                setTimeout(() => {
                    if (window.setPageZoom) {
                        window.setPageZoom(0.5);
                    }
                }, 200);
                
                console.log('✅ 데스크탑 모드 적용 완료');
            }
            
            // 데스크탑 모드 해제 (페이지 새로고침 필요)
            function removeDesktopMode() {
                window.desktopModeApplied = false;
                // 모바일 모드로 돌아가려면 페이지 새로고침이 필요
                console.log('📱 모바일 모드로 전환 (새로고침 필요)');
            }
            
            // Viewport 메타태그 조작
            function fixViewport() {
                const viewports = document.querySelectorAll('meta[name="viewport"]');
                viewports.forEach(viewport => {
                    viewport.setAttribute('content', 'width=1920, initial-scale=0.5, maximum-scale=3.0, minimum-scale=0.3, user-scalable=yes');
                });
                
                if (viewports.length === 0) {
                    const meta = document.createElement('meta');
                    meta.name = 'viewport';
                    meta.content = 'width=1920, initial-scale=0.5, maximum-scale=3.0, minimum-scale=0.3, user-scalable=yes';
                    document.head?.appendChild(meta);
                }
            }
            
            // 줌 기능 구현
            function setupZoomFunction() {
                window.setPageZoom = function(scale) {
                    scale = Math.max(0.3, Math.min(3.0, scale));
                    
                    // 기존 스타일 정리
                    if (document.body.style.transform) {
                        document.body.style.transform = '';
                        document.body.style.transformOrigin = '';
                        document.body.style.width = '';
                        document.body.style.height = '';
                    }
                    
                    // 새 스타일 적용
                    requestAnimationFrame(() => {
                        document.body.style.transform = `scale(${scale})`;
                        document.body.style.transformOrigin = '0 0';
                        document.body.style.width = `${100/scale}%`;
                        document.body.style.height = `${100/scale}%`;
                        document.body.style.overflow = 'visible';
                        
                        window.currentZoomLevel = scale;
                        
                        // 네이티브로 줌 레벨 전달
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.setZoom) {
                            window.webkit.messageHandlers.setZoom.postMessage({
                                zoom: scale,
                                action: 'update'
                            });
                        }
                    });
                };
            }
            
            // 동적 viewport 감시
            if (window.MutationObserver) {
                const observer = new MutationObserver(function(mutations) {
                    mutations.forEach(function(mutation) {
                        if (mutation.type === 'childList') {
                            mutation.addedNodes.forEach(function(node) {
                                if (node.nodeType === 1 && node.tagName === 'META' && node.name === 'viewport') {
                                    if (window.desktopModeEnabled) {
                                        fixViewport();
                                    }
                                }
                            });
                        }
                    });
                });
                observer.observe(document.head || document.documentElement, { childList: true, subtree: true });
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
                // iOS 자동재생 제약 회피
                video.muted = true;
                video.volume = 0;
                video.setAttribute('muted','true');

                // AVPlayer로 넘기는 클릭 핸들러 1회만 부착
                if (!video.hasAttribute('nativeAVPlayerListener')) {
                    video.addEventListener('click', () => {
                        window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
                    });
                    video.setAttribute('nativeAVPlayerListener', 'true');
                }

                // PiP 자동 진입 시도
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

    // MARK: - Coordinator (WKNavigationDelegate 제거됨, UIGestureRecognizerDelegate 추가)
    class Coordinator: NSObject, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {

        var parent: CustomWebView
        weak var webView: WKWebView?
        var filePicker: FilePicker?

        // ✨ 데스크탑 모드 변경 감지용 플래그
        private var lastDesktopMode: Bool = false

        // 🎯 커스텀 제스처 레퍼런스
        private var backGesture: UIScreenEdgePanGestureRecognizer?
        private var forwardGesture: UIScreenEdgePanGestureRecognizer?

        // 다운로드 진행률 UI 구성 요소들
        private var overlayContainer: UIVisualEffectView?
        private var overlayTitleLabel: UILabel?
        private var overlayPercentLabel: UILabel?
        private var overlayProgress: UIProgressView?

        // ✨ KVO 옵저버들 (로딩 상태 동기화용만)
        private var loadingObserver: NSKeyValueObservation?
        private var urlObserver: NSKeyValueObservation?
        private var titleObserver: NSKeyValueObservation?
        private var progressObserver: NSKeyValueObservation?
        
        // 🎯 네비게이션 상태 KVO 제거됨 - 이제 웹뷰 상태 무시!

        init(_ parent: CustomWebView) { 
            self.parent = parent 
            self.lastDesktopMode = parent.stateModel.isDesktopMode  // 초기값 설정
        }

        deinit {
            removeLoadingObservers(for: webView)
            // 🎯 네비게이션 옵저버 제거됨 - 이제 웹뷰 상태 무시
        }
        
        // MARK: - 🎯 커스텀 제스처 설정 (핵심!)
        
        func setupCustomGestures(for webView: WKWebView) {
            // ✨ 커스텀 뒤로가기 제스처 (왼쪽 가장자리)
            let backGesture = UIScreenEdgePanGestureRecognizer(
                target: self, 
                action: #selector(handleBackGesture(_:))
            )
            backGesture.edges = .left
            backGesture.delegate = self  // 충돌 방지용
            webView.addGestureRecognizer(backGesture)
            self.backGesture = backGesture
            
            // ✨ 커스텀 앞으로가기 제스처 (오른쪽 가장자리)
            let forwardGesture = UIScreenEdgePanGestureRecognizer(
                target: self,
                action: #selector(handleForwardGesture(_:))
            )
            forwardGesture.edges = .right
            forwardGesture.delegate = self  // 충돌 방지용
            webView.addGestureRecognizer(forwardGesture)
            self.forwardGesture = forwardGesture
            
            TabPersistenceManager.debugMessages.append("🎯 커스텀 제스처 설정 완료 - 동기화 문제 해결!")
        }
        
        func removeCustomGestures(from webView: WKWebView) {
            if let backGesture = backGesture {
                webView.removeGestureRecognizer(backGesture)
                self.backGesture = nil
            }
            if let forwardGesture = forwardGesture {
                webView.removeGestureRecognizer(forwardGesture)
                self.forwardGesture = nil
            }
        }
        
        // MARK: - 🎯 커스텀 제스처 핸들러들 (동기화 문제 완전 해결!)
        
        @objc func handleBackGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            
            // 최소 이동 거리 체크 (실수 방지)
            let translation = gesture.translation(in: gesture.view)
            guard translation.x > 50 else { return }
            
            // 🎯 우리 시스템으로 직접 처리 - 동기화 문제 완전 해결!
            if parent.stateModel.canGoBack {
                parent.stateModel.goBack()
                TabPersistenceManager.debugMessages.append("👆 커스텀 뒤로가기 제스처 (동기화 완벽!)")
            }
        }
        
        @objc func handleForwardGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            
            // 최소 이동 거리 체크
            let translation = gesture.translation(in: gesture.view)
            guard translation.x < -50 else { return }  // 오른쪽에서 왼쪽으로
            
            if parent.stateModel.canGoForward {
                parent.stateModel.goForward()
                TabPersistenceManager.debugMessages.append("👆 커스텀 앞으로가기 제스처 (동기화 완벽!)")
            }
        }
        
        // MARK: - UIGestureRecognizerDelegate (제스처 충돌 방지)
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 스크롤과는 동시 인식 허용
            if otherGestureRecognizer is UIPanGestureRecognizer && gestureRecognizer is UIScreenEdgePanGestureRecognizer {
                return false  // 화면 가장자리 제스처는 우선권
            }
            return true
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 우리 커스텀 제스처가 우선권
            return gestureRecognizer is UIScreenEdgePanGestureRecognizer
        }
        
        // ✨ 사용자 에이전트 업데이트 메서드 (데스크탑 모드용)
        func updateUserAgentIfNeeded() {
            guard let webView = webView else { return }
            
            if parent.stateModel.isDesktopMode {
                // ✨ 강력한 데스크탑 사용자 에이전트 (Windows Chrome)
                let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
                webView.customUserAgent = desktopUA
            } else {
                webView.customUserAgent = nil
            }
        }
        
        // ✨ 데스크탑 모드 변경 감지 및 적용
        func updateDesktopModeIfNeeded() {
            guard let webView = webView else { return }
            
            // 사용자 에이전트 업데이트
            updateUserAgentIfNeeded()
            
            // ✨ 데스크탑 모드 변경 시 JavaScript로 즉시 토글
            if parent.stateModel.isDesktopMode != lastDesktopMode {
                lastDesktopMode = parent.stateModel.isDesktopMode
                
                // JavaScript 함수 호출로 즉시 적용
                let script = "if (window.toggleDesktopMode) { window.toggleDesktopMode(\(parent.stateModel.isDesktopMode)); }"
                webView.evaluateJavaScript(script) { result, error in
                    if let error = error {
                        print("데스크탑 모드 토글 실패: \(error)")
                        // 실패 시 페이지 새로고침으로 폴백
                        if let currentURL = self.parent.stateModel.currentURL {
                            webView.load(URLRequest(url: currentURL))
                        }
                    } else {
                        print("✅ 데스크탑 모드 토글 성공: \(self.parent.stateModel.isDesktopMode)")
                    }
                }
            }
        }

        // MARK: - ✨ 로딩 상태 동기화를 위한 KVO 설정
        func setupLoadingObservers(for webView: WKWebView) {
            // isLoading 상태 관찰
            loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
                guard let self = self else { return }
                let isLoading = change.newValue ?? false

                DispatchQueue.main.async {
                    if self.parent.stateModel.isLoading != isLoading {
                        self.parent.stateModel.isLoading = isLoading
                    }
                }
            }

            // ✅ 진행률 관찰 추가 (단순화 - 모든 변화 반영)
            progressObserver = webView.observe(\.estimatedProgress, options: [.new, .initial]) { [weak self] webView, change in
                guard let self = self else { return }
                let progress = change.newValue ?? 0.0

                DispatchQueue.main.async {
                    // ✅ 모든 진행률 변화를 반영
                    let newProgress = max(0.0, min(1.0, progress))
                    self.parent.stateModel.loadingProgress = newProgress
                }
            }

            // URL 변경 관찰
            urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
                guard let self = self, let newURL = change.newValue, let url = newURL else { return }

                DispatchQueue.main.async {
                    if self.parent.stateModel.currentURL != url {
                        self.parent.stateModel.setNavigatingFromWebView(true)
                        self.parent.stateModel.currentURL = url
                        self.parent.stateModel.setNavigatingFromWebView(false)
                    }
                }
            }

            // 제목 변경 관찰
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
        
        // 🎯 네비게이션 상태 KVO 메서드들 제거됨 - 이제 웹뷰 상태 완전 무시!

        // MARK: - JS → 네이티브 메시지 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo" {
                if let urlString = message.body as? String, let url = URL(string: urlString) {
                    DispatchQueue.main.async {
                        self.parent.playerURL = url
                        self.parent.showAVPlayer = true
                    }
                }
            } else if message.name == "setZoom" {
                // ✨ 줌 레벨 업데이트 메시지 처리
                if let data = message.body as? [String: Any],
                   let zoom = data["zoom"] as? Double {
                    DispatchQueue.main.async {
                        // 줌 레벨을 StateModel에 전달 (UI 슬라이더 업데이트용)
                        self.parent.stateModel.currentZoomLevel = zoom
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

        // MARK: 네비게이션 명령 (🎯 완전히 우리 시스템으로 통합!)
        @objc func reloadWebView() { 
            webView?.reload()
        }
        @objc func goBack() { 
            // 🎯 이제 이것도 우리 시스템을 통해 처리!
            parent.stateModel.goBack()
        }
        @objc func goForward() { 
            // 🎯 이제 이것도 우리 시스템을 통해 처리!
            parent.stateModel.goForward()
        }

        // MARK: 스크롤 전달
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll?(scrollView.contentOffset.y)
        }

        // ✅ SSL 인증서 경고 처리 (수정됨 - 정상 사이트는 자동 통과)
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

            let host = challenge.protectionSpace.host

            // 서버 신뢰성 검증 (SSL/TLS)
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {

                // ✅ 먼저 시스템 기본 검증 시도
                guard let serverTrust = challenge.protectionSpace.serverTrust else {
                    completionHandler(.performDefaultHandling, nil)
                    return
                }

                // ✅ 최신 API 사용 (iOS 13+)
                var error: CFError?
                let isValid = SecTrustEvaluateWithError(serverTrust, &error)

                if isValid {
                    // ✅ 시스템이 신뢰하는 인증서 - 자동 허용
                    let credential = URLCredential(trust: serverTrust)
                    completionHandler(.useCredential, credential)
                    return
                }

                // ❌ 시스템 검증 실패 - 사용자에게 묻기
                TabPersistenceManager.debugMessages.append("⚠️ SSL 인증서 문제: \(host)")

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

                    // 무시하고 방문
                    alert.addAction(UIAlertAction(title: "무시하고 방문", style: .destructive) { _ in
                        let credential = URLCredential(trust: serverTrust)
                        completionHandler(.useCredential, credential)
                        TabPersistenceManager.debugMessages.append("🔓 SSL 경고 무시: \(host)")
                    })

                    // 취소 (안전한 선택)
                    alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                        completionHandler(.cancelAuthenticationChallenge, nil)

                        // SSL 에러 알림 전송
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

            // 다른 인증 방법은 기본 처리
            completionHandler(.performDefaultHandling, nil)
        }

        // ✨ 최상위 뷰컨트롤러 찾기 (SSL 알림용)
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
            
            // ✅ 모든 새 창 요청은 현재 탭에서 열기
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

// ✨ SilentAudioPlayer와 AVPlayerView는 avp.swift에 정의되어 있으므로 여기서는 제거됨
