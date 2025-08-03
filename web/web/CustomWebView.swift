import SwiftUI
import WebKit
import AVFoundation

// ✅ SwiftUI에서 WKWebView를 감싸는 UIViewRepresentable 구조체
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel          // 🌐 WebView 상태 저장 모델
    @Binding var playerURL: URL?                               // 🎬 AVPlayer에 사용할 비디오 URL
    @Binding var showAVPlayer: Bool                            // 🎬 AVPlayer 전체화면 여부

    // ✅ WebView 생성 및 초기화
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()                       // 🔊 무음 상태에서도 재생 가능하도록 오디오 세션 구성

        // 🔧 WebView 구성 설정
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true                // ▶️ 인라인 재생 허용
        config.allowsPictureInPictureMediaPlayback = true      // 🖼 PIP 허용
        config.mediaTypesRequiringUserActionForPlayback = []   // 사용자 동작 없이 자동 재생 허용

        // 🎯 JavaScript 메시지 및 스크립트 핸들링 설정
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())            // 🎥 비디오 관련 JS 삽입
        controller.add(context.coordinator, name: "playVideo") // 🎬 영상 재생 메시지 핸들러 등록
        config.userContentController = controller

        // 🌐 WebView 인스턴스 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true     // ←→ 제스처 허용
        webView.navigationDelegate = context.coordinator       // 📡 탐색 이벤트 위임
        webView.uiDelegate = context.coordinator               // 🪟 팝업 이벤트 위임

        // 🔗 Coordinator에 WebView 연결
        context.coordinator.webView = webView

        // 🔄 Pull to refresh 설정
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // 🌐 초기 로딩 - 세션 복원이 있다면 그것부터 적용
        if let session = stateModel.pendingSession {
            restoreSession(session, webView: webView)          // ✅ 세션 복원 시도
            stateModel.pendingSession = nil                    // 🔁 복원 후 초기화
        } else if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))                 // ✅ 단순 URL 로딩
        }

        // 🔔 알림 기반 웹 동작 연결
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goBack), name: .init("WebViewGoBack"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goForward), name: .init("WebViewGoForward"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.reloadWebView), name: .init("WebViewReload"), object: nil)

        return webView
    }

    // ✅ WebView 업데이트 처리
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = stateModel.currentURL else { return }

        // 🔄 동일한 URL이면 재로딩 안 함
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
    }

    // ✅ 뷰 해제 시 리소스 정리
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()                               // 🎧 오디오 세션 비활성화
        NotificationCenter.default.removeObserver(coordinator) // 🔕 알림 제거
    }

    // ✅ Coordinator 객체 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // ✅ JavaScript 삽입용 스크립트 생성 (비디오 처리)
    private func makeVideoScript() -> WKUserScript {
        let scriptSource = """
        // JavaScript for auto-PIP and tap-detection on <video> elements
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

    // ✅ 오디오 세션 활성화 (다른 앱과 혼합 재생 허용)
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

    // ✅ 🔄 세션 복원 기능 - 저장된 세션의 URL 리스트를 복원
    private func restoreSession(_ session: WebViewSession, webView: WKWebView) {
        guard !session.urls.isEmpty else { return }
        loadURLsSequentially(session.urls, currentIndex: session.currentIndex, webView: webView)
    }

    // ✅ 🔁 URL들을 순서대로 로딩 (앞뒤 스택 시뮬레이션 가능)
    private func loadURLsSequentially(_ urls: [URL], currentIndex: Int, webView: WKWebView) {
        guard urls.indices.contains(currentIndex) else { return }
        let request = URLRequest(url: urls[currentIndex])
        webView.load(request)
    }

    // ✅ WebView 이벤트를 처리하는 Coordinator 클래스
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
        }

        // ✅ 알림 처리
        @objc func goBack() { webView?.goBack() }
        @objc func goForward() { webView?.goForward() }
        @objc func reloadWebView() { webView?.reload() }

        // ✅ Pull to refresh 처리
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // ✅ 페이지 로딩 완료 시 상태 업데이트
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            let title = (webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? webView.title!
                : (webView.url?.host ?? "제목 없음")

            if let finalURL = webView.url {
                parent.stateModel.addToHistory(url: finalURL, title: title)
            }
        }

        // ✅ 새 창 → 동일 WebView로 처리
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // ✅ JavaScript에서 playVideo 메시지 수신 처리
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

        // ❌ 로딩 중 실패
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Navigation fail: \(error.localizedDescription)")
        }
    }
}