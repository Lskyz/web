import SwiftUI
import WebKit
import AVFoundation
import UIKit // ✅ UIScrollViewDelegate 사용을 위해 추가

// MARK: - CustomWebView
// 1) ContentView 쪽에서 .id(tabID)를 부여해 탭별로 WKWebView 인스턴스가 분리되도록 강제
// 2) updateUIView에서 navigationDelegate, uiDelegate, stateModel.webView를 매번 확인·재설정해
//    SwiftUI 뷰 재사용 시 연결이 엉키지 않도록 방어
// 3) 세션 복원 중(stateModel.isRestoringSession == true)엔 불필요한 재로드를 막아
//    back/forward 리스트 구축이 끝나기 전 상태 오염을 방지
// 4) ✅ 추가: webView.scrollView의 스크롤을 UIScrollViewDelegate로 직접 수신해
//    ContentView로 y 오프셋을 콜백(onScroll)으로 전달 (스크롤시 주소창 숨김/표시 판단용)

struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    // ✅ 추가: 실제 스크롤 y오프셋을 외부(ContentView)로 전달하는 콜백. 미지정(nil) 시 무시됨.
    var onScroll: ((CGFloat) -> Void)? = nil

    // MARK: - makeUIView
    // 최초 한 번 WKWebView를 생성·구성하고 델리게이트, 스크립트, 옵저버 등을 붙인다.
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
        webView.navigationDelegate = stateModel              // 상태 모델이 네비게이션 델리게이트
        webView.uiDelegate = context.coordinator             // UI 델리게이트는 코디네이터
        context.coordinator.webView = webView
        stateModel.webView = webView // 🔧 webView 설정 시 대기 중인 복원 로직이 자동 실행됨

        // Pull to Refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refreshControl

        // ✅ 스크롤 델리게이트 연결 (실제 콘텐츠 스크롤 y오프셋을 수신하기 위함)
        webView.scrollView.delegate = context.coordinator

        // ◾️ 세션 복원 또는 초기 로드
        if let session = stateModel.pendingSession {
            TabPersistenceManager.debugMessages.append("세션 복원 시도: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
            // 🔸 복원 시작 플래그 ON (히스토리/방문기록 오염 방지)
            stateModel.beginSessionRestore()
            restoreSession(session, webView: webView)
            stateModel.pendingSession = nil
        } else if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("초기 URL 로드: \(url)")
        }

        // 전역 네비게이션 액션(Notification) 수신
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

    // MARK: - updateUIView
    // SwiftUI가 뷰를 재사용할 수 있으므로, 델리게이트/바인딩을 매 프레임 점검하여 오염 방지.
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 🛠 재사용 방지용 재바인딩(필수)
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
        // ✅ 스크롤 델리게이트도 재확인 (재사용 시 다른 객체로 바뀌는 것을 방지)
        if uiView.scrollView.delegate !== context.coordinator {
            uiView.scrollView.delegate = context.coordinator
        }

        // 🛠 세션 복원 중엔 불필요한 재로드 금지
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

    // MARK: - dismantleUIView
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
    // 🔧 개선된 히스토리 복원 - WebViewStateModel과 협력하여 안정적인 복원 수행
    private func restoreSession(_ session: WebViewSession, webView: WKWebView) {
        let urls = session.urls
        let currentIndex = max(0, min(session.currentIndex, urls.count - 1))
        TabPersistenceManager.debugMessages.append("세션 복원 시도: \(urls.count) URLs, 인덱스 \(currentIndex)")

        guard urls.indices.contains(currentIndex) else {
            TabPersistenceManager.debugMessages.append("세션 복원 실패: 인덱스 범위 초과")
            stateModel.finishSessionRestore()
            return
        }

        // 🔧 안정적인 순차 로드를 위한 비동기 처리
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak stateModel] in
            CustomWebView.loadURLsSequentially(urls, index: 0, targetIndex: currentIndex, webView: webView, stateModel: stateModel)
        }
    }

    // MARK: - 순차 로드 유틸리티(Static)
    // 🔧 개선된 순차 로드: 각 URL 로드 간 적절한 딜레이로 안정성 확보
    private static func loadURLsSequentially(
        _ urls: [URL],
        index: Int,
        targetIndex: Int,
        webView: WKWebView,
        stateModel: WebViewStateModel?
    ) {
        guard let stateModel = stateModel else { return }
        
        // 모든 URL 로드 완료 시 목표 인덱스로 이동
        if index >= urls.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let backList = webView.backForwardList.backList
                if backList.indices.contains(targetIndex) {
                    // 최종 복원 완료 콜백 설정
                    stateModel.onLoadCompletion = { [weak stateModel] in
                        TabPersistenceManager.debugMessages.append("히스토리 복원 최종 완료")
                        stateModel?.finishSessionRestore()
                        // 복원 완료 신호 발송
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            stateModel?.navigationDidFinish.send(())
                        }
                    }
                    webView.go(to: backList[targetIndex])
                    TabPersistenceManager.debugMessages.append("목표 인덱스로 이동: \(targetIndex)")
                } else {
                    TabPersistenceManager.debugMessages.append("목표 인덱스 이동 실패: 범위 초과")
                    stateModel.finishSessionRestore()
                }
            }
            return
        }

        let currentURL = urls[index]
        TabPersistenceManager.debugMessages.append("순차 로드 중: [\(index)/\(urls.count-1)] \(currentURL.absoluteString)")
        
        // 로드 완료 콜백 설정
        stateModel.onLoadCompletion = { [weak webView, weak stateModel] in
            TabPersistenceManager.debugMessages.append("순차 로드 완료: [\(index)] \(currentURL.absoluteString)")
            guard let wv = webView, let sm = stateModel else { return }
            
            // 다음 URL로 진행 (안정성을 위한 딜레이)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                CustomWebView.loadURLsSequentially(urls, index: index + 1, targetIndex: targetIndex, webView: wv, stateModel: sm)
            }
        }
        
        // URL 로드 실행
        webView.load(URLRequest(url: currentURL))
    }

    // MARK: - Coordinator (WKUIDelegate & Script Message Handler & ✅ UIScrollViewDelegate)
    class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
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

        // ✅ UIScrollViewDelegate: 실제 웹 콘텐츠 스크롤 전달
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // y 오프셋(위로 스크롤: 감소, 아래로 스크롤: 증가)
            parent.onScroll?(scrollView.contentOffset.y)
        }
    }
}