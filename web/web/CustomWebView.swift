import SwiftUI
import WebKit
import AVFoundation

struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel

    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        // ✅ 웹뷰 구성 설정: 자동 재생, PIP, 인라인 허용
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator // ✅ 새 창 요청 대응용

        // ✅ Pull to refresh 설정
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // ✅ 최초 URL 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // ✅ 알림 수신자 등록 (뒤로/앞으로/새로고침)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.goBack),
                                               name: .init("WebViewGoBack"),
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.goForward),
                                               name: .init("WebViewGoForward"),
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.reloadWebView),
                                               name: .init("WebViewReload"),
                                               object: nil)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // ✅ 주소창과 다른 경우에만 로드
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

    // MARK: - 오디오 세션 (백그라운드 재생 허용)
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Coordinator (웹뷰 이벤트 처리)
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: CustomWebView
        weak var webView: WKWebView?

        /// ✅ 리디렉션 설정: 특정 도메인 또는 * 모든 도메인
        let domainRedirectMap: [String: String] = [
            "*" : "example.com"
            // 예: "m.daum.net": "daum.net"
        ]

        init(_ parent: CustomWebView) {
            self.parent = parent
        }

        // ✅ 새 창 요청 (target="_blank") 방지
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // ✅ 도메인 리디렉션 처리 및 주소 동기화
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let host = url.host {
                let redirectHost = domainRedirectMap[host] ?? domainRedirectMap["*"]
                if let newHost = redirectHost, newHost != host {
                    var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    comp?.host = newHost
                    if let newURL = comp?.url {
                        parent.stateModel.currentURL = newURL // ✅ 주소창 동기화
                        webView.load(URLRequest(url: newURL))
                        decisionHandler(.cancel)
                        return
                    }
                }
            }
            decisionHandler(.allow)
        }

        // ✅ 페이지 로딩 완료 후 상태 업데이트 + 미디어 음소거
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            // ✅ 자동 음소거
            let muteScript = """
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
            webView.evaluateJavaScript(muteScript)
        }

        // MARK: - 컨트롤 버튼 처리
        @objc func goBack() { webView?.goBack() }
        @objc func goForward() { webView?.goForward() }
        @objc func reloadWebView() { webView?.reload() }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}