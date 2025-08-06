import SwiftUI
import WebKit
import AVFoundation

// MARK: - CustomWebView
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    // MARK: - makeUIView
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        // 웹뷰 설정 구성
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 사용자 스크립트/메시지 핸들러
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())
        controller.add(context.coordinator, name: "playVideo")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // 최초 delegate 연결
        webView.navigationDelegate = stateModel
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        stateModel.webView = webView // 🔧 webView 설정 시 대기 중인 복원 로직이 자동 실행됨

        // Pull to Refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refreshControl

        // 🔧 세션 복원 또는 초기 로드 (단순화)
        if let session = stateModel.pendingSession {
            TabPersistenceManager.debugMessages.append("세션 복원 시작: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
            // 복원은 이제 WebViewStateModel 내부에서 자동 처리됨 (webView 설정 시 트리거)
            stateModel.pendingSession = nil
        } else if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("초기 URL 로드: \(url)")
        }

        // 전역 네비게이션 액션(Notification 기반) 수신
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
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.reloadWebView),
            name: .init("WebViewReload"),
            object: nil
        )

        return webView
    }

    // MARK: - updateUIView
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 🛠 재사용 방지용 재바인딩(필수)
        if uiView.navigationDelegate !== stateModel {
            uiView.navigationDelegate = stateModel
            TabPersistenceManager.debugMessages.append("재바인딩: navigationDelegate -> stateModel(\(stateModel.tabID?.uuidString ?? "no-id"))")
        }
        if uiView.uiDelegate !== context.coordinator {
            uiView.uiDelegate = context.coordinator
            TabPersistenceManager.debugMessages.append("재바인딩: uiDelegate -> coordinator")
        }
        if stateModel.webView !== uiView {
            stateModel.webView = uiView
            TabPersistenceManager.debugMessages.append("재바인딩: stateModel.webView <- uiView (탭 \(stateModel.tabID?.uuidString ?? "no-id"))")
        }
        if context.coordinator.webView !== uiView {
            context.coordinator.webView = uiView
        }

        // 🛠 세션 복원 중엔 불필요한 재로드 금지
        if stateModel.isRestoringSession {
            return
        }

        // URL 변경 시에만 로드 (중복 네비게이션 방지)
        guard let url = stateModel.currentURL else { return }
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("URL 업데이트 로드: \(url)")
        }
    }

    // MARK: - dismantleUIView
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
        TabPersistenceManager.debugMessages.append("WebView 소멸: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - 사용자 스크립트 (비디오 클릭 → AVPlayer로 재생 / PiP 활성 시도)
    private func makeVideoScript() -> WKUserScript {
        let scriptSource = """
        function processVideos(doc) {
            [...doc.querySelectorAll('video')].forEach(video => {
                // iOS 사파리 자동재생 제약 회피를 위해 기본 mute
                video.muted = true;
                video.volume = 0;
                video.setAttribute('muted','true');

                // AVPlayer로 넘기는 클릭 핸들러는 1회만 부착
                if (!video.hasAttribute('nativeAVPlayerListener')) {
                    video.addEventListener('click', () => {
                        window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
                    });
                    video.setAttribute('nativeAVPlayerListener', 'true');
                }

                // 가능하면 PiP 자동 진입 시도(실패해도 무시)
                if (document.pictureInPictureEnabled &&
                    !video.disablePictureInPicture &&
                    !document.pictureInPictureElement) {
                    try { video.requestPictureInPicture().catch(() => {}); } catch (e) {}
                }
            });
        }

        // 최초/주기적으로 DOM 스캔(iframe 내부도 시도)
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

    // MARK: - 오디오 세션 (다른 앱과 믹싱 허용)
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        TabPersistenceManager.debugMessages.append("오디오 세션 활성화")
    }
