import SwiftUI
import WebKit
import AVFoundation
import AVKit

struct CustomWebView: UIViewRepresentable {
    var stateModel: WebViewStateModel

    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()

        // ✅ JavaScript: video 클릭 시 native AVPlayer로 전달
        let scriptSource = """
        document.querySelectorAll('video').forEach(video => {
            if (!video.hasAttribute('nativeAVPlayerListener')) {
                video.addEventListener('click', () => {
                    window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
                });
                video.setAttribute('nativeAVPlayerListener', 'true');
            }
        });
        """
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        controller.addUserScript(userScript)
        controller.add(context.coordinator, name: "playVideo")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // ✅ pull to refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // ✅ 기본 URL 설정 (초기 페이지 보이도록 수정)
        let defaultURL = stateModel.currentURL ?? URL(string: "https://www.google.com")!
        stateModel.currentURL = defaultURL
        webView.load(URLRequest(url: defaultURL))

        // ✅ NotificationCenter 연결
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

    // ✅ Audio Session: mixWithOthers 설정
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // ✅ Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
            super.init()
        }

        // ✅ JavaScript 메시지 수신: video 클릭 시 호출
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo",
               let urlString = message.body as? String,
               let url = URL(string: urlString) {
                playWithAVPlayer(url)
            }
        }

        // ✅ AVPlayer 재생 + 자동 PiP + 음소거
        private func playWithAVPlayer(_ url: URL) {
            let player = AVPlayer(url: url)
            player.isMuted = true // 🔇 음소거 설정

            let controller = AVPlayerViewController()
            controller.player = player
            controller.allowsPictureInPicturePlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.entersFullScreenWhenPlaybackBegins = false // ✅ PiP 진입을 위해 전체화면 자동 진입 방지

            if let rootVC = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                rootVC.present(controller, animated: true) {
                    player.play()
                }
            }
        }

        // ✅ 새 탭 방지 (target="_blank") → 현재 웹뷰에서 열기
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // ✅ 새 탭 요청인 경우에만 현재 WebView에서 로드
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // ✅ 리디렉션 대응
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.stateModel.currentURL = webView.url
        }

        // ✅ 네비게이션 완료 시 상태 업데이트 + 영상 음소거 스크립트 삽입
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            // 모든 media 요소 음소거 유지
            let script = """
            [...document.querySelectorAll('video'), ...document.querySelectorAll('audio')].forEach(media => {
              media.muted = true;
              media.volume = 0;
              media.setAttribute('muted','true');
            });
            setInterval(() => {
              [...document.querySelectorAll('video'), ...document.querySelectorAll('audio')].forEach(media => {
                media.muted = true;
                media.volume = 0;
                media.setAttribute('muted','true');
              });
            }, 500);
            """
            webView.evaluateJavaScript(script)
        }

        // ✅ Pull to refresh 동작
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // ✅ NotificationCenter 동작
        @objc func goBack() {
            webView?.goBack()
        }

        @objc func goForward() {
            webView?.goForward()
        }

        @objc func reloadWebView() {
            webView?.reload()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}