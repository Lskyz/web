import SwiftUI
import WebKit
import AVFoundation

// ✅ SwiftUI에서 WKWebView를 사용할 수 있도록 UIViewRepresentable로 래핑
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    
    // ✅ WKWebView 생성 및 설정
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing() // 오디오 믹싱 설정 (백그라운드 재생 대비)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true // 인라인 재생 허용
        config.allowsPictureInPictureMediaPlayback = true // PiP 모드 허용
        config.mediaTypesRequiringUserActionForPlayback = [] // 자동재생 허용

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true // 스와이프 네비게이션 허용

        // ✅ 당겨서 새로고침 구성
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // ✅ navigation delegate 연결
        webView.navigationDelegate = context.coordinator

        // ✅ 초기 URL 로딩
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }

        // ✅ Notification을 통해 외부에서 웹뷰 동작 제어 (뒤로가기, 앞으로가기, 새로고침)
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
    
    // ✅ URL이 바뀌었을 경우 새 요청 로드
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url = stateModel.currentURL, uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
    
    // ✅ 웹뷰 해제 시 정리
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
    }
    
    // ✅ Coordinator 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // MARK: - 오디오 세션 설정 (다른 앱 오디오와 믹싱 허용)
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }

    // ✅ 오디오 세션 비활성화
    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
    
    // ✅ 웹뷰 이벤트를 처리할 Coordinator 클래스
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
            super.init()
        }

        // ✅ 외부 알림으로부터 웹뷰를 뒤로 이동
        @objc func goBack() {
            webView?.goBack()
        }

        // ✅ 외부 알림으로부터 웹뷰를 앞으로 이동
        @objc func goForward() {
            webView?.goForward()
        }

        // ✅ 외부 알림으로부터 웹뷰를 새로고침
        @objc func reloadWebView() {
            webView?.reload()
        }

        // ✅ 당겨서 새로고침 동작
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // ✅ 페이지 로딩 완료 시 호출됨
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            // ✅ 자동 음소거 스크립트: video/audio 요소들을 반복적으로 mute 처리
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

        // ✅ 해제 시 옵저버 제거
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
