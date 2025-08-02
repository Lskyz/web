import SwiftUI
import WebKit
import AVFoundation

struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    
    // ✅ AVPlayer 연동용 바인딩
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()
        
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        // ✅ pull to refresh 연결
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        
        // ✅ 알림 센터 등록
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
        
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // ✅ JavaScript 핸들러 등록: 영상 클릭 시 AVPlayer로 전송
        let controller = webView.configuration.userContentController
        controller.add(context.coordinator, name: "playVideo")
        let js = """
        function setupNativeVideoPlayer() {
          [...document.querySelectorAll('video')].forEach(video => {
            video.muted = true;
            video.volume = 0;
            video.setAttribute('muted', 'true');

            if (!video.hasAttribute('nativeAVPlayerListener')) {
              video.addEventListener('click', () => {
                window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
              });
              video.setAttribute('nativeAVPlayerListener', 'true');
            }
          });
        }
        setupNativeVideoPlayer();
        setInterval(setupNativeVideoPlayer, 1000);
        """
        let userScript = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        controller.addUserScript(userScript)

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
    
    // MARK: Audio Session
    private func configureAudioSessionForMixing() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
        }

        // ✅ AVPlayer로 URL 전송
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo",
               let urlString = message.body as? String,
               let url = URL(string: urlString) {
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

        // ✅ 새창 방지 처리
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
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