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
        controller.addUserScript(makeVideoDetectionScript())
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        
        // 스크롤 최적화
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.decelerationRate = .normal

        // delegate 연결
        webView.navigationDelegate = stateModel
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        stateModel.webView = webView // webView 설정 시 pendingSession이 있으면 복원 트리거됨

        // Pull to Refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refreshControl

        // ✅ 스크롤 델리게이트 연결
        webView.scrollView.delegate = context.coordinator

        // ◾️ ✅ 최적화된 세션 복원 또는 초기 로드
        if let _ = stateModel.pendingSession {
            TabPersistenceManager.debugMessages.append("✅ 지연로드 세션 복원 시도: 탭 \(stateModel.tabID?.uuidString ?? "없음")")
            // 🔸 복원 시작 플래그 ON (히스토리/방문기록 오염 방지)
            stateModel.beginSessionRestore()
            // (WebViewStateModel에서 executeOptimizedRestore가 자동 호출됨)
            // [FIX] 복원 완료 콜백에서 정리하므로 여기선 건드리지 않음
            // stateModel.pendingSession = nil
        } else if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
        } else if let home = URL(string: "about:blank") {
            webView.load(URLRequest(url: home))
        }

        // 옵저버
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleExternalOpenURL(_:)),
            name: .init("ExternalOpenURL"),
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
        if uiView.uiDelegate !== context.coordinator {
            uiView.uiDelegate = context.coordinator
        }
        if uiView.navigationDelegate !== stateModel {
            uiView.navigationDelegate = stateModel
        }
        if context.coordinator.webView !== uiView {
            context.coordinator.webView = uiView
        }
        // (다크모드/추가 설정 동기화 자리)
    }

    // MARK: - teardown
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.scrollView.delegate = nil
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil
        coordinator.webView = nil
    }

    // MARK: - JS: 비디오 자동 감지 (예: mp4 링크 → AVPlayer)
    private func makeVideoDetectionScript() -> WKUserScript {
        let scriptSource = """
        (function() {
            function processVideos(doc) {
                var anchors = doc.querySelectorAll('a[href]');
                anchors.forEach(function(a) {
                    var href = a.getAttribute('href');
                    if (!href) return;
                    var lower = href.toLowerCase();
                    if (lower.endsWith('.mp4') || lower.includes('m3u8') || lower.includes('mpd')) {
                        window.webkit.messageHandlers.videoURL?.postMessage(href);
                    }
                });
            }
            processVideos(document);
            setInterval(function() {
                var iframes = document.querySelectorAll('iframe');
                iframes.forEach(function(iframe) {
                    try {
                        const doc = iframe.contentDocument || iframe.contentWindow?.document;
                        if (doc) processVideos(doc);
                    } catch (e) {}
                });
            }, 1000);
        })();
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

    // MARK: - Coordinator
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, WKUIDelegate, UIScrollViewDelegate {
        var parent: CustomWebView
        weak var webView: WKWebView?

        init(_ parent: CustomWebView) { self.parent = parent }

        // Pull to Refresh
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                sender.endRefreshing()
            }
        }

        // 외부 URL 오픈 핸들링
        @objc func handleExternalOpenURL(_ note: Notification) {
            guard
                let userInfo = note.userInfo,
                let url = userInfo["url"] as? URL,
                let webView = webView
            else { return }
            webView.load(URLRequest(url: url))
        }

        // 재로딩
        @objc func reloadWebView() {
            webView?.reload()
        }

        // 파일 선택/새 창 등 WKUIDelegate 구현은 필요한 만큼 추가…
        // (요청: 애먼데 수정하지 않음)

        // ✅ UIScrollViewDelegate: 실제 웹 콘텐츠 스크롤 전달
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll?(scrollView.contentOffset.y)
        }
    }
}
