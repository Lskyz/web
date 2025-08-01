import SwiftUI
import WebKit
import AVFoundation

struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel

    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // ✅ userContentController 생성: 메시지 핸들러와 JS 삽입용
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "redirectHandler") // JS → native 메시지 수신

        // ✅ JavaScript: window.location.href 리디렉션 감지 스크립트
        let redirectionScript = """
        (function() {
            const pushURL = (url) => {
                if (!url) return;
                window.webkit.messageHandlers.redirectHandler.postMessage(url);
            };
            // 진입 시 전송
            pushURL(window.location.href);
            // SPA 혹은 location 변경 감지
            const observer = new MutationObserver(() => {
                pushURL(window.location.href);
            });
            observer.observe(document, {childList: true, subtree: true});
        })();
        """
        let userScript = WKUserScript(source: redirectionScript,
                                      injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: false)
        controller.addUserScript(userScript)

        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // ✅ pull to refresh 연결
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // ✅ NotificationCenter 등록
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

    // MARK: Audio Session Helpers

    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            // ✅ 모든 media 요소 음소거
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

        // ✅ target="_blank" 새 창 → 현재 창에서 열기
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
}

// ✅ JavaScript → Swift 메시지 처리 확장
extension CustomWebView.Coordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // ✅ JS에서 전달한 리디렉션 주소 수신
        if message.name == "redirectHandler",
           let urlString = message.body as? String,
           let url = URL(string: urlString) {

            // ✅ 중복 방지 후 수동 로드
            if webView?.url?.absoluteString != url.absoluteString {
                parent.stateModel.currentURL = url
                webView?.load(URLRequest(url: url))
            }
        }
    }
}