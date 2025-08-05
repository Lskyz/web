import SwiftUI
import WebKit
import AVFoundation

// MARK: - CustomWebView
// WKWebView를 SwiftUI에서 쓰기 위한 UIViewRepresentable.
// ⚠️ 핵심 수정 요약
// 1) (ContentView 쪽 작업) 이 뷰를 쓰는 곳에서 .id(탭의 고유 UUID) 를 반드시 부여해서
//    각 탭이 서로 다른 WKWebView 인스턴스를 갖도록 강제합니다.
// 2) (아래 코드) updateUIView에서 재사용 상황을 방지/정정하기 위해
//    navigationDelegate/uiDelegate/stateModel.webView 바인딩을 매번 확인/재설정합니다.
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    // MARK: - makeUIView
    // 최초 생성 시점: WKWebView 구성/스크립트/옵저버 연결.
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())
        controller.add(context.coordinator, name: "playVideo")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        // 최초 delegate 설정
        webView.navigationDelegate = stateModel                 // ✅ stateModel이 WKNavigationDelegate
        webView.uiDelegate = context.coordinator                // ✅ UI delegate는 coordinator
        context.coordinator.webView = webView
        stateModel.webView = webView

        // Pull-to-Refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator,
                                 action: #selector(Coordinator.handleRefresh(_:)),
                                 for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // 세션/초기 URL 로드
        if let session = stateModel.pendingSession {
            TabPersistenceManager.debugMessages.append("세션 복원 시도: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
            restoreSession(session, webView: webView)
            stateModel.pendingSession = nil
        } else if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("초기 URL 로드: \(url)")
        } else {
            stateModel.prepareRestoredHistoryIfNeeded()
        }

        // 전역 액션 옵저버
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
    // 뷰 재사용(다른 탭으로 바뀌며 같은 WKWebView가 재바인딩)될 수 있어 여기서 바인딩을 항상 교정.
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // ✅ [수정 위치 #1] 재사용 안전장치 — delegate, uiDelegate, stateModel.webView 재바인딩
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

        // URL 변경 시에만 로드
        guard let url = stateModel.currentURL else { return }
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("URL 업데이트 로드: \(url)")
        }
    }

    // MARK: - dismantleUIView
    // 뷰 해제 시 정리.
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
        TabPersistenceManager.debugMessages.append("WebView 소멸: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Video Script
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

    // MARK: - 세션 복원 (순차 로드)
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

    private func loadURLsSequentially(_ urls: [URL], index: Int, webView: WKWebView, completion: @escaping () -> Void) {
        guard index < urls.count else {
            completion()
            TabPersistenceManager.debugMessages.append("URL 순차 로드 완료")
            return
        }
        webView.load(URLRequest(url: urls[index]))
        (webView.navigationDelegate as? WebViewStateModel)?.onLoadCompletion = {
            TabPersistenceManager.debugMessages.append("URL 로드 완료: \(urls[index])")
            self.loadURLsSequentially(urls, index: index + 1, webView: webView, completion: completion)
        }
    }

    // MARK: - Coordinator (UI Delegate & Script Handler)
    class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) { self.parent = parent }

        @objc func goBack() { webView?.goBack(); TabPersistenceManager.debugMessages.append("뒤로가기 실행") }
        @objc func goForward() { webView?.goForward(); TabPersistenceManager.debugMessages.append("앞으로가기 실행") }
        @objc func reloadWebView() { webView?.reload(); TabPersistenceManager.debugMessages.append("새로고침 실행") }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
            TabPersistenceManager.debugMessages.append("Pull to Refresh 실행")
        }

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