import SwiftUI
import WebKit
import AVFoundation

// ✅ SwiftUI에서 WKWebView를 사용할 수 있도록 래핑하는 구조체
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel      // 🔄 WebView 상태 추적용 (URL, 방문 기록 등)
    @Binding var playerURL: URL?                           // 🎬 AVPlayer로 재생할 영상 URL (스크립트로 전달됨)
    @Binding var showAVPlayer: Bool                        // 🎬 AVPlayer 표시 여부

    // ✅ WebView 인스턴스 생성
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing() // 🔇 무음 상태에서도 비디오 재생 허용

        // 🌐 WebView 구성 초기화
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 🧠 JavaScript 인터페이스 구성
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())                // 🎥 비디오 태그 자동처리 스크립트
        controller.add(context.coordinator, name: "playVideo")     // 🎬 Swift로 메시지 전달 받기 (영상 클릭 시)

        config.userContentController = controller

        // 🧱 WebView 인스턴스 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true         // ← → 제스처 허용
        webView.navigationDelegate = context.coordinator           // Web 탐색 이벤트 처리
        webView.uiDelegate = context.coordinator                   // 팝업 등 UI 핸들링

        // 🔁 Pull-to-Refresh 구성
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // 🌐 최초 로딩
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // 🔁 외부 알림으로 WebView 동작 연결 (뒤로가기/앞으로가기/새로고침)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goBack), name: NSNotification.Name("WebViewGoBack"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goForward), name: NSNotification.Name("WebViewGoForward"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.reloadWebView), name: NSNotification.Name("WebViewReload"), object: nil)

        return webView
    }

    // ✅ SwiftUI에서 상태 변경되면 WebView에 반영
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = stateModel.currentURL else { return }

        // 👉 이미 같은 URL이면 다시 로드하지 않음
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
    }

    // ✅ 뷰가 해제될 때 정리
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
    }

    // ✅ Coordinator 인스턴스 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // ✅ JavaScript 삽입 (비디오 자동 재생 및 PIP 진입 + 클릭 이벤트 연결)
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

    // ✅ 오디오 세션 활성화 (다른 앱과 혼합 허용)
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

    // ✅ Coordinator 클래스 정의 (델리게이트 및 메시지 핸들링)
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
        }

        // ✅ 알림 처리 메서드들
        @objc func goBack() { webView?.goBack() }
        @objc func goForward() { webView?.goForward() }
        @objc func reloadWebView() { webView?.reload() }

        // ✅ 당겨서 새로고침 처리
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // ✅ 페이지 로딩 완료 시 호출
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            // ✅ [중요] 현재 URL + 타이틀을 기록 저장 (탭별 기록용)
            let pageTitle = webView.title ?? "제목 없음"
            parent.stateModel.addToHistory(url: webView.url!, title: pageTitle)
        }

        // ✅ 새 창 열기 → 같은 WebView에서 처리 (팝업 방지)
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // ✅ JavaScript 메시지 수신 처리 (영상 클릭 감지)
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

        // ❌ 페이지 초기 로딩 실패
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("❌ Provisional fail: \(error.localizedDescription)")
        }

        // ❌ 일반 로딩 실패
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Navigation fail: \(error.localizedDescription)")
        }
    }
}