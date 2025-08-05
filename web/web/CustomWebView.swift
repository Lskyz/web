import SwiftUI
import WebKit
import AVFoundation

// MARK: - CustomWebView
// 1) ContentView 쪽에서 .id(tabID) 부여(탭별 WKWebView 인스턴스 분리 강제).
// 2) updateUIView에서 navigationDelegate/uiDelegate/stateModel.webView를 매 프레임 점검(재사용 오염 방지).
// 3) 세션 복원 중엔( stateModel.isRestoringSession == true ) 불필요한 재로드 금지(스택 구축 전 상태 오염 방지).
// 4) ★복원 완료 "최종 시점"에만 finishSessionRestore() + navigationDidFinish.send() 발생.

struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    // MARK: - makeUIView
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        // 구성
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

        // delegate 연결
        webView.navigationDelegate = stateModel
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        stateModel.webView = webView

        // Pull to Refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
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
            // 전역 복원 버퍼 경로(탭 복원)
            stateModel.prepareRestoredHistoryIfNeeded()
        }

        // 전역 네비게이션 액션(Notification 기반) 수신
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

    // MARK: - updateUIView
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 🛠 재사용 방지: delegate/참조 재바인딩
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

        // 🛠 복원 중엔 외부에서 들어온 currentURL로 재로드 금지(복원 체인 진행 중)
        if stateModel.isRestoringSession { return }

        // URL 변경 시에만 로드 (중복 네비게이션 방지)
        guard let url = stateModel.currentURL else { return }
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("URL 업데이트 로드: \(url)")
        }
    }

    // MARK: - dismantleUIView
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
        TabPersistenceManager.debugMessages.append("WebView 소멸: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Video Script
    private func makeVideoScript() -> WKUserScript {
        let scriptSource = """
        function processVideos(doc) {
            [...doc.querySelectorAll('video')].forEach(video => {
                // iOS 자동재생 제약 회피
                video.muted = true;
                video.volume = 0;
                video.setAttribute('muted','true');

                // AVPlayer로 넘기는 핸들러(중복 부착 방지)
                if (!video.hasAttribute('nativeAVPlayerListener')) {
                    video.addEventListener('click', () => {
                        window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
                    });
                    video.setAttribute('nativeAVPlayerListener', 'true');
                }

                // 가능하면 PiP 자동 진입 시도(실패 무시)
                if (document.pictureInPictureEnabled &&
                    !video.disablePictureInPicture &&
                    !document.pictureInPictureElement) {
                    try { video.requestPictureInPicture().catch(() => {}); } catch (e) {}
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

    // MARK: - Audio Session
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

    // MARK: - 세션 복원 (순차 로드 → 대상 인덱스로 이동)
    /// 저장된 `urls`를 순차 로드한 뒤, backList 기준 `currentIndex` 위치로 점프.
    /// 점프가 완료되는 didFinish에서만 복원 종료 + 저장 신호를 1회 발행한다.
    private func restoreSession(_ session: WebViewSession, webView: WKWebView) {
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, urls.count - 1))
        TabPersistenceManager.debugMessages.append("세션 복원 시도: \(urls.count) URLs, 인덱스 \(targetIndex)")

        guard urls.indices.contains(targetIndex) else {
            TabPersistenceManager.debugMessages.append("세션 복원 실패: 인덱스 범위 초과")
            return
        }

        // 복원 시작 플래그 (외부가 이미 올려놨더라도 안전)
        stateModel.beginSessionRestore()

        // 순차 로드 체인
        loadURLsSequentially(urls, index: 0, webView: webView) {
            // 순차 로드 완료 → backList 기준 목표 위치로 맞추기
            let backList = webView.backForwardList.backList
            let backCount = backList.count

            if targetIndex == backCount {
                // 이미 현재 아이템이 목표 위치인 케이스(뒤로갈 항목이 targetIndex개)
                self.stateModel.finishSessionRestore()
                self.stateModel.navigationDidFinish.send(())
                TabPersistenceManager.debugMessages.append("세션 복원 완료(점프 불필요)")
            } else if backList.indices.contains(targetIndex) {
                // 최종 점프의 didFinish 직후에만 복원 종료 + 저장 신호 발행
                (webView.navigationDelegate as? WebViewStateModel)?.onLoadCompletion = { [weak stateModel] in
                    guard let stateModel = stateModel else { return }
                    stateModel.finishSessionRestore()
                    stateModel.navigationDidFinish.send(())
                    TabPersistenceManager.debugMessages.append("세션 복원 최종 완료(go(to:) 이후)")
                }
                webView.go(to: backList[targetIndex])
                TabPersistenceManager.debugMessages.append("세션 복원 go(to:) 실행")
            } else {
                // 실패 시에도 복원 종료만 확실히
                self.stateModel.finishSessionRestore()
                TabPersistenceManager.debugMessages.append("세션 복원 실패: backList 인덱스 범위 초과")
            }
        }
    }

    /// URL 배열을 "한 개씩" 로드. 각 페이지의 didFinish에서 다음으로 이어짐.
    private func loadURLsSequentially(_ urls: [URL], index: Int, webView: WKWebView, completion: @escaping () -> Void) {
        guard index < urls.count else {
            completion()
            TabPersistenceManager.debugMessages.append("URL 순차 로드 완료")
            return
        }
        let url = urls[index]
        webView.load(URLRequest(url: url))
        (webView.navigationDelegate as? WebViewStateModel)?.onLoadCompletion = { [weak self] in
            TabPersistenceManager.debugMessages.append("URL 로드 완료: \(url)")
            (webView.navigationDelegate as? WebViewStateModel)?.onLoadCompletion = nil
            self?.loadURLsSequentially(urls, index: index + 1, webView: webView, completion: completion)
        }
    }

    // MARK: - Coordinator (WKUIDelegate & Script Handler)
    class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) { self.parent = parent }

        // 전역 버튼 액션
        @objc func goBack()    { webView?.goBack();    TabPersistenceManager.debugMessages.append("뒤로가기 실행") }
        @objc func goForward() { webView?.goForward(); TabPersistenceManager.debugMessages.append("앞으로가기 실행") }
        @objc func reloadWebView() { webView?.reload(); TabPersistenceManager.debugMessages.append("새로고침 실행") }

        // Pull-to-Refresh
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
            TabPersistenceManager.debugMessages.append("Pull to Refresh 실행")
        }

        // window.open 등 새 창 요청 → 현재 웹뷰로 열기
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