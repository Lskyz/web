//
//  CustomWebView.swift
//
//  ✅ 스마트 주소창 & 한글 에러 메시지와 완벽 연동
//  ✨ 데스크탑 모드 강화: JS 주입으로 강제 데스크탑 환경 구현
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
        webView.allowsBackForwardNavigationGestures = true
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

        // ✨ 강화된 Delegate 연결 (로딩 상태 동기화)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        stateModel.webView = webView
        
        // ✨ 초기 사용자 에이전트 설정 (필요시에만)
        if stateModel.isDesktopMode {
            context.coordinator.updateUserAgentIfNeeded()
        }

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
        if uiView.navigationDelegate !== context.coordinator {
            uiView.navigationDelegate = context.coordinator
        }
        if context.coordinator.webView !== uiView {
            context.coordinator.webView = uiView
        }

        // ✅ 하단 UI 겹치기를 위한 투명 설정 유지
        if uiView.isOpaque { uiView.isOpaque = false }
        if uiView.backgroundColor != .clear { uiView.backgroundColor = .clear }
        if uiView.scrollView.backgroundColor != .clear { uiView.scrollView.backgroundColor = .clear }
        uiView.scrollView.isOpaque = false
        
        // ✨ 데스크탑 모드 변경 감지
        context.coordinator.updateDesktopModeIfNeeded()
        
        // ✨ 줌 레벨 변경 감지 및 즉시 적용
        if stateModel.isDesktopMode {
            context.coordinator.applyZoomIfDesktopMode()
        }
    }

    // MARK: - teardown
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // KVO 옵저버 제거
        coordinator.removeLoadingObservers(for: uiView)

        // 스크롤/델리게이트 해제
        uiView.scrollView.delegate = nil
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil
        coordinator.webView = nil

        // 오디오 세션 비활성화
        coordinator.parent.deactivateAudioSession()

        // 메시지 핸들러 제거
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "playVideo")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "setZoom")

        // 모든 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - ✨ 데스크탑 모드 관리 JS 스크립트 (봇 감지 방지)
    private func makeDesktopModeScript() -> WKUserScript {
        let scriptSource = """
        // ✨ 데스크탑 모드 관리 스크립트 (자연스러운 전환)
        (function() {
            'use strict';
            
            // 전역 변수로 상태 관리
            window.desktopModeEnabled = false;
            window.desktopModeApplied = false;
            window.desktopModeSynced = false;
            
            // 데스크탑 모드 토글 함수 (부드러운 전환)
            window.toggleDesktopMode = function(enabled) {
                if (window.desktopModeEnabled === enabled) return; // 중복 실행 방지
                
                window.desktopModeEnabled = enabled;
                window.desktopModeSynced = false; // 새 상태로 리셋
                
                if (enabled && !window.desktopModeApplied) {
                    setTimeout(() => applyDesktopMode(), 50); // 약간의 지연으로 자연스럽게
                } else if (!enabled && window.desktopModeApplied) {
                    removeDesktopMode();
                }
            };
            
            // 데스크탑 모드 적용 (한 번만 실행)
            function applyDesktopMode() {
                if (window.desktopModeApplied) return;
                window.desktopModeApplied = true;
                
                // ✨ 네이티브에 상태 변경 알림
                if (window.webkit?.messageHandlers?.setZoom) {
                    window.webkit.messageHandlers.setZoom.postMessage({
                        action: 'desktopModeChanged',
                        enabled: true
                    });
                }
                
                // 1. 화면 크기 속이기 (읽기 전용 프로퍼티 재정의)
                try {
                    Object.defineProperty(screen, 'width', { get: () => 1920 });
                    Object.defineProperty(screen, 'height', { get: () => 1080 });
                    Object.defineProperty(screen, 'availWidth', { get: () => 1920 });
                    Object.defineProperty(screen, 'availHeight', { get: () => 1040 });
                    
                    Object.defineProperty(window, 'innerWidth', { get: () => 1920 });
                    Object.defineProperty(window, 'innerHeight', { get: () => 1080 });
                    Object.defineProperty(window, 'outerWidth', { get: () => 1920 });
                    Object.defineProperty(window, 'outerHeight', { get: () => 1080 });
                } catch (e) {
                    console.log('화면 크기 속이기 실패 (일부 사이트에서 정상)');
                }
                
                // 2. 터치 이벤트 비활성화
                try {
                    Object.defineProperty(window, 'ontouchstart', { get: () => undefined });
                    Object.defineProperty(window, 'ontouchmove', { get: () => undefined });
                    Object.defineProperty(window, 'ontouchend', { get: () => undefined });
                    
                    if (navigator.maxTouchPoints !== undefined) {
                        Object.defineProperty(navigator, 'maxTouchPoints', { get: () => 0 });
                    }
                } catch (e) {
                    console.log('터치 이벤트 비활성화 실패 (일부 사이트에서 정상)');
                }
                
                // 3. CSS 미디어 쿼리 속이기 (신중하게)
                const originalMatchMedia = window.matchMedia;
                window.matchMedia = function(query) {
                    if (query.includes('hover: none') || query.includes('pointer: coarse')) {
                        return { matches: false, media: query, addListener: () => {}, removeListener: () => {} };
                    }
                    if (query.includes('hover: hover') || query.includes('pointer: fine')) {
                        return { matches: true, media: query, addListener: () => {}, removeListener: () => {} };
                    }
                    return originalMatchMedia.call(this, query);
                };
                
                // 4. Device 이벤트 비활성화
                window.DeviceMotionEvent = undefined;
                window.DeviceOrientationEvent = undefined;
                
                // 5. Viewport 조작 (자연스럽게)
                setTimeout(() => {
                    fixViewport();
                    setupZoomFunction();
                    
                    // 초기 줌 설정 (부드럽게)
                    setTimeout(() => {
                        if (window.setPageZoom) {
                            window.setPageZoom(0.5);
                        }
                    }, 100);
                }, 100);
                
                console.log('✅ 데스크탑 모드 적용 완료');
            }
            
            // 모바일 모드로 복원
            function removeDesktopMode() {
                window.desktopModeApplied = false;
                
                // ✨ 네이티브에 상태 변경 알림
                if (window.webkit?.messageHandlers?.setZoom) {
                    window.webkit.messageHandlers.setZoom.postMessage({
                        action: 'desktopModeChanged',
                        enabled: false
                    });
                }
                
                // 줌 리셋
                if (document.body.style.transform) {
                    document.body.style.transform = '';
                    document.body.style.transformOrigin = '';
                    document.body.style.width = '';
                    document.body.style.height = '';
                }
                
                console.log('📱 모바일 모드로 복원');
            }
            
            // Viewport 조작 (부드럽게)
            function fixViewport() {
                const viewports = document.querySelectorAll('meta[name="viewport"]');
                viewports.forEach(viewport => {
                    const content = 'width=1920, initial-scale=0.5, maximum-scale=3.0, minimum-scale=0.3, user-scalable=yes';
                    if (viewport.getAttribute('content') !== content) {
                        viewport.setAttribute('content', content);
                    }
                });
                
                if (viewports.length === 0) {
                    const meta = document.createElement('meta');
                    meta.name = 'viewport';
                    meta.content = 'width=1920, initial-scale=0.5, maximum-scale=3.0, minimum-scale=0.3, user-scalable=yes';
                    document.head?.appendChild(meta);
                }
            }
            
            // 줌 기능 (안정적으로)
            function setupZoomFunction() {
                window.setPageZoom = function(scale) {
                    scale = Math.max(0.3, Math.min(3.0, scale));
                    
                    // 부드러운 전환을 위한 지연
                    requestAnimationFrame(() => {
                        if (document.body) {
                            // 기존 스타일 정리
                            document.body.style.transform = '';
                            document.body.style.transformOrigin = '';
                            document.body.style.width = '';
                            document.body.style.height = '';
                            
                            // 새 스타일 적용
                            requestAnimationFrame(() => {
                                document.body.style.transform = `scale(${scale})`;
                                document.body.style.transformOrigin = '0 0';
                                document.body.style.width = `${100/scale}%`;
                                document.body.style.height = `${100/scale}%`;
                                document.body.style.overflow = 'visible';
                                
                                window.currentZoomLevel = scale;
                                
                                // 네이티브로 줌 레벨 전달
                                if (window.webkit?.messageHandlers?.setZoom) {
                                    window.webkit.messageHandlers.setZoom.postMessage({
                                        zoom: scale,
                                        action: 'update'
                                    });
                                }
                            });
                        }
                    });
                };
            }
            
            console.log('✅ 데스크탑 모드 스크립트 준비됨');
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

    // MARK: - Coordinator
    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {

        var parent: CustomWebView
        weak var webView: WKWebView?
        var filePicker: FilePicker?

        // ✅ 스와이프 뒤로가기 감지용 플래그
        private var isSwipeBackNavigation: Bool = false
        
        // ✨ 데스크탑 모드 변경 감지용 플래그
        private var lastDesktopMode: Bool = false
        
        // ✨ 줌 레벨 추적용 (슬라이더 반응성 개선)
        private var lastZoomLevel: Double = 0.5

        // 다운로드 진행률 UI 구성 요소들
        private var overlayContainer: UIVisualEffectView?
        private var overlayTitleLabel: UILabel?
        private var overlayPercentLabel: UILabel?
        private var overlayProgress: UIProgressView?

        // ✨ KVO 옵저버들 (로딩 상태 동기화용)
        private var loadingObserver: NSKeyValueObservation?
        private var urlObserver: NSKeyValueObservation?
        private var titleObserver: NSKeyValueObservation?
        private var progressObserver: NSKeyValueObservation?

        init(_ parent: CustomWebView) { 
            self.parent = parent 
            self.lastDesktopMode = parent.stateModel.isDesktopMode  // 초기값 설정
            self.lastZoomLevel = parent.stateModel.currentZoomLevel  // 줌 레벨 초기값
        }

        deinit {
            removeLoadingObservers(for: webView)
        }
        
        // ✨ 사용자 에이전트 업데이트 메서드 (신중한 적용)
        func updateUserAgentIfNeeded() {
            guard let webView = webView else { return }
            
            let currentUA = webView.customUserAgent
            let targetUA: String?
            
            if parent.stateModel.isDesktopMode {
                // ✨ 자연스러운 데스크탑 사용자 에이전트 (Chrome 기준)
                targetUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            } else {
                // 기본 모바일 사용자 에이전트 (nil = 시스템 기본값)
                targetUA = nil
            }
            
            // 실제로 변경이 필요할 때만 적용 (불필요한 변경 방지)
            if currentUA != targetUA {
                webView.customUserAgent = targetUA
                print("🔄 사용자 에이전트 변경: \(parent.stateModel.isDesktopMode ? "데스크탑" : "모바일")")
            }
        }
        
        // ✨ 데스크탑 모드 변경 감지 및 적용 (새로고침 최소화)
        func updateDesktopModeIfNeeded() {
            guard let webView = webView else { return }
            
            // ✨ 데스크탑 모드 변경 시 JavaScript로만 처리 (새로고침 제거)
            if parent.stateModel.isDesktopMode != lastDesktopMode {
                lastDesktopMode = parent.stateModel.isDesktopMode
                
                // 사용자 에이전트 업데이트 (조용히)
                updateUserAgentIfNeeded()
                
                // JavaScript 함수 호출로 즉시 적용 (새로고침 없음)
                let script = "if (window.toggleDesktopMode) { window.toggleDesktopMode(\(parent.stateModel.isDesktopMode)); }"
                webView.evaluateJavaScript(script) { result, error in
                    if let error = error {
                        print("⚠️ 데스크탑 모드 토글 실패: \(error)")
                        // 에러가 있어도 새로고침하지 않음 (봇 감지 방지)
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

        // MARK: - ✨ WKNavigationDelegate (에러 처리 강화 + 스와이프 동기화)

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // ✅ 간단한 스와이프 뒤로가기 감지
            isSwipeBackNavigation = webView.canGoBack && 
                                  webView.backForwardList.backItem != nil

            // ✨ 로딩 시작을 StateModel에 전달
            DispatchQueue.main.async {
                if !self.parent.stateModel.isLoading {
                    self.parent.stateModel.isLoading = true
                }

                // ✅ 항상 0%로 시작 (KVO가 실제 진행률 업데이트)
                self.parent.stateModel.loadingProgress = 0.0
            }

            // ✅ 스와이프 제스처 감지 추가 - WebViewStateModel과 동기화
            if let startURL = webView.url {
                parent.stateModel.handleSwipeGestureDetected(to: startURL)
            }

            // 기존 StateModel의 didStartProvisionalNavigation 호출
            parent.stateModel.webView(webView, didStartProvisionalNavigation: navigation)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // ✨ 로딩 완료를 StateModel에 전달
            DispatchQueue.main.async {
                // ✅ 진행률을 먼저 확실히 100%로 설정
                self.parent.stateModel.loadingProgress = 1.0

                // 잠깐 후 로딩 상태 해제 (100% 표시 시간 확보)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.parent.stateModel.isLoading = false
                }

                // ✅ 스와이프 플래그 리셋
                self.isSwipeBackNavigation = false
            }
            
            // ✨ 새 페이지에서만 데스크탑 모드 설정 (기존 페이지에서는 스킵)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let script = """
                if (window.toggleDesktopMode && typeof window.desktopModeSynced === 'undefined') { 
                    window.toggleDesktopMode(\(self.parent.stateModel.isDesktopMode)); 
                    window.desktopModeSynced = true;
                    console.log('📄 새 페이지 초기화: 데스크탑모드=\(self.parent.stateModel.isDesktopMode)');
                }
                """
                webView.evaluateJavaScript(script, completionHandler: nil)
            }

            // 기존 StateModel의 didFinish 호출
            parent.stateModel.webView(webView, didFinish: navigation)
        }

        // ✅ 에러 처리 개선 - 로딩 시작 단계 에러 (didFailProvisionalNavigation)
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // ✨ 로딩 실패 처리
            DispatchQueue.main.async {
                if self.parent.stateModel.isLoading {
                    self.parent.stateModel.isLoading = false
                }
                self.parent.stateModel.loadingProgress = 0.0
            }

            let nsError = error as NSError

            // ✅ 스와이프 뒤로가기 중엔 모든 에러 무시
            if isSwipeBackNavigation {
                parent.stateModel.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
                return
            }

            // ✅ 사용자 취소는 무시 (새 URL 입력, 링크 클릭 등)
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                parent.stateModel.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
                return
            }

            // ✅ 명확한 에러 전달 - 모든 중요한 에러를 ContentView로 전달
            if shouldNotifyUserForError(nsError), let tabID = parent.stateModel.tabID {
                NotificationCenter.default.post(
                    name: Notification.Name("webViewDidFailLoad"),
                    object: nil,
                    userInfo: [
                        "tabID": tabID.uuidString,
                        "error": error,
                        "url": webView.url?.absoluteString ?? parent.stateModel.currentURL?.absoluteString ?? ""
                    ]
                )
                TabPersistenceManager.debugMessages.append("❌ 로딩 시작 에러 알림: \(nsError.code)")
            } else {
                TabPersistenceManager.debugMessages.append("🔕 무시된 로딩 시작 에러: \(nsError.code)")
            }

            // 기존 StateModel의 didFailProvisionalNavigation 호출
            parent.stateModel.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        }

        // ✅ 에러 처리 개선 - 로딩 진행 중 에러 (didFail)
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // ✨ 로딩 실패 처리
            DispatchQueue.main.async {
                if self.parent.stateModel.isLoading {
                    self.parent.stateModel.isLoading = false
                }
                self.parent.stateModel.loadingProgress = 0.0
            }

            let nsError = error as NSError

            // ✅ 명확한 에러 전달 - 로딩 진행 중 에러도 ContentView로 전달
            if shouldNotifyUserForError(nsError), let tabID = parent.stateModel.tabID {
                NotificationCenter.default.post(
                    name: Notification.Name("webViewDidFailLoad"),
                    object: nil,
                    userInfo: [
                        "tabID": tabID.uuidString,
                        "error": error,
                        "url": webView.url?.absoluteString ?? parent.stateModel.currentURL?.absoluteString ?? ""
                    ]
                )
                TabPersistenceManager.debugMessages.append("❌ 로딩 진행 에러 알림: \(nsError.code)")
            } else {
                TabPersistenceManager.debugMessages.append("🔕 무시된 로딩 진행 에러: \(nsError.code)")
            }

            // 기존 StateModel의 didFail 호출
            parent.stateModel.webView(webView, didFail: navigation, withError: error)
        }

        // ✅ HTTP 에러 필터링 - 메인 페이지와 내부 API/리소스 구분
        private func shouldNotifyForHTTPError(statusCode: Int, responseURL: URL?, mainURL: URL?) -> Bool {
            guard let responseURL = responseURL else { return false }

            // ✅ 메인 페이지 URL과 같은 도메인이면 알림 (사용자가 직접 접근한 페이지)
            if let mainURL = mainURL, 
               responseURL.host == mainURL.host {
                TabPersistenceManager.debugMessages.append("🏠 메인 도메인 HTTP 에러: \(statusCode) - \(responseURL.host ?? "")")
                return true
            }

            // ✅ OAuth/로그인 관련 도메인은 무시 (정상적인 플로우)
            let oauthDomains = [
                "accounts.google.com",
                "login.microsoftonline.com", 
                "appleid.apple.com",
                "www.facebook.com",
                "api.twitter.com",
                "github.com",
                "oauth.googleusercontent.com"
            ]

            if let host = responseURL.host?.lowercased(),
               oauthDomains.contains(where: { host.contains($0) }) {
                TabPersistenceManager.debugMessages.append("🔐 OAuth 도메인 HTTP 에러 무시: \(statusCode) - \(host)")
                return false
            }

            // ✅ 광고/트래킹 관련 도메인 무시
            let adDomains = [
                "googleads", "doubleclick", "googlesyndication", "googletagmanager",
                "facebook.com", "fbcdn", "amazon-adsystem", "adsystem.amazon",
                "analytics", "gtag", "gtm", "pixel", "tracking", "metrics"
            ]

            if let host = responseURL.host?.lowercased(),
               adDomains.contains(where: { host.contains($0) }) {
                TabPersistenceManager.debugMessages.append("📊 광고/트래킹 도메인 HTTP 에러 무시: \(statusCode) - \(host)")
                return false
            }

            // ✅ API 엔드포인트 무시 (api., rest., graphql. 등)
            if let host = responseURL.host?.lowercased(),
               (host.hasPrefix("api.") || 
                host.hasPrefix("rest.") || 
                host.hasPrefix("graphql.") ||
                host.contains("api")) {
                TabPersistenceManager.debugMessages.append("🔌 API 엔드포인트 HTTP 에러 무시: \(statusCode) - \(host)")
                return false
            }

            // ✅ CDN/리소스 도메인 무시
            let cdnDomains = [
                "amazonaws.com", "cloudfront.net", "cdn", "static",
                "gstatic.com", "googleapis.com", "bootstrapcdn.com"
            ]

            if let host = responseURL.host?.lowercased(),
               cdnDomains.contains(where: { host.contains($0) }) {
                TabPersistenceManager.debugMessages.append("🌍 CDN/리소스 도메인 HTTP 에러 무시: \(statusCode) - \(host)")
                return false
            }

            // ✅ 심각한 에러만 알림 (404, 500 등)
            switch statusCode {
            case 404, 500, 502, 503, 504:
                TabPersistenceManager.debugMessages.append("🚨 심각한 HTTP 에러 알림: \(statusCode) - \(responseURL.host ?? "")")
                return true
            default:
                // 403, 401 등은 대부분 내부 API/인증 관련이므로 무시
                TabPersistenceManager.debugMessages.append("🔕 일반 HTTP 에러 무시: \(statusCode) - \(responseURL.host ?? "")")
                return false
            }
        }

        private func shouldNotifyUserForError(_ error: NSError) -> Bool {
            // NSURLError가 아닌 경우는 무시 (내부 리소스 에러 등)
            guard error.domain == NSURLErrorDomain else { 
                TabPersistenceManager.debugMessages.append("🔕 비-NSURLError 도메인 무시: \(error.domain)")
                return false 
            }

            switch error.code {
            // ✅ 메인 페이지 로딩 실패 - 반드시 알려야 할 중요한 에러들만
            case NSURLErrorCannotFindHost:           // 잘못된 주소/도메인
                TabPersistenceManager.debugMessages.append("📍 주소를 찾을 수 없음: \(error.code)")
                return true
            case NSURLErrorBadURL,                   // 잘못된 URL 형식
                 NSURLErrorUnsupportedURL:           // 지원하지 않는 URL 형식
                TabPersistenceManager.debugMessages.append("🔗 잘못된 URL 형식: \(error.code)")
                return true
            case NSURLErrorTimedOut:                 // 타임아웃
                TabPersistenceManager.debugMessages.append("⏰ 연결 시간 초과: \(error.code)")
                return true
            case NSURLErrorNotConnectedToInternet:   // 인터넷 연결 없음
                TabPersistenceManager.debugMessages.append("📶 인터넷 연결 없음: \(error.code)")
                return true
            case NSURLErrorCannotConnectToHost:      // 서버 연결 불가
                TabPersistenceManager.debugMessages.append("🖥️ 서버 연결 실패: \(error.code)")
                return true
            case NSURLErrorNetworkConnectionLost:    // 네트워크 연결 끊김
                TabPersistenceManager.debugMessages.append("📡 네트워크 연결 끊김: \(error.code)")
                return true
            case NSURLErrorDNSLookupFailed:          // DNS 조회 실패
                TabPersistenceManager.debugMessages.append("🌐 DNS 조회 실패: \(error.code)")
                return true

            // ✅ 무시할 에러들 (모든 기타 에러들)
            default:
                // ✅ 알 수 없는 에러는 무시 (내부 리소스, 광고, 이미지 등의 실패)
                TabPersistenceManager.debugMessages.append("🔕 알 수 없는 에러 무시: \(error.code) - 내부 리소스 실패 추정")
                return false
            }
        }

        // ✨ HTTP 상태 코드 에러 감지 (decidePolicyFor navigationResponse에서) - 필터링 강화
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {

            // HTTP 응답 상태 코드 체크
            if let httpResponse = navigationResponse.response as? HTTPURLResponse {
                let statusCode = httpResponse.statusCode
                let responseURL = navigationResponse.response.url
                let mainURL = parent.stateModel.currentURL

                // ✅ 4xx, 5xx 에러이지만 스마트 필터링 적용
                if statusCode >= 400 {
                    let shouldNotifyHTTPError = shouldNotifyForHTTPError(
                        statusCode: statusCode, 
                        responseURL: responseURL, 
                        mainURL: mainURL
                    )

                    if shouldNotifyHTTPError, let tabID = parent.stateModel.tabID {
                        NotificationCenter.default.post(
                            name: Notification.Name("webViewDidFailLoad"),
                            object: nil,
                            userInfo: [
                                "tabID": tabID.uuidString,
                                "statusCode": statusCode,
                                "url": responseURL?.absoluteString ?? ""
                            ]
                        )
                        TabPersistenceManager.debugMessages.append("❌ HTTP 에러 알림: \(statusCode) - \(responseURL?.host ?? "")")
                    } else {
                        TabPersistenceManager.debugMessages.append("🔕 HTTP 에러 무시: \(statusCode) - \(responseURL?.host ?? "") (내부 API/OAuth)")
                    }
                }
            }

            // 다운로드 처리 (iOS 14+)
            if #available(iOS 14.0, *) {
                if let http = navigationResponse.response as? HTTPURLResponse,
                   let disp = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
                   disp.contains("attachment") {
                    decisionHandler(.download)
                    return
                }
            }

            decisionHandler(.allow)
        }

        // ✨ 다운로드 지원 (iOS 14+)
        @available(iOS 14.0, *)
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = parent.stateModel
        }

        // MARK: - 네비게이션 정책 결정
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            
            // ✅ 팝업에서 오는 요청 체크 (새 창)
            if navigationAction.targetFrame == nil {
                // 새 창 요청은 현재 웹뷰에서 열기
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }
            
            // 일반적인 경우는 허용
            decisionHandler(.allow)
        }

        // MARK: JS → 네이티브 메시지 처리 (완벽 동기화)
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
                   let action = data["action"] as? String {
                    
                    DispatchQueue.main.async {
                        switch action {
                        case "update":
                            // ✨ 줌 레벨 업데이트 (JavaScript → 네이티브)
                            if let zoom = data["zoom"] as? Double {
                                self.parent.stateModel.currentZoomLevel = zoom
                                print("🔍 JS → 네이티브 줌 동기화: \(zoom)x")
                            }
                            
                        case "desktopModeChanged":
                            // ✨ 데스크탑 모드 상태 동기화 (JavaScript → 네이티브)
                            if let enabled = data["enabled"] as? Bool {
                                if self.parent.stateModel.isDesktopMode != enabled {
                                    self.parent.stateModel.isDesktopMode = enabled
                                    print("🖥️ JS → 네이티브 모드 동기화: \(enabled ? "데스크탑" : "모바일")")
                                }
                            }
                            
                        default:
                            break
                        }
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
            if webView?.canGoBack == true { 
                webView?.goBack()
            }
        }
        @objc func goForward() { 
            if webView?.canGoForward == true { 
                webView?.goForward()
            }
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

// MARK: - 전역 쿠키 동기화 추적
private let _cookieSyncInstalledModels = NSHashTable<AnyObject>.weakObjects()

// MARK: - WebViewStateModel 확장 (쿠키 세션 공유 + 스와이프 동기화)
extension WebViewStateModel {

    // ✅ 스와이프-버튼 동기화를 위한 didCommit 처리
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // 기존 쿠키 동기화 로직
        _installCookieSyncIfNeeded(for: webView)
        CookieSyncManager.syncAppToWebView(webView, completion: nil)

        // ✅ 추가: 스와이프-버튼 동기화 연동
        handleDidCommitNavigation()
    }

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

// MARK: - 파일 다운로드 지원 (iOS 14+)
private final class DownloadCoordinator {
    static let shared = DownloadCoordinator()
    private init() {}
    private var map = [ObjectIdentifier: URL]()
    func set(url: URL, for download: WKDownload) { map[ObjectIdentifier(download)] = url }
    func url(for download: WKDownload) -> URL? { map[ObjectIdentifier(download)] }
    func remove(_ download: WKDownload) { map.removeValue(forKey: ObjectIdentifier(download)) }
}

private func sanitizedFilename( name: String) -> String {
    var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    result = result.components(separatedBy: forbidden).joined(separator: "")
    if result.count > 150 {
        result = String(result.prefix(150))
    }
    return result.isEmpty ? "download" : result
}

private func topMostViewController() -> UIViewController? {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let root = window.rootViewController else { return nil }
    var top = root
    while let presented = top.presentedViewController { top = presented }
    return top
}

// MARK: - WebViewStateModel: WKDownloadDelegate
extension WebViewStateModel: WKDownloadDelegate {
    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         decideDestinationUsing response: URLResponse,
                         suggestedFilename: String,
                         completionHandler: @escaping (URL?) -> Void) {

        NotificationCenter.default.post(name: .WebViewDownloadStart,
                                        object: nil,
                                        userInfo: ["filename": suggestedFilename])

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsDir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let safeName = sanitizedFilename(name: suggestedFilename)
        let dst = downloadsDir.appendingPathComponent(safeName)

        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
        }

        DownloadCoordinator.shared.set(url: dst, for: download)
        completionHandler(dst)
    }

    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         didWriteData bytesWritten: Int64,
                         totalBytesWritten: Int64,
                         totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        NotificationCenter.default.post(name: .WebViewDownloadProgress,
                                        object: nil,
                                        userInfo: ["progress": progress])
    }

    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         didFailWithError error: Error,
                         resumeData: Data?) {
        let filename = DownloadCoordinator.shared.url(for: download)?.lastPathComponent ?? "파일"
        DownloadCoordinator.shared.remove(download)

        NotificationCenter.default.post(name: .WebViewDownloadFailed, object: nil)

        DispatchQueue.main.async {
            if let top = topMostViewController() {
                let alert = UIAlertController(title: "다운로드 실패",
                                              message: "\(filename) 다운로드 중 오류가 발생했습니다.\n\(error.localizedDescription)",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "확인", style: .default))
                top.present(alert, animated: true)
            }
        }
    }

    @available(iOS 14.0, *)
    public func downloadDidFinish(_ download: WKDownload) {
        guard let fileURL = DownloadCoordinator.shared.url(for: download) else {
            TabPersistenceManager.debugMessages.append("⚠️ 다운로드 완료했지만 파일 경로를 찾을 수 없음")
            NotificationCenter.default.post(name: .WebViewDownloadFinish, object: nil)
            return
        }
        DownloadCoordinator.shared.remove(download)

        NotificationCenter.default.post(name: .WebViewDownloadFinish, object: nil)

        DispatchQueue.main.async {
            guard let top = topMostViewController() else { return }
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activityVC.popoverPresentationController?.sourceView = top.view
            top.present(activityVC, animated: true)
        }
    }
}
