import SwiftUI
import WebKit
import AVFoundation

// MARK: - CustomWebView
// WKWebView를 SwiftUI에서 사용하기 위한 UIViewRepresentable 구현.
//
// ⚠️ 핵심 포인트
// 1) (호출부 요구) CustomWebView 사용하는 쪽에서 .id(해당 탭의 UUID)를 꼭 부여하세요.
//    → 각 탭이 서로 다른 WKWebView 인스턴스를 갖도록 강제하여, 재사용 꼬임 방지.
// 2) (이 파일에서 처리) updateUIView에서 delegate/uiDelegate/stateModel.webView 바인딩을
//    매번 검증/재설정하여, 혹시라도 재사용되었을 때 연결이 엉키지 않도록 방어.
// 3) 세션 복원 중(stateModel.isRestoringSession == true)엔 불필요한 재로드를 막아
//    back/forward 리스트 구축이 끝나기 전 상태 오염을 방지.

struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    // MARK: makeUIView
    // 최초 한 번 WKWebView를 생성/구성하고 델리게이트, 스크립트, 옵저버 등을 붙인다.
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        // 웹뷰 설정 구성
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 사용자 스크립트/메시지 핸들러
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())
        controller.add(context.coordinator, name: "playVideo")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // 최초 delegate 연결
        webView.navigationDelegate = stateModel              // ✅ 상태 모델이 네비게이션 델리게이트
        webView.uiDelegate = context.coordinator             // ✅ UI 델리게이트는 코디네이터
        context.coordinator.webView = webView
        stateModel.webView = webView

        // Pull to Refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refreshControl

        // ◾️ 세션 복원 또는 초기 로드
        if let session = stateModel.pendingSession {
            TabPersistenceManager.debugMessages.append("세션 복원 시도: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
            restoreSession(session, webView: webView)
            stateModel.pendingSession = nil
        } else if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("초기 URL 로드: \(url)")
        } else {
            // 탭 복원 경로에서 히스토리 배열이 있다면 여기서 순차 복원
            stateModel.prepareRestoredHistoryIfNeeded()
        }

        // 전역 네비게이션 액션(Notification 기반) 수신
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

    // MARK: updateUIView
    // SwiftUI가 뷰를 재사용할 수 있으므로, 델리게이트/바인딩을 매 프레임 점검하여 오염 방지.
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 🛠 [수정 위치 #1] 재사용 방지용 재바인딩(필수)
        if uiView.navigationDelegate !== stateModel {
            uiView.navigationDelegate = stateModel
            TabPersistenceManager.debugMessages.append("재바인딩: navigationDelegate -> stateModel(\(stateModel.tabID?.uuidString ?? "no-id"))")
        }
        if uiView.uiDelegate !== context.coordinator {
            uiView.uiDelegate = context.coordinator
            TabPersistenceManager.debugMessages.append("재바인딩: uiDelegate -> coordinator")
        }
        if stateModel.webView !== uiView {
            stateModel.webView = uiView
            TabPersistenceManager.debugMessages.append("재바인딩: stateModel.webView <- uiView (탭 \(stateModel.tabID?.uuidString ?? "no-id"))")
        }
        if context.coordinator.webView !== uiView {
            context.coordinator.webView = uiView
        }

        // 🛠 [수정 위치 #2] 세션 복원 중엔 불필요한 재로드 금지
        // (currentURL 변화는 복원 로직 내부에서 순차적으로 처리됨)
        if stateModel.isRestoringSession {
            return
        }

        // URL 변경 시에만 로드 (중복 네비게이션 방지)
        guard let url = stateModel.currentURL else { return }
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("URL 업데이트 로드: \(url)")
        }
    }

    // MARK: dismantleUIView
    // 뷰가 사라질 때 정리(오디오 세션 비활성, 옵저버 제거).
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
        TabPersistenceManager.debugMessages.append("WebView 소멸: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - 사용자 스크립트 (비디오 클릭 → AVPlayer로 재생 / PiP 활성 시도)
    private func makeVideoScript() -> WKUserScript {
        let scriptSource = """
        function processVideos(doc) {
            [...doc.querySelectorAll('video')].forEach(video => {
                // iOS 사파리 자동재생 제약 회피를 위해 기본 mute
                video.muted = true;
                video.volume = 0;
                video.setAttribute('muted','true');

                // AVPlayer로 넘기는 클릭 핸들러는 1회만 부착
                if (!video.hasAttribute('nativeAVPlayerListener')) {
                    video.addEventListener('click', () => {
                        window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
                    });
                    video.setAttribute('nativeAVPlayerListener', 'true');
                }

                // 가능하면 PiP 자동 진입 시도(실패해도 무시)
                if (document.pictureInPictureEnabled &&
                    !video.disablePictureInPicture &&
                    !document.pictureInPictureElement) {
                    try { video.requestPictureInPicture().catch(() => {}); } catch (e) {}
                }
            });
        }

        // 최초/주기적으로 DOM 스캔(iframe 내부도 시도)
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

    // MARK: - 오디오 세션 (다른 앱과 믹싱 허용)
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        TabPersistenceManager.debugMessages.append("오디오 세션 활성화")
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        TabPersistenceManager.debugMessages.append("오디오 세션 비활성화")
    }

    // MARK: - 세션 복원(순차 로드 → 대상 인덱스로 이동)
    // WebViewStateModel.saveSession()으로 저장했던 urls/backIndex 기준으로
    // 실제 네비게이션 스택을 복원한다.
    private func restoreSession(_ session: WebViewSession, webView: WKWebView) {
        let urls = session.urls
        let currentIndex = max(0, min(session.currentIndex, urls.count - 1))
        TabPersistenceManager.debugMessages.append("세션 복원 시도: \(urls.count) URLs, 인덱스 \(currentIndex)")

        guard urls.indices.contains(currentIndex) else {
            TabPersistenceManager.debugMessages.append("세션 복원 실패: 인덱스 범위 초과")
            return
        }

        loadURLsSequentially(urls, index: 0, webView: webView) {
            let backList = webView.backForwardList.backList
            if backList.indices.contains(currentIndex) {
                webView.go(to: backList[currentIndex])
                TabPersistenceManager.debugMessages.append("세션 복원 완료: \(webView.url?.absoluteString ?? "없음")")
            } else {
                TabPersistenceManager.debugMessages.append("세션 복원 실패: backList 인덱스 범위 초과")
            }
        }
    }

    // 순차 로드 유틸리티: 한 URL이 로드 완료될 때 다음 URL을 로드
    private func loadURLsSequentially(_ urls: [URL], index: Int, webView: WKWebView, completion: @escaping () -> Void) {
        guard index < urls.count else {
            completion()
            TabPersistenceManager.debugMessages.append("URL 순차 로드 완료")
            return
        }
        webView.load(URLRequest(url: urls[index]))

        // WebViewStateModel(WKNavigationDelegate)에서 didFinish → onLoadCompletion 호출됨
        (webView.navigationDelegate as? WebViewStateModel)?.onLoadCompletion = {
            TabPersistenceManager.debugMessages.append("URL 로드 완료: \(urls[index])")
            self.loadURLsSequentially(urls, index: index + 1, webView: webView, completion: completion)
        }
    }

    // MARK: - Coordinator (WKUIDelegate & Script Message Handler)
    class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) { self.parent = parent }

        // 전역 버튼 액션(Notification) 처리
        @objc func goBack() {
            webView?.goBack()
            TabPersistenceManager.debugMessages.append("뒤로가기 실행")
        }
        @objc func goForward() {
            webView?.goForward()
            TabPersistenceManager.debugMessages.append("앞으로가기 실행")
        }
        @objc func reloadWebView() {
            webView?.reload()
            TabPersistenceManager.debugMessages.append("새로고침 실행")
        }

        // Pull-to-Refresh
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
            TabPersistenceManager.debugMessages.append("Pull to Refresh 실행")
        }

        // window.open 등 새 창 요청을 가로채 현재 웹뷰로 열기
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                TabPersistenceManager.debugMessages.append("새 창 요청을 현재 웹뷰로 로드: \(navigationAction.request.url?.absoluteString ?? "없음")")
            }
            return nil
        }

        // JS → 네이티브: 비디오 클릭 시 AVPlayer로 재생
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo",
               let urlString = message.body as? String,
               let videoURL = URL(string: urlString) {
                DispatchQueue.main.async {
                    self.parent.playerURL = videoURL
                    self.parent.showAVPlayer = true
                    TabPersistenceManager.debugMessages.append("비디오 재생 요청: \(urlString)")
                }
            }
        }
    }
}