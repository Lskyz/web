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
        
        // Pull to refresh 연결
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator // 새 탭 열기를 위해 uiDelegate 추가
        
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }
        
        // NotificationCenter 등록
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
        
        context.coordinator.currentWebView = webView
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
        weak var currentWebView: WKWebView?
        var webViews: [WKWebView] = [] // 여러 WKWebView 관리
        
        // 도메인 리디렉션 매핑
        let domainRedirects: [String: String] = [
            "example.com": "new-example.com",
            "old-site.com": "new-site.com"
        ]
        
        init(_ parent: CustomWebView) {
            self.parent = parent
            super.init()
        }
        
        @objc func goBack() {
            currentWebView?.goBack()
        }
        
        @objc func goForward() {
            currentWebView?.goForward()
        }
        
        @objc func reloadWebView() {
            currentWebView?.reload()
        }
        
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            currentWebView?.reload()
            sender.endRefreshing()
        }
        
        // MARK: WKNavigationDelegate
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.currentWebView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url
            
            // 모든 media 요소 음소거
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
        
        // 링크 클릭 시 동작 처리
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            
            // 도메인 리디렉션 처리
            if let redirectedURL = redirectURLIfNeeded(url) {
                webView.load(URLRequest(url: redirectedURL))
                decisionHandler(.cancel)
                return
            }
            
            // 새 탭 요청은 createWebViewWith에서 처리하므로 현재 창에서 기본적으로 로드
            decisionHandler(.allow)
        }
        
        // MARK: WKUIDelegate
        
        // 새 탭 요청 처리 (target="_blank" 등)
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            
            // 새 WKWebView 생성
            let newWebView = WKWebView(frame: .zero, configuration: configuration)
            newWebView.navigationDelegate = self
            newWebView.uiDelegate = self
            newWebView.allowsBackForwardNavigationGestures = true
            
            // 새 WKWebView를 배열에 추가
            webViews.append(newWebView)
            
            // 새로운 WebViewStateModel 생성
            let newStateModel = WebViewStateModel()
            newStateModel.currentURL = url
            newStateModel.canGoBack = false
            newStateModel.canGoForward = false
            
            // 새로운 CustomWebView를 SwiftUI 뷰로 표시
            let newWebViewRepresentable = CustomWebView(stateModel: newStateModel)
            
            // 현재 WebView를 새 WebView로 교체
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                let hostingController = UIHostingController(rootView: newWebViewRepresentable)
                window.rootViewController = hostingController
                window.makeKeyAndVisible()
            }
            
            // 새 WebView에 URL 로드
            newWebView.load(URLRequest(url: url))
            
            return newWebView
        }
        
        // MARK: Helper Methods
        
        private func redirectURLIfNeeded(_ url: URL) -> URL? {
            guard let host = url.host else { return nil }
            
            // 도메인 리디렉션 매핑 확인
            for (originalDomain, newDomain) in domainRedirects {
                if host.contains(originalDomain) {
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    components?.host = newDomain
                    return components?.url
                }
            }
            
            return nil
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// WebViewStateModel 정의 (기존 코드에서 사용 중인 것으로 가정)
class WebViewStateModel: ObservableObject {
    @Published var currentURL: URL?
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
}