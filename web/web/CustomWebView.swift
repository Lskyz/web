import SwiftUI
import WebKit
import AVFoundation
import UIKit

// MARK: - CustomWebView
// ✅ 개선사항:
// 1) 지연로드 방식 지원: 세션 복원 시 모든 페이지를 로드하지 않고 현재 페이지만 로드
// 2) 메모리 캐시 최적화: 불필요한 히스토리 로드 제거
// 3) 기존 기능 유지: 모든 기존 기능은 그대로 작동

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
        
        // ✅ 웹뷰 캐시 설정
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        // ✅ 성능 최적화: 프로세스 풀 사용
        config.processPool = WKProcessPool()

        // 사용자 스크립트/메시지 핸들러
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())
        controller.add(context.coordinator, name: "playVideo")
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        
        // ✅ 메모리 최적화: 스크롤뷰 설정
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.decelerationRate = UIScrollView.DecelerationRate.normal

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

        // ◾️ ✅ 최적화된 세션 복원 또는 초기 로드
        if let session = stateModel.pendingSession {
            TabPersistenceManager.debugMessages.append("✅ 지연로드 세션 복원 시도: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
            // 🔸 복원 시작 플래그 ON (히스토리/방문기록 오염 방지)
            stateModel.beginSessionRestore()
            // ✅ 기존의 전체 순차 로드 대신 최적화된 복원 사용
            // (WebViewStateModel에서 executeOptimizedRestore가 자동 호출됨)
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

        // ✅ URL 변경 시에만 로드 (중복 네비게이션 방지, 지연로드 방식과 호환)
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
        
        // ✅ 메모리 정리: 웹뷰 데이터 정리
        DispatchQueue.main.async {
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) { 
                TabPersistenceManager.debugMessages.append("WebView 캐시 정리 완료")
            }
        }
        
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

    // MARK: - ✅ 제거된 기능: 기존 복잡한 순차 로드 로직
    // restoreSession, loadURLsSequentially 등의 메서드들은 제거됨
    // 대신 WebViewStateModel의 executeOptimizedRestore가 처리함

    // MARK: - Coordinator (WKUIDelegate & Script Message Handler & ✅ UIScrollViewDelegate)
    class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) { self.parent = parent }

        // ✅ 최적화된 전역 버튼 액션(Notification) 처리 - 지연로드와 호환
        @objc func goBack() {
            // 가상 히스토리 사용 중이면 StateModel이 처리하고, 아니면 직접 처리
            if parent.stateModel.isUsingVirtualHistory {
                parent.stateModel.goBack() // 이미 지연로드 로직 포함
            } else {
                webView?.goBack()
            }
            TabPersistenceManager.debugMessages.append("뒤로가기 실행 (최적화)")
        }
        
        @objc func goForward() {
            // 가상 히스토리 사용 중이면 StateModel이 처리하고, 아니면 직접 처리
            if parent.stateModel.isUsingVirtualHistory {
                parent.stateModel.goForward() // 이미 지연로드 로직 포함
            } else {
                webView?.goForward()
            }
            TabPersistenceManager.debugMessages.append("앞으로가기 실행 (최적화)")
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
