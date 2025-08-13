//
//  CustomWebView.swift
//
//  🌐 통합된 SPA 네비게이션 + 로그인 리다이렉트 필터링
//  🎯 네이버 특화 로직을 범용으로 사용 (중복 제거)
//  🔒 로그인 관련 임시 페이지 히스토리 제외
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
        controller.addUserScript(makeDesktopModeScript())
        // 🌐 통합된 SPA 네비게이션 스크립트 (네이버 로직을 범용으로)
        controller.addUserScript(makeUnifiedSPANavigationScript())
        controller.add(context.coordinator, name: "playVideo")
        controller.add(context.coordinator, name: "setZoom")
        // 🌐 단일 통합 SPA 메시지 핸들러
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
        
        webView.scrollView.contentInsetAdjustmentBehavior = .naver
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

        // 🎯 커스텀 제스처 추가
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

        // 🎯 커스텀 제스처 제거
        coordinator.removeCustomGestures(from: uiView)

        // 오디오 세션 비활성화
        coordinator.parent.deactivateAudioSession()

        // 메시지 핸들러 제거
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "playVideo")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "setZoom")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "spaNavigation")

        // 모든 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - 🌐 통합된 SPA 네비게이션 스크립트 (네이버 로직을 범용으로 사용)
    private func makeUnifiedSPANavigationScript() -> WKUserScript {
        let scriptSource = """
        // 🌐 통합된 SPA 네비게이션 감지 (네이버 특화 로직을 범용으로 사용)
        (function() {
            'use strict';
            
            console.log('🌐 통합된 SPA 네비게이션 훅 초기화');
            
            // 원본 History API 메서드들 백업
            const originalPushState = history.pushState;
            const originalReplaceState = history.replaceState;
            
            // 현재 상태 추적
            let currentSPAState = {
                url: window.location.href,
                title: document.title,
                timestamp: Date.now(),
                state: history.state
            };
            
            // 🔒 로그인/리다이렉트 관련 URL 패턴 (히스토리에서 제외)
            const EXCLUDE_PATTERNS = [
                /\\/login/i,
                /\\/signin/i,
                /\\/auth/i,
                /\\/oauth/i,
                /\\/sso/i,
                /\\/redirect/i,
                /\\/callback/i,
                /\\/nid\\.naver\\.com/i,
                /\\/accounts\\.google\\.com/i,
                /\\/facebook\\.com\\/login/i,
                /\\/twitter\\.com\\/oauth/i,
                /returnUrl=/i,
                /redirect_uri=/i,
                /continue=/i
            ];
            
            // URL이 제외 대상인지 확인
            function shouldExcludeFromHistory(url) {
                return EXCLUDE_PATTERNS.some(pattern => pattern.test(url));
            }
            
            // URL 패턴 분석 (범용)
            function detectSiteType(url) {
                const urlObj = new URL(url, window.location.origin);
                const host = urlObj.hostname.toLowerCase();
                const path = urlObj.pathname.toLowerCase();
                
                // 패턴 분석 (백슬래시 이스케이프 수정)
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
            
            // 네이티브로 네비게이션 알림
            function notifyNavigation(type, url, title, state) {
                // 🔒 제외 대상은 알림하지 않음
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
                
                // 🌐 단일 통합 메시지 핸들러로 전송
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.spaNavigation) {
                    window.webkit.messageHandlers.spaNavigation.postMessage(message);
                    console.log(`🌐 SPA ${type}: ${siteType} | ${url}`);
                }
            }
            
            // pushState 훅 (새 페이지 추가)
            history.pushState = function(state, title, url) {
                console.log('🌐 pushState 감지:', url);
                
                // 원본 메서드 실행
                const result = originalPushState.call(this, state, title, url);
                
                // URL이 실제로 변경되었는지 확인
                const newURL = new URL(url || window.location.href, window.location.origin).href;
                if (newURL !== currentSPAState.url) {
                    currentSPAState = {
                        url: newURL,
                        title: title || document.title,
                        timestamp: Date.now(),
                        state: state
                    };
                    
                    // 약간의 지연 후 제목 업데이트 및 알림
                    setTimeout(() => {
                        notifyNavigation('push', newURL, document.title, state);
                    }, 150); // 제목 변경 대기
                }
                
                return result;
            };
            
            // replaceState 훅 (현재 페이지 교체)
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
            
            // popstate 이벤트 감지 (뒤로가기/앞으로가기)
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
            
            // 해시 변경 감지
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
            
            // 🌐 iframe 감지 (범용 처리)
            function setupIframeDetection() {
                // iframe 내부 네비게이션 감지
                const checkIframes = () => {
                    document.querySelectorAll('iframe').forEach(iframe => {
                        try {
                            if (iframe.contentWindow && iframe.contentWindow.location) {
                                const iframeURL = iframe.contentWindow.location.href;
                                
                                // iframe 내부의 pushState/replaceState도 후킹
                                if (iframe.contentWindow.history && !iframe.contentWindow.__spa_hooked) {
                                    iframe.contentWindow.__spa_hooked = true;
                                    
                                    const iframeOriginalPushState = iframe.contentWindow.history.pushState;
                                    iframe.contentWindow.history.pushState = function(state, title, url) {
                                        console.log('🌐 iframe pushState:', url);
                                        const result = iframeOriginalPushState.call(this, state, title, url);
                                        
                                        setTimeout(() => {
                                            const fullURL = new URL(url || iframe.contentWindow.location.href, iframe.contentWindow.location.origin).href;
                                            notifyNavigation('iframe_push', fullURL, iframe.contentDocument?.title || title, state);
                                        }, 200);
                                        
                                        return result;
                                    };
                                }
                            }
                        } catch (e) {
                            // Cross-origin iframe은 접근 불가 (정상)
                        }
                    });
                };
                
                // 주기적으로 iframe 체크
                setInterval(checkIframes, 2000);
                
                // DOM 변화 감지로 새 iframe 체크
                if (window.MutationObserver) {
                    const observer = new MutationObserver(() => {
                        setTimeout(checkIframes, 500);
                    });
                    observer.observe(document.body, { childList: true, subtree: true });
                }
            }
            
            // 제목 변경 감지
            if (window.MutationObserver) {
                const titleObserver = new MutationObserver(function(mutations) {
                    mutations.forEach(function(mutation) {
                        if (mutation.type === 'childList' && document.title !== currentSPAState.title) {
                            console.log('🌐 제목 변경 감지:', document.title);
                            currentSPAState.title = document.title;
                            
                            // 제목만 변경된 경우
                            if (!shouldExcludeFromHistory(window.location.href)) {
                                const message = {
                                    type: 'title',
                                    url: window.location.href,
                                    title: document.title,
                                    state: history.state,
                                    timestamp: Date.now(),
                                    siteType: detectSiteType(window.location.href),
                                    shouldExclude: false
                                };
                                
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.spaNavigation) {
                                    window.webkit.messageHandlers.spaNavigation.postMessage(message);
                                }
                            }
                        }
                    });
                });
                
                // title 태그와 body 변경 모두 감지
                const titleElement = document.querySelector('title');
                if (titleElement) {
                    titleObserver.observe(titleElement, { childList: true, subtree: true });
                }
                titleObserver.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['title'] });
            }
            
            // 페이지 로드 완료 후 iframe 처리 시작
            if (document.readyState === 'complete') {
                setupIframeDetection();
            } else {
                window.addEventListener('load', setupIframeDetection);
            }
            
            console.log('✅ 통합된 SPA 네비게이션 훅 설정 완료');
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - ✨ 데스크탑 모드 강제 JS 스크립트 (기존 유지)
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

    // MARK: - Coordinator
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

        init(_ parent: CustomWebView) {
    self.parent = parent
    self.lastDesktopMode = parent.stateModel.isDesktopMode
    super.init()
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleKeyboardChange(_:)),
        name: UIResponder.keyboardWillChangeFrameNotification,
        object: nil
    )
}

        // ✅ 2) deinit 교체
deinit {
    removeLoadingObservers(for: webView)
    NotificationCenter.default.removeObserver(self)
}
@objc private func handleKeyboardChange(_ n: Notification) {
    guard let wv = webView,
          let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else { return }

    let screenH = wv.window?.bounds.height ?? UIScreen.main.bounds.height
    let visibleH = max(0, screenH - end.origin.y)

    // ✅ 키보드가 완전히 사라진 순간, 남아 있는 하단 인셋 제거
    if visibleH == 0 {
        wv.scrollView.contentInset = .zero
        wv.scrollView.scrollIndicatorInsets = .zero
    }
}
        
        // MARK: - 🎯 커스텀 제스처 설정
        
        func setupCustomGestures(for webView: WKWebView) {
            let backGesture = UIScreenEdgePanGestureRecognizer(
                target: self, 
                action: #selector(handleBackGesture(_:))
            )
            backGesture.edges = .left
            backGesture.delegate = self
            webView.addGestureRecognizer(backGesture)
            self.backGesture = backGesture
            
            let forwardGesture = UIScreenEdgePanGestureRecognizer(
                target: self,
                action: #selector(handleForwardGesture(_:))
            )
            forwardGesture.edges = .right
            forwardGesture.delegate = self
            webView.addGestureRecognizer(forwardGesture)
            self.forwardGesture = forwardGesture
            
            TabPersistenceManager.debugMessages.append("🎯 강화된 커스텀 제스처 설정 완료")
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
        
        // MARK: - 🎯 커스텀 제스처 핸들러들
        
        @objc func handleBackGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            
            let translation = gesture.translation(in: gesture.view)
            guard translation.x > 50 else { return }
            
            if parent.stateModel.canGoBack {
                parent.stateModel.goBack()
                TabPersistenceManager.debugMessages.append("👆 강화된 뒤로가기 제스처")
            }
        }
        
        @objc func handleForwardGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            
            let translation = gesture.translation(in: gesture.view)
            guard translation.x < -50 else { return }
            
            if parent.stateModel.canGoForward {
                parent.stateModel.goForward()
                TabPersistenceManager.debugMessages.append("👆 강화된 앞으로가기 제스처")
            }
        }
        
        // MARK: - UIGestureRecognizerDelegate
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if otherGestureRecognizer is UIPanGestureRecognizer && gestureRecognizer is UIScreenEdgePanGestureRecognizer {
                return false
            }
            return true
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return gestureRecognizer is UIScreenEdgePanGestureRecognizer
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
            loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
                guard let self = self else { return }
                let isLoading = change.newValue ?? false

                DispatchQueue.main.async {
                    if self.parent.stateModel.isLoading != isLoading {
                        self.parent.stateModel.isLoading = isLoading
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
                    if self.parent.stateModel.currentURL != url {
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

        // MARK: - 🌐 통합된 JS 메시지 처리 (단일 핸들러)
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
                // 🌐 통합된 SPA 네비게이션 처리
                if let data = message.body as? [String: Any],
                   let type = data["type"] as? String,
                   let urlString = data["url"] as? String,
                   let url = URL(string: urlString) {
                    
                    let title = data["title"] as? String ?? ""
                    let timestamp = data["timestamp"] as? Double ?? Date().timeIntervalSince1970 * 1000
                    let shouldExclude = data["shouldExclude"] as? Bool ?? false
                    let siteType = data["siteType"] as? String ?? "unknown"
                    
                    DispatchQueue.main.async {
                        // 🔒 제외 대상이면 처리하지 않음
                        if shouldExclude {
                            TabPersistenceManager.debugMessages.append("🔒 히스토리 제외: \(urlString)")
                            return
                        }
                        
                        // ✅ 하나의 통합된 함수로 처리
                        self.parent.stateModel.dataModel.handleSPANavigation(
                            type: type,
                            url: url,
                            title: title,
                            timestamp: timestamp,
                            siteType: siteType
                        )
                        
                        TabPersistenceManager.debugMessages.append("🌐 SPA \(type)(\(siteType)): \(urlString)")
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

                    alert.addAction(UIAlertAction(title: "무시하고 방문", style: .destructive) { _ in
                        let credential = URLCredential(trust: serverTrust)
                        completionHandler(.useCredential, credential)
                        TabPersistenceManager.debugMessages.append("🔓 SSL 경고 무시: \(host)")
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
