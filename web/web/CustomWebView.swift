import SwiftUI
import WebKit
import AVFoundation

// ✅ SwiftUI에서 WKWebView를 사용할 수 있게 래핑
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel      // 🔄 상태 감지용
    @Binding var playerURL: URL?                           // 🎬 AVPlayer 재생 URL
    @Binding var showAVPlayer: Bool                        // 🎬 AVPlayer 표시 여부

    // MARK: - UIView 생성
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing() // 🔇 무음 오디오 세션 유지

        // 🔧 WebView 설정 구성
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true                    // 🔊 인라인 재생 허용
        config.allowsPictureInPictureMediaPlayback = true          // 🎬 PIP 재생 허용
        config.mediaTypesRequiringUserActionForPlayback = []       // ▶️ 사용자 조작 없이 재생 가능

        // ✅ JavaScript 삽입 및 메시지 핸들러 등록
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())                // 🎥 video 태그 처리 스크립트
        controller.add(context.coordinator, name: "playVideo")     // 🎬 영상 클릭 → 메시지 전달

        config.userContentController = controller

        // ✅ WebView 인스턴스 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true         // ⬅️➡️ 제스처 허용
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // 🔄 Pull-to-Refresh 적용
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // 🌐 초기 페이지 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // 🔁 외부에서 보낸 WebView 조작 알림 수신
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goBack), name: NSNotification.Name("WebViewGoBack"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goForward), name: NSNotification.Name("WebViewGoForward"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.reloadWebView), name: NSNotification.Name("WebViewReload"), object: nil)

        return webView
    }

    // MARK: - UIView 업데이트 (URL 변경 시)
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = stateModel.currentURL else { return }

        // ❗️현재 URL과 다른 경우에만 로딩
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
    }

    // MARK: - WebView 제거 시 호출
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Coordinator 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - JavaScript 생성
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

                // 🎬 자동 PIP 진입
                if (document.pictureInPictureEnabled &&
                    !video.disablePictureInPicture &&
                    !document.pictureInPictureElement) {
                    try {
                        video.requestPictureInPicture().catch(() => {});
                    } catch (e) {}
                }
            });
        }

        processVideos(document);
        setInterval(() => {
            processVideos(document);

            // 🖼 iframe 안 video도 처리
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

    // MARK: - 오디오 세션 설정 (무음 유지)
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Coordinator (델리게이트 + 메시지 핸들러)
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
        }

        // 🔁 외부 알림 → WebView 동작
        @objc func goBack() { webView?.goBack() }
        @objc func goForward() { webView?.goForward() }
        @objc func reloadWebView() { webView?.reload() }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // ✅ 페이지 로딩 완료
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url
        }

        // ✅ 새 창 열기 차단 (현재 WebView로 처리)
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // ✅ JavaScript → Swift로 메시지 수신 → AVPlayer 전환
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "playVideo",
               let urlString = message.body as? String,
               let videoURL = URL(string: urlString) {
                DispatchQueue.main.async {
                    self.parent.playerURL = videoURL
                    self.parent.showAVPlayer = true
                }
            }
        }

        // ❌ 로딩 실패: 초기 네트워크/도메인 오류
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("❌ Provisional fail: \(error.localizedDescription)")
        }

        // ❌ 로딩 실패: 진행 중 오류
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Navigation fail: \(error.localizedDescription)")
        }
    }
}