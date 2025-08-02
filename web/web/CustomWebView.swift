import SwiftUI
import WebKit
import AVFoundation

// ✅ SwiftUI에서 WKWebView를 사용할 수 있도록 래핑하는 구조체
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel      // 🔄 WebView 상태 추적용
    @Binding var playerURL: URL?                           // 🎬 AVPlayer로 재생할 URL
    @Binding var showAVPlayer: Bool                        // 🎬 AVPlayer 표시 여부

    // ✅ WebView 생성
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing() // 🔇 무음 오디오 세션 유지

        // ✅ WebView 구성 설정
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // ✅ JavaScript 스크립트 추가 및 메시지 핸들러 등록
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())                // 🎥 자동 PIP + 영상 클릭
        controller.add(context.coordinator, name: "playVideo")     // 🎬 Swift로 메시지 전달

        config.userContentController = controller

        // ✅ WebView 인스턴스 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // 🔁 Pull-to-Refresh 적용
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // 🌐 초기 페이지 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // 🔁 알림(Notification)으로 WebView 동작 연결
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goBack), name: NSNotification.Name("WebViewGoBack"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goForward), name: NSNotification.Name("WebViewGoForward"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.reloadWebView), name: NSNotification.Name("WebViewReload"), object: nil)

        return webView
    }

    // ✅ URL이 바뀌었을 때 WebView 업데이트
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = stateModel.currentURL else { return }

        // 같은 페이지면 다시 로드하지 않음
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
    }

    // ✅ View가 사라질 때 정리
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
    }

    // ✅ Coordinator 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // ✅ JavaScript 삽입 (video 자동 감지 및 PIP 처리)
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

    // ✅ 오디오 세션 활성화
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    // ✅ 오디오 세션 비활성화
    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // ✅ Coordinator 클래스 정의 (델리게이트 + 메시지 핸들러)
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
        }

        // ✅ 알림 → WebView 동작
        @objc func goBack() { webView?.goBack() }
        @objc func goForward() { webView?.goForward() }
        @objc func reloadWebView() { webView?.reload() }

        // ✅ 당겨서 새로고침
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // ✅ 페이지 로딩 완료 후 처리
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            // ✅ [추가] 방문기록에 웹페이지 제목 저장 (한 줄 추가)
            let pageTitle = webView.title ?? "제목 없음"
            parent.stateModel.addToHistory(url: webView.url!, title: pageTitle)
        }

        // ✅ 새 창 열기 차단하고 동일 WebView에서 열기
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // ✅ JavaScript 메시지 수신 (예: 비디오 클릭 → AVPlayer 재생)
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

        // ❌ 초기 로딩 실패
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("❌ Provisional fail: \(error.localizedDescription)")
        }

        // ❌ 일반 로딩 실패
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Navigation fail: \(error.localizedDescription)")
        }
    }
}