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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // ✅ 새 창(target="_blank")을 현재 탭에서 열도록 설정
        webView.uiDelegate = context.coordinator

        // ✅ Pull to refresh 연결
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        webView.navigationDelegate = context.coordinator

        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // ✅ 알림 센터 연결 (탐색 버튼 동작용)
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

            // ✅ 모든 video (iframe 포함) 자동 음소거 + PIP 실행
            let script = """
            function processVideos(doc) {
                [...doc.querySelectorAll('video')].forEach(video => {
                    video.muted = true;
                    video.volume = 0;
                    video.setAttribute('muted','true');
                    if (document.pictureInPictureEnabled && !video.disablePictureInPicture && !document.pictureInPictureElement) {
                        try {
                            video.requestPictureInPicture().catch(() => {});
                        } catch (e) {}
                    }
                });
            }

            // 초기 처리
            processVideos(document);

            // iframe 포함 반복 처리
            setInterval(() => {
                processVideos(document);
                [...document.querySelectorAll('iframe')].forEach(iframe => {
                    try {
                        const doc = iframe.contentDocument || iframe.contentWindow?.document;
                        if (doc) {
                            processVideos(doc);
                        }
                    } catch (e) {
                        // cross-origin iframe은 무시
                    }
                });
            }, 1000);
            """
            webView.evaluateJavaScript(script)
        }

        // ✅ 새창 방지: target="_blank" → 현재 탭에서 열기
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}