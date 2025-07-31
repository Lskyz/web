import SwiftUI
import WebKit
import AVFoundation
import AVKit

struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 처음부터 음소거 설정 JS (페이지 시작 시)
        let muteScript = """
        document.querySelectorAll('video').forEach(video => {
            video.muted = true;
            video.setAttribute('muted', 'true');
            video.volume = 0;
        });
        """
        let userScript = WKUserScript(source: muteScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)

        // 영상 클릭 이벤트 감지용 메시지 핸들러 추가
        config.userContentController.add(context.coordinator, name: "playVideo")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        webView.navigationDelegate = context.coordinator

        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name("WebViewReload"), object: nil, queue: .main) { [weak webView] _ in
            webView?.reload()
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let targetURL = stateModel.currentURL else { return }
        if uiView.url != targetURL {
            uiView.load(URLRequest(url: targetURL))
        }
    }

    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("WebViewReload"), object: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(goBack), name: NSNotification.Name("WebViewGoBack"), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(goForward), name: NSNotification.Name("WebViewGoForward"), object: nil)
        }

        @objc func goBack() {
            webView?.goBack()
        }

        @objc func goForward() {
            webView?.goForward()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView

            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward

            if let currentURL = webView.url, parent.stateModel.currentURL != currentURL {
                parent.stateModel.currentURL = currentURL
            }

            // 음소거 및 클릭 이벤트 재적용 JS
            let script = """
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

            setInterval(() => {
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
            }, 500);
            """
            webView.evaluateJavaScript(script)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if let url = webView.url {
                parent.stateModel.currentURL = url
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo", let urlString = message.body as? String, let url = URL(string: urlString) {
                DispatchQueue.main.async {
                    self.parent.playerURL = url
                    self.parent.showAVPlayer = true
                }
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

struct AVPlayerOverlayView: UIViewControllerRepresentable {
    let videoURL: URL
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: videoURL)
        controller.showsPlaybackControls = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: controller.player?.currentItem,
                                               queue: .main) { _ in
            onClose()
        }

        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player?.pause()
        NotificationCenter.default.removeObserver(uiViewController)
    }
}