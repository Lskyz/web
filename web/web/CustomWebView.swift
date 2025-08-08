import SwiftUI
import WebKit
import AVFoundation
import UIKit

// MARK: - CustomWebView (단순화된 시스템)
/// 기존 복잡한 지연로드/복원 시스템 제거, 페이지 기록 시스템으로 단순화
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    var onScroll: ((CGFloat) -> Void)? = nil

    // MARK: - makeUIView (단순화)
    func makeUIView(context: Context) -> WKWebView {
        configureAudioSessionForMixing()

        // 웹뷰 설정 구성
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.processPool = WKProcessPool()

        // 사용자 스크립트/메시지 핸들러
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoDetectionScript())
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.decelerationRate = .normal

        // delegate 연결
        webView.navigationDelegate = stateModel
        webView.uiDelegate = context.coordinator
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
        webView.scrollView.delegate = context.coordinator

        // 단순화된 초기 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("🌐 초기 URL 로드: \(url.absoluteString)")
        } else {
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            TabPersistenceManager.debugMessages.append("🌐 빈 페이지 로드")
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

        return webView
    }

    // MARK: - updateUIView
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

    // MARK: - teardown
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.scrollView.delegate = nil
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil
        coordinator.webView = nil
        
        // NotificationCenter 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - JS: 비디오 자동 감지
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

    // MARK: - 오디오 세션
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

        // 네비게이션 명령들 (단순화)
        @objc func reloadWebView() {
            webView?.reload()
        }
        
        @objc func goBack() {
            guard let webView = webView else { return }
            if webView.canGoBack {
                webView.goBack()
            }
        }
        
        @objc func goForward() {
            guard let webView = webView else { return }
            if webView.canGoForward {
                webView.goForward()
            }
        }

        // UIScrollViewDelegate: 실제 웹 콘텐츠 스크롤 전달
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll?(scrollView.contentOffset.y)
        }
        
        // MARK: - WKUIDelegate 메서드들
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // 새 창 요청 시 현재 웹뷰에서 로드
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
        
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            // JavaScript alert 처리
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "알림", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                    completionHandler()
                })
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootVC = window.rootViewController {
                    var presentingVC = rootVC
                    while let presented = presentingVC.presentedViewController {
                        presentingVC = presented
                    }
                    presentingVC.present(alert, animated: true)
                } else {
                    completionHandler()
                }
            }
        }
        
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            // JavaScript confirm 처리
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "확인", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                    completionHandler(false)
                })
                alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                    completionHandler(true)
                })
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootVC = window.rootViewController {
                    var presentingVC = rootVC
                    while let presented = presentingVC.presentedViewController {
                        presentingVC = presented
                    }
                    presentingVC.present(alert, animated: true)
                } else {
                    completionHandler(false)
                }
            }
        }
        
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithMessage prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            // JavaScript prompt 처리
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "입력", message: prompt, preferredStyle: .alert)
                alert.addTextField { textField in
                    textField.text = defaultText
                }
                alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                    completionHandler(nil)
                })
                alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in
                    let text = alert.textFields?.first?.text
                    completionHandler(text)
                })
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootVC = window.rootViewController {
                    var presentingVC = rootVC
                    while let presented = presentingVC.presentedViewController {
                        presentingVC = presented
                    }
                    presentingVC.present(alert, animated: true)
                } else {
                    completionHandler(nil)
                }
            }
        }
        
        // 파일 업로드 처리 (iOS 버전 - WKOpenPanelParameters 없이)
        @available(iOS 14.0, *)
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: Any, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            DispatchQueue.main.async {
                let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
                documentPicker.allowsMultipleSelection = true
                documentPicker.delegate = FilePicker(completionHandler: completionHandler)
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootVC = window.rootViewController {
                    var presentingVC = rootVC
                    while let presented = presentingVC.presentedViewController {
                        presentingVC = presented
                    }
                    presentingVC.present(documentPicker, animated: true)
                } else {
                    completionHandler(nil)
                }
            }
        }
    }
}

// MARK: - 파일 선택 헬퍼
@available(iOS 14.0, *)
class FilePicker: NSObject, UIDocumentPickerDelegate {
    let completionHandler: ([URL]?) -> Void
    
    init(completionHandler: @escaping ([URL]?) -> Void) {
        self.completionHandler = completionHandler
    }
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completionHandler(urls)
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completionHandler(nil)
    }
}
