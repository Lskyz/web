import SwiftUI
import WebKit
import AVFoundation

// SwiftUI UIViewRepresentable 로 감싼 WKWebView
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    
    // 1) UIView 생성 시 호출
    func makeUIView(context: Context) -> WKWebView {
        // 1-a) 오디오 믹싱 세션 활성화
        configureAudioSessionForMixing()
        
        // 1-b) 웹뷰 설정: 인라인 재생, PIP 허용, 자동 재생 금지 해제
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        // 1-c) WKWebView 인스턴스 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        
        // 1-d) Pull to Refresh 연결
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refreshControl
        
        // 1-e) 델리게이트 지정 (Navigation + UI)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        // 1-f) 초기 URL 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }
        
        // 1-g) NotificationCenter 로 뒤로/앞으로/새로고침 제어 메시지 받기
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.goBack),
            name: .init("WebViewGoBack"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.goForward),
            name: .init("WebViewGoForward"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.reloadWebView),
            name: .init("WebViewReload"),
            object: nil
        )
        
        return webView
    }
    
    // 2) State 변경 시 호출
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url = stateModel.currentURL, uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
    
    // 3) UIView 파괴 시 호출
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
    }
    
    // Coordinator 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // MARK: – Audio Session Helpers
    
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }
    
    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
    
    // MARK: – Coordinator: WKNavigationDelegate & WKUIDelegate
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: CustomWebView
        weak var webView: WKWebView?
        
        /// domainRedirectMap:
        /// - 키: 접속한 호스트(host), "*" 은 와일드카드(모든 도메인)
        /// - 값: 강제 리디렉트할 호스트(host)
        let domainRedirectMap: [String: String] = [
            "*"             : "example.com",  // 모든 도메인 → example.com
            // "m.example.com": "example.com", // 특정 도메인만 매핑하려면 주석 해제
        ]
        
        init(_ parent: CustomWebView) {
            self.parent = parent
            super.init()
        }
        
        // MARK: WKNavigationDelegate
        
        /// 네비게이션 액션 전 리디렉션 정책 결정
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               let host = url.host {
                // 1) 호스트에 매핑된 타겟 호스트가 있는지 찾기
                let targetHost = domainRedirectMap[host]
                    ?? domainRedirectMap["*"]  // 없으면 와일드카드 검사
                if let redirectHost = targetHost {
                    // 2) URLComponents 로 path/query 그대로 유지하며 host 교체
                    if var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        comp.host = redirectHost
                        if let newURL = comp.url {
                            webView.load(URLRequest(url: newURL))
                            decisionHandler(.cancel)  // 원 요청 취소
                            return
                        }
                    }
                }
            }
            // 3) 매핑 대상이 아니면 정상 진행
            decisionHandler(.allow)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            // 뒤로/앞으로 가능 여부, 현재 URL 상태 업데이트
            parent.stateModel.canGoBack    = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL   = webView.url
            
            // 모든 미디어 요소(비디오/오디오) 음소거 스크립트 삽입
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
        
        // MARK: WKUIDelegate
        
        /// target="_blank" 등의 새창 요청을 현재 창에서 로드하도록 처리
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // targetFrame 이 nil 이면 새탭 요청 → 메인 웹뷰에 load
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
        
        // MARK: – Actions
        
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
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}