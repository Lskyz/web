import SwiftUI
import WebKit
import AVFoundation
import AVKit

// SwiftUI 내 WKWebView 래핑
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel

    @Binding var playerURL: URL?       // AVPlayer 재생용 URL
    @Binding var showAVPlayer: Bool    // AVPlayer 오버레이 표시 여부

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true                 // 인라인 미디어 재생 허용
        config.allowsPictureInPictureMediaPlayback = true       // PiP 허용
        config.mediaTypesRequiringUserActionForPlayback = []    // 자동재생 제한 해제

        // JS 메시지 핸들러 등록 (웹→네이티브 메시지용)
        config.userContentController.add(context.coordinator, name: "playVideo")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true      // 스와이프 탐색 허용

        // 오디오 세션: 다른 앱 오디오와 혼합 가능하도록 설정
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        webView.navigationDelegate = context.coordinator

        // 초기 URL 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // NotificationCenter로 리로드 명령 수신 대기
        NotificationCenter.default.addObserver(forName: NSNotification.Name("WebViewReload"), object: nil, queue: .main) { [weak webView] _ in
            webView?.reload()
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url = stateModel.currentURL, uiView.url != url {
            uiView.load(URLRequest(url: url))
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

            // 상태 갱신
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            // JS: video 음소거 및 클릭 시 네이티브 AVPlayer 호출 이벤트 등록
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

        // 웹에서 playVideo 메시지 수신 처리
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

// AVPlayer 오버레이 뷰 (CustomWebView.swift에 같이 포함)
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