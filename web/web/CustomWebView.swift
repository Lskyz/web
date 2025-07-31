import SwiftUI
import WebKit
import AVFoundation
import AVKit

// SwiftUI에서 WKWebView를 사용하기 위한 UIViewRepresentable 구조체
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel

    // AVPlayer 오버레이 재생 관련 상태 바인딩
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    // WKWebView 생성 및 초기 설정
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true                  // 인라인 미디어 재생 허용
        config.allowsPictureInPictureMediaPlayback = true        // PiP 허용
        config.mediaTypesRequiringUserActionForPlayback = []     // 자동재생 제한 해제

        // JS 메시지 핸들러 "playVideo" 등록 - 네이티브 호출용
        config.userContentController.add(context.coordinator, name: "playVideo")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true       // 스와이프로 뒤로/앞으로 가능

        // 오디오 세션을 다른 앱과 혼합하여 재생 가능하도록 설정
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        webView.navigationDelegate = context.coordinator

        // 초기 URL 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    // 상태 변경 시 호출 (URL 변경 시 재로드)
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url = stateModel.currentURL, uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }

    // 뷰 해제 시 로딩 중지 및 오디오 세션 비활성화
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Coordinator 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // WKNavigationDelegate 및 WKScriptMessageHandler 구현
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) {
            self.parent = parent
            super.init()

            // 뒤로가기, 앞으로가기 알림 수신 등록
            NotificationCenter.default.addObserver(self, selector: #selector(goBack), name: NSNotification.Name("WebViewGoBack"), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(goForward), name: NSNotification.Name("WebViewGoForward"), object: nil)
        }

        @objc func goBack() {
            webView?.goBack()
        }

        @objc func goForward() {
            webView?.goForward()
        }

        // 웹뷰 로딩 완료 시 처리
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView

            // 네비게이션 상태 갱신
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.can