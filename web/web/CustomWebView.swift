import SwiftUI
import WebKit
import AVFoundation
import AVKit

struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?                // ✅ AVPlayer용 URL 바인딩
    @Binding var showAVPlayer: Bool             // ✅ AVPlayer 표시 여부 바인딩

    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()

        // ✅ JavaScript: video 요소 클릭 시 AVPlayerViewController로 전환하도록 설정
        let jsScript = """
        document.querySelectorAll('video').forEach(video => {
            video.muted = true;
            video.setAttribute('muted', 'true');
            video.volume = 0;

            if (!video.hasAttribute('nativeAVPlayerListener')) {
                video.addEventListener('click', () => {
                    window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
                });
                video.setAttribute('nativeAVPlayerListener', 'true');
            }
        });
        """
        let userScript = WKUserScript(source: jsScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        controller.addUserScript(userScript)

        // ✅ Swift → JavaScript 통신 연결
        controller.add(context.coordinator, name: "playVideo")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // ✅ Pull to refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // ✅ 최초 로딩
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // ✅ 알림 연결
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goBack), name: NSNotification.Name("WebViewGoBack"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goForward), name: NSNotification.Name("WebViewGoForward"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.reloadWebView), name: NSNotification.Name("WebViewReload"), object: nil)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url = stateModel.currentURL, uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }

    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // ✅ 오디오 세션: 다른 앱과 동시 재생 허용
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
            super.init()
        }

        // ✅ AVPlayer로 재생 요청이 들어왔을 때 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo", let urlString = message.body as? String, let url = URL(string: urlString) {
                parent.playerURL = url
                parent.showAVPlayer = true
            }
        }

        @objc func goBack() {
            webView?.goBack()
        }

        @objc func goForward() {
            webView?.goForward()
        }

        @objc func reloadWebView() {
            webView?.reload()
        }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url
        }

        // ✅ 새창 방지: target="_blank" → 현재 창에서 열기
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}