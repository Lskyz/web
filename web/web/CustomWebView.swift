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

    // ✅ WebView 업데이트 처리 (URL 변경 시 동기화)
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = stateModel.currentURL else { return }

        // 🔄 동일한 URL이면 재로딩 안 함
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
    }

    // ✅ 뷰 해제 시 리소스 정리
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()                                    // 🛑 로딩 중지
        deactivateAudioSession()                                // 🎧 오디오 세션 비활성화
        NotificationCenter.default.removeObserver(coordinator)  // 🔕 알림 제거
    }

    // ✅ Coordinator 객체 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // ✅ JavaScript 삽입용 스크립트 생성 (비디오 처리 및 PIP 자동화)
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

    // ✅ 🔄 세션 복원 기능 - 저장된 세션의 URL 리스트를 순서대로 복원
    private func restoreSession(_ session: WebViewSession, webView: WKWebView) {
        let urls = session.urls
        let currentIndex = session.currentIndex

        guard urls.indices.contains(currentIndex) else { return }

        // 🔁 순차적으로 로딩 후, 현재 인덱스로 되돌아가기
        loadURLsSequentially(urls, index: 0, webView: webView) {
            let stepsToGoBack = urls.count - 1 - currentIndex
            for _ in 0..<stepsToGoBack {
                webView.goBack()
            }
        }
    }

    // ✅ URL들을 하나씩 로딩해 backForwardList 구성
    private func loadURLsSequentially(_ urls: [URL], index: Int, webView: WKWebView, completion: @escaping () -> Void) {
        guard index < urls.count else {
            completion()
            return
        }

        webView.load(URLRequest(url: urls[index]))

        // 🔁 다음 URL 로딩까지 지연 (WKWebView는 완전한 로딩 확인 콜백이 없음)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            loadURLsSequentially(urls, index: index + 1, webView: webView, completion: completion)
        }
    }

    // ✅ WebView 이벤트 처리 Coordinator
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
        }

        // ✅ 외부 알림 처리 (뒤로, 앞으로, 새로고침)
        @objc func goBack() { webView?.goBack() }
        @objc func goForward() { webView?.goForward() }
        @objc func reloadWebView() { webView?.reload() }

        // ✅ 새로고침 처리 (UIRefreshControl)
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // ✅ 로딩 완료 시 URL 및 상태 동기화
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            // 📋 제목 확보 및 전역 기록에 저장
            let title = (webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? webView.title!
                : (webView.url?.host ?? "제목 없음")

            if let finalURL = webView.url {
                parent.stateModel.addToHistory(url: finalURL, title: title)
            }
        }

        // ✅ 새 창 열기 방지 → 현재 WebView에 로드
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // ✅ JavaScript 메시지 처리 (비디오 클릭 시)
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

        // ❌ 로딩 실패 로그 출력
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("❌ Provisional fail: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Navigation fail: \(error.localizedDescription)")
        }
    }
}