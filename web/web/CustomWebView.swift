// CustomWebView.swift
import SwiftUI
import WebKit
import AVFoundation

/// ✅ SwiftUI에서 WKWebView를 감싸는 UIViewRepresentable 구조체
struct CustomWebView: UIViewRepresentable {
    // 🔗 외부 상태 모델을 감시 (탭별 웹뷰 상태 관리)
    @ObservedObject var stateModel: WebViewStateModel

    // 🎬 AVPlayer를 위한 비디오 URL
    @Binding var playerURL: URL?

    // 🎬 AVPlayer 전체화면 재생 여부
    @Binding var showAVPlayer: Bool

    // ✅ WebView 생성 및 초기화
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()  // 🎧 무음에서도 재생 가능한 오디오 세션 구성

        // 🔧 웹 구성 초기화
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 📜 자바스크립트 메시지 처리용 컨트롤러 구성
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript()) // ▶️ 비디오 자동 처리 JS 삽입
        controller.add(context.coordinator, name: "playVideo") // JS로부터 메시지 수신

        config.userContentController = controller

        // 🌐 웹뷰 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // 🔗 coordinator가 웹뷰 참조하게 함
        context.coordinator.webView = webView

        // 🔄 Pull to Refresh 구성
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // 🧠 세션 복원 or 초기 URL 로딩
        if let session = stateModel.pendingSession {
            restoreSession(session, webView: webView)
            stateModel.pendingSession = nil
        } else if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // ✅ 모델에 WKWebView 연결 및 복원 준비 실행
        stateModel.webView = webView
        stateModel.prepareRestoredHistoryIfNeeded()

        // 🔔 외부 명령 바인딩
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goBack), name: .init("WebViewGoBack"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goForward), name: .init("WebViewGoForward"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.reloadWebView), name: .init("WebViewReload"), object: nil)

        return webView
    }

    // ✅ WebView의 상태 업데이트
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = stateModel.currentURL else { return }

        // 📍 같은 URL이면 다시 로드 안 함
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
    }

    // ✅ 뷰가 사라질 때 리소스 정리
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
    }

    // ✅ Coordinator 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // ✅ 비디오 자동 처리용 JavaScript 생성
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

    // ✅ 오디오 세션 설정: 다른 앱과 혼합 재생 허용
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

    // ✅ 세션 복원 - 방문 기록 복원용 (legacy)
    private func restoreSession(_ session: WebViewSession, webView: WKWebView) {
        let urls = session.urls
        let currentIndex = session.currentIndex

        guard urls.indices.contains(currentIndex) else { return }

        loadURLsSequentially(urls, index: 0, webView: webView) {
            let stepsToGoBack = urls.count - 1 - currentIndex
            for _ in 0..<stepsToGoBack {
                webView.goBack()
            }
        }
    }

    // ✅ 방문 기록을 하나씩 로드하여 세션 구성
    private func loadURLsSequentially(_ urls: [URL], index: Int, webView: WKWebView, completion: @escaping () -> Void) {
        guard index < urls.count else {
            completion()
            return
        }

        webView.load(URLRequest(url: urls[index]))

        // 🚧 WKWebView는 로딩 완료 콜백이 없어서 delay로 대체
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            loadURLsSequentially(urls, index: index + 1, webView: webView, completion: completion)
        }
    }

    // ✅ Coordinator 정의: WebView 이벤트 관리
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
        }

        // 🔁 외부 알림 트리거
        @objc func goBack() { webView?.goBack() }
        @objc func goForward() { webView?.goForward() }
        @objc func reloadWebView() { webView?.reload() }

        // ✅ Pull to refresh 처리
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // ✅ 로딩 완료 처리
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            let title = (webView.title?.isEmpty == false)
                ? webView.title!
                : (webView.url?.host ?? "제목 없음")

            if let finalURL = webView.url {
                parent.stateModel.addToHistory(url: finalURL, title: title)
            }
        }

        // ✅ 새 창 요청을 현재 웹뷰로 대체
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // ✅ JS에서 온 메시지 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo",
               let urlString = message.body as? String,
               let videoURL = URL(string: urlString) {
                DispatchQueue.main.async {
                    self.parent.playerURL = videoURL
                    self.parent.showAVPlayer = true
                }
            }
        }

        // ⚠️ 에러 로그
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("❌ Provisional fail: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Navigation fail: \(error.localizedDescription)")
        }
    }
}
