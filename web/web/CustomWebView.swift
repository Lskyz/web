import SwiftUI
import WebKit
import AVFoundation

// MARK: - CustomWebView: WKWebView를 SwiftUI에서 사용하기 위한 래퍼
struct CustomWebView: UIViewRepresentable {
    // 외부에서 주입된 WebView 상태 관리 모델
    @ObservedObject var stateModel: WebViewStateModel
    // 비디오 재생을 위한 URL 바인딩
    @Binding var playerURL: URL?
    // AVPlayer 전체화면 표시 여부 바인딩
    @Binding var showAVPlayer: Bool

    // MARK: - WKWebView 생성 및 초기화
    func makeUIView(context: Context) -> WKWebView {
        // 오디오 세션 설정: 다른 앱과 혼합 재생 가능
        configureAudioSessionForMixing()

        // WKWebView 설정 구성
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true // 인라인 비디오 재생 허용
        config.allowsPictureInPictureMediaPlayback = true // PiP 재생 허용
        config.mediaTypesRequiringUserActionForPlayback = [] // 사용자 동작 없이 재생

        // JavaScript 메시지 처리용 컨트롤러 설정
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript()) // 비디오 자동 처리 스크립트 추가
        controller.add(context.coordinator, name: "playVideo") // JS 메시지 핸들러 등록
        config.userContentController = controller

        // WKWebView 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true // 뒤로/앞으로 제스처 허용
        webView.navigationDelegate = context.coordinator // 내비게이션 델리게이트 설정
        webView.uiDelegate = context.coordinator // UI 델리게이트 설정
        context.coordinator.webView = webView // Coordinator에 웹뷰 참조 전달
        stateModel.webView = webView // WebViewStateModel에 웹뷰 참조 전달

        // Pull to Refresh 설정
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // 세션 복원 또는 초기 URL 로딩
        if let session = stateModel.pendingSession {
            TabPersistenceManager.debugMessages.append("세션 복원 시도: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
            restoreSession(session, webView: webView)
            stateModel.pendingSession = nil
        } else if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("초기 URL 로드: \(url)")
        } else {
            // 저장된 히스토리 복원 시도
            stateModel.prepareRestoredHistoryIfNeeded()
        }

        // 외부 명령(뒤로가기, 앞으로가기, 새로고침) 처리용 Notification 등록
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goBack), name: .init("WebViewGoBack"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.goForward), name: .init("WebViewGoForward"), object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.reloadWebView), name: .init("WebViewReload"), object: nil)

        return webView
    }

    // MARK: - WKWebView 상태 업데이트
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = stateModel.currentURL else { return }
        // 동일한 URL은 중복 로드 방지
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("URL 업데이트 로드: \(url)")
        }
    }

    // MARK: - 뷰 소멸 시 리소스 정리
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading() // 로딩 중지
        deactivateAudioSession() // 오디오 세션 비활성화
        NotificationCenter.default.removeObserver(coordinator) // Notification 제거
        TabPersistenceManager.debugMessages.append("WebView 소멸: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
    }

    // MARK: - Coordinator 생성
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - 비디오 자동 처리 JavaScript 생성
    private func makeVideoScript() -> WKUserScript {
        let scriptSource = """
        function processVideos(doc) {
            [...doc.querySelectorAll('video')].forEach(video => {
                video.muted = true;
                video.volume = 0;
                video.setAttribute('muted','true');
                if (!video.hasAttribute('nativeAVPlayerListener')) {
                    video.addEventListener('click', () => {
                        window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
                    });
                    video.setAttribute('nativeAVPlayerListener', 'true');
                }
                if (document.pictureInPictureEnabled &&
                    !video.disablePictureInPicture &&
                    !document.pictureInPictureElement) {
                    try {
                        video.requestPictureInPicture().catch(() => {});
                    } catch (e) {}
                }
            });
        }
        processVideos(document);
        setInterval(() => {
            processVideos(document);
            [...document.querySelectorAll('iframe')].forEach(iframe => {
                try {
                    const doc = iframe.contentDocument || iframe.contentWindow?.document;
                    if doc { processVideos(doc); }
                } catch (e) {}
            });
        }, 1000);
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    // MARK: - 오디오 세션 설정: 다른 앱과 혼합 재생
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        TabPersistenceManager.debugMessages.append("오디오 세션 활성화")
    }

    // MARK: - 오디오 세션 비활성화
    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        TabPersistenceManager.debugMessages.append("오디오 세션 비활성화")
    }

    // MARK: - 세션 복원: 방문 기록 복원
    private func restoreSession(_ session: WebViewSession, webView: WKWebView) {
        let urls = session.urls
        let currentIndex = session.currentIndex
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

    // MARK: - URL을 순차적으로 로드하여 세션 구성
    private func loadURLsSequentially(_ urls: [URL], index: Int, webView: WKWebView, completion: @escaping () -> Void) {
        guard index < urls.count else {
            completion()
            TabPersistenceManager.debugMessages.append("URL 순차 로드 완료")
            return
        }

        webView.load(URLRequest(url: urls[index]))
        // WKNavigationDelegate에서 로드 완료 확인
        (webView.navigationDelegate as? Coordinator)?.onLoadCompletion = {
            TabPersistenceManager.debugMessages.append("URL 로드 완료: \(urls[index])")
            self.loadURLsSequentially(urls, index: index + 1, webView: webView, completion: completion)
        }
    }

    // MARK: - Coordinator: WKWebView 이벤트 관리
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?
        var onLoadCompletion: (() -> Void)? // 로드 완료 콜백

        init(_ parent: CustomWebView) {
            self.parent = parent
        }

        // 외부 명령 처리
        @objc func goBack() { webView?.goBack(); TabPersistenceManager.debugMessages.append("뒤로가기 실행") }
        @objc func goForward() { webView?.goForward(); TabPersistenceManager.debugMessages.append("앞으로가기 실행") }
        @objc func reloadWebView() { webView?.reload(); TabPersistenceManager.debugMessages.append("새로고침 실행") }

        // Pull to Refresh 처리
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
            TabPersistenceManager.debugMessages.append("Pull to Refresh 실행")
        }

        // 페이지 로드 완료 처리
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.stateModel.canGoBack = webView.canGoBack
            parent.stateModel.canGoForward = webView.canGoForward
            parent.stateModel.currentURL = webView.url

            let title = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "제목 없음")
            if let finalURL = webView.url {
                parent.stateModel.addToHistory(url: finalURL, title: title)
            }
            TabPersistenceManager.debugMessages.append("페이지 로드 완료: \(webView.url?.absoluteString ?? "없음")")
            onLoadCompletion?()
            onLoadCompletion = nil
        }

        // 새 창 요청을 현재 웹뷰로 처리
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                TabPersistenceManager.debugMessages.append("새 창 요청을 현재 웹뷰로 로드: \(navigationAction.request.url?.absoluteString ?? "없음")")
            }
            return nil
        }

        // JavaScript 메시지 처리 (비디오 재생)
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo", let urlString = message.body as? String, let videoURL = URL(string: urlString) {
                DispatchQueue.main.async {
                    self.parent.playerURL = videoURL
                    self.parent.showAVPlayer = true
                    TabPersistenceManager.debugMessages.append("비디오 재생 요청: \(urlString)")
                }
            }
        }

        // 로드 실패 처리
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            TabPersistenceManager.debugMessages.append("로드 실패 (Provisional): \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            TabPersistenceManager.debugMessages.append("로드 실패 (Navigation): \(error.localizedDescription)")
        }
    }
}
