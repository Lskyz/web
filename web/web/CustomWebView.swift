import SwiftUI
import WebKit
import AVFoundation

// ✅ SwiftUI에서 WKWebView를 사용할 수 있도록 UIViewRepresentable로 래핑
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // ✅ 새로고침
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator // ✅ 새창 처리용

        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // ✅ 알림 기반 이동/새로고침
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

    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
            super.init()
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

        // ✅ 리디렉션된 최종 주소를 정확히 가져오기 (JS 기반)
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward

            // ✅ JS로 현재 최종 URL을 가져와 주소창에 반영
            webView.evaluateJavaScript("window.location.href") { result, error in
                if let finalURLString = result as? String, let finalURL = URL(string: finalURLString) {
                    self.parent.stateModel.currentURL = finalURL
                } else {
                    self.parent.stateModel.currentURL = webView.url
                }
            }

            // ✅ 자동 음소거
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

        // ✅ 중간 리디렉션 감지도 가능
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.stateModel.currentURL = webView.url
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// ✅ 새탭 열기 대응 (target="_blank", window.open)
extension CustomWebView.Coordinator: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
