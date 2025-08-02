import SwiftUI
import WebKit
import AVFoundation

/// ✅ WebView + AVPlayer + PIP 를 한 번에 관리하는 커스텀 뷰
struct CustomWebView: UIViewRepresentable {
    /// 반드시 @ObservedObject ― state 변경 시 updateUIView 호출
    @ObservedObject var stateModel: WebViewStateModel       // (FIXED)
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        // 🔧 WKWebView 설정
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 🔧 사용자 스크립트 & 메시지 핸들러
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())
        controller.add(context.coordinator, name: "playVideo")
        config.userContentController = controller

        // 🔧 WebView 인스턴스
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // 🔧 Pull-to-refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // 🔧 초기 로드
        if let url = stateModel.currentURL {
            print("🌐 초기 로딩: \(url.absoluteString)")
            webView.load(URLRequest(url: url))
        }

        // 🔧 알림 → WebView 조작
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.goBack),
                                               name: NSNotification.Name("WebViewGoBack"),
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.goForward),
                                               name: NSNotification.Name("WebViewGoForward"),
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.reloadWebView),
                                               name: NSNotification.Name("WebViewReload"),
                                               object: nil)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // URL이 바뀌면 강제 로드
        guard let target = stateModel.currentURL else { return }
        if uiView.url?.scheme != target.scheme ||
            uiView.url?.host  != target.host  ||
            uiView.url?.path  != target.path {
            print("🔄 updateUIView → \(target)")
            uiView.load(URLRequest(url: target))
        }
    }

    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - 사용자 스크립트
    private func makeVideoScript() -> WKUserScript {
        let source = """
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
                // 자동 PIP 진입
                if (document.pictureInPictureEnabled &&
                    !video.disablePictureInPicture &&
                    !document.pictureInPictureElement) {
                    try { video.requestPictureInPicture().catch(() => {}); } catch(e) {}
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
        return WKUserScript(source: source,
                            injectionTime: .atDocumentEnd,
                            forMainFrameOnly: false)
    }

    // MARK: - Audio Session
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }
    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) { self.parent = parent }

        // 🔹 네비게이션 조작용 메서드
        @objc func goBack()     { webView?.goBack()     }
        @objc func goForward()  { webView?.goForward()  }
        @objc func reloadWebView() { webView?.reload()  }
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // 🔹 페이지 로딩 성공 시
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack    = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL   = webView.url
            print("✅ 페이지 로딩 완료: \(webView.url?.absoluteString ?? "nil")")
        }

        // 🔹 새 창 요청 무시 → 현재 WebView 사용
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // 🔹 영상 클릭 → AVPlayerView 전환
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "playVideo",
                  let urlString = message.body as? String,
                  let videoURL  = URL(string: urlString) else { return }
            DispatchQueue.main.async {
                self.parent.playerURL    = videoURL
                self.parent.showAVPlayer = true
            }
        }

        // --------------------------------------------------------------------
        // 🔻[ADD] 로딩 실패 로그 ― 요청하신 부분
        // --------------------------------------------------------------------
        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            print("❌ Provisional fail: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            print("❌ Navigation fail: \(error.localizedDescription)")
        }
        // --------------------------------------------------------------------

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}