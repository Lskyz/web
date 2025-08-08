import SwiftUI
import WebKit
import AVFoundation
import UIKit

// MARK: - CustomWebView
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool
    var onScroll: ((CGFloat) -> Void)? = nil
    
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()
        
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.processPool = WKProcessPool()
        
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())
        controller.add(context.coordinator, name: "playVideo")
        config.userContentController = controller
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.decelerationRate = .normal
        
        webView.navigationDelegate = stateModel
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        stateModel.webView = webView
        
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleRefresh(_:)),
            for: .valueChanged
        )
        webView.scrollView.refreshControl = refreshControl
        
        webView.scrollView.delegate = context.coordinator
        
        if let session = stateModel.pendingSession {
            let urlList = session.history.map { $0.debugDescription }.joined(separator: ", ")
            TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(stateModel.tabID?.uuidString ?? "없음")] ✅ 지연로드 세션 복원 시도: \(session.history.count) 항목, 인덱스 \(session.currentIndex) | entries=[\(urlList)]")
            stateModel.beginSessionRestore()
        } else if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(stateModel.tabID?.uuidString ?? "없음")] 초기 URL 로드: \(url.absoluteString)")
        } else if let home = URL(string: "about:blank") {
            webView.load(URLRequest(url: home))
            TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(stateModel.tabID?.uuidString ?? "없음")] 초기 about:blank 로드")
        }
        
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
    }
    
    func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        deactivateAudioSession()
        NotificationCenter.default.removeObserver(coordinator)
        let urlList = stateModel.virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
        TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(stateModel.tabID?.uuidString ?? "없음")] WebView 소멸: 히스토리=[\(urlList)]")
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
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
    
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(stateModel.tabID?.uuidString ?? "없음")] 오디오 세션 활성화")
    }
    
    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(stateModel.tabID?.uuidString ?? "없음")] 오디오 세션 비활성화")
    }
    
    class Coordinator: NSObject, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?
        
        init(_ parent: CustomWebView) { self.parent = parent }
        
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                sender.endRefreshing()
            }
            let urlList = parent.stateModel.virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
            TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(parent.stateModel.tabID?.uuidString ?? "없음")] 새로고침: 히스토리=[\(urlList)]")
        }
        
        @objc func handleExternalOpenURL(_ note: Notification) {
            guard
                let userInfo = note.userInfo,
                let url = userInfo["url"] as? URL,
                let webView = webView
            else { return }
            webView.load(URLRequest(url: url))
            let urlList = parent.stateModel.virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
            TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(parent.stateModel.tabID?.uuidString ?? "없음")] 외부 URL 로드: \(url.absoluteString), 히스토리=[\(urlList)]")
        }
        
        @objc func reloadWebView() {
            webView?.reload()
            let urlList = parent.stateModel.virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
            TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(parent.stateModel.tabID?.uuidString ?? "없음")] 웹뷰 재로딩: 히스토리=[\(urlList)]")
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo",
               let urlString = message.body as? String,
               let videoURL = URL(string: urlString) {
                DispatchQueue.main.async {
                    self.parent.playerURL = videoURL
                    self.parent.showAVPlayer = true
                    TabPersistenceManager.debugMessages.append("[\(formattedTimestamp())][tab\(parent.stateModel.tabID?.uuidString ?? "없음")] 비디오 재생 요청: \(urlString)")
                }
            }
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll?(scrollView.contentOffset.y)
        }
    }
    
    // 타임스탬프 포맷터 (WebViewStateModel과 통일)
    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}