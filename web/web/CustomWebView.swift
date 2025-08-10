//
//  CustomWebView.swift
//
//  ✅ 스마트 주소창 & 한글 에러 메시지와 완벽 연동
//  - WebViewStateModel isLoading 상태와 동기화 강화
//  - HTTP/네트워크 에러 감지 및 ContentView 알림 전달 보장
//  - 새로고침/중지 기능과 웹뷰 로딩 상태 완벽 연동
//  - 기존 기능 유지: 비디오 클릭 → AVPlayer, Pull-to-Refresh, 쿠키 동기화, 파일 다운로드
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import Foundation

// MARK: - 다운로드 진행 알림 이름 정의
extension Notification.Name {
    static let WebViewDownloadStart    = Notification.Name("WebViewDownloadStart")
    static let WebViewDownloadProgress = Notification.Name("WebViewDownloadProgress")
    static let WebViewDownloadFinish   = Notification.Name("WebViewDownloadFinish")
    static let WebViewDownloadFailed   = Notification.Name("WebViewDownloadFailed")
}

// MARK: - CustomWebView (UIViewRepresentable)
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool
    var onScroll: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - makeUIView
    func makeUIView(context: Context) -> WKWebView {
        // ✅ 오디오 세션 활성화
        configureAudioSessionForMixing()

        // WKWebView 설정
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.processPool = WKProcessPool()

        // 사용자 스크립트/메시지 핸들러
        let controller = WKUserContentController()
        controller.addUserScript(makeVideoScript())
        controller.add(context.coordinator, name: "playVideo")
        config.userContentController = controller

        // ✨ 다운로드 지원 (iOS 14+)
        if #available(iOS 14.0, *) {
            config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        }

        // WKWebView 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.decelerationRate = .normal

        // ✅ 하단 UI 겹치기를 위한 투명 처리
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero

        // ✨ 강화된 Delegate 연결 (로딩 상태 동기화)
        webView.navigationDelegate = context.coordinator  // ⚠️ 중요: Coordinator로 변경
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

        // ✨ 로딩 상태 동기화를 위한 KVO 옵저버 추가
        context.coordinator.setupLoadingObservers(for: webView)

        // 초기 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("🌐 CustomWebView 초기 URL 로드: \(url.absoluteString)")
        } else {
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            TabPersistenceManager.debugMessages.append("🌐 CustomWebView 빈 페이지 로드")
        }

        // 외부 제어용 Notification 옵저버 등록
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

        // 다운로드 진행률 UI 오버레이 구성
        context.coordinator.installDownloadOverlay(on: webView)

        // 다운로드 관련 이벤트 옵저버 등록
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadStart(_:)),
                                               name: .WebViewDownloadStart,
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadProgress(_:)),
                                               name: .WebViewDownloadProgress,
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadFinish(_:)),
                                               name: .WebViewDownloadFinish,
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadFailed(_:)),
                                               name: .WebViewDownloadFailed,
                                               object: nil)

        return webView
    }

    // MARK: - updateUIView
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 연결 상태 확인 및 재연결
        if uiView.uiDelegate !== context.coordinator {
            uiView.uiDelegate = context.coordinator
        }
        if uiView.navigationDelegate !== context.coordinator {
            uiView.navigationDelegate = context.coordinator
        }
        if context.coordinator.webView !== uiView {
            context.coordinator.webView = uiView
        }

        // ✅ 하단 UI 겹치기를 위한 투명 설정 유지
        if uiView.isOpaque { uiView.isOpaque = false }
        if uiView.backgroundColor != .clear { uiView.backgroundColor = .clear }
        if uiView.scrollView.backgroundColor != .clear { uiView.scrollView.backgroundColor = .clear }
        uiView.scrollView.isOpaque = false
    }

    // MARK: - teardown
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // KVO 옵저버 제거
        coordinator.removeLoadingObservers(for: uiView)
        
        // 스크롤/델리게이트 해제
        uiView.scrollView.delegate = nil
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil
        coordinator.webView = nil

        // 오디오 세션 비활성화
        coordinator.parent.deactivateAudioSession()

        // 메시지 핸들러 제거
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "playVideo")

        // 모든 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - 사용자 스크립트 (비디오 클릭 → AVPlayer)
    private func makeVideoScript() -> WKUserScript {
        let scriptSource = """
        function processVideos(doc) {
            [...doc.querySelectorAll('video')].forEach(video => {
                // iOS 자동재생 제약 회피
                video.muted = true;
                video.volume = 0;
                video.setAttribute('muted','true');

                // AVPlayer로 넘기는 클릭 핸들러 1회만 부착
                if (!video.hasAttribute('nativeAVPlayerListener')) {
                    video.addEventListener('click', () => {
                        window.webkit.messageHandlers.playVideo.postMessage(video.currentSrc || video.src || '');
                    });
                    video.setAttribute('nativeAVPlayerListener', 'true');
                }

                // PiP 자동 진입 시도
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

    // MARK: - 오디오 세션
    private func configureAudioSessionForMixing() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        TabPersistenceManager.debugMessages.append("🔊 오디오 세션 활성화")
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        TabPersistenceManager.debugMessages.append("🔇 오디오 세션 비활성화")
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {

        var parent: CustomWebView
        weak var webView: WKWebView?
        var filePicker: FilePicker?

        // 다운로드 진행률 UI 구성 요소들
        private var overlayContainer: UIVisualEffectView?
        private var overlayTitleLabel: UILabel?
        private var overlayPercentLabel: UILabel?
        private var overlayProgress: UIProgressView?

        // ✨ KVO 옵저버들 (로딩 상태 동기화용)
        private var loadingObserver: NSKeyValueObservation?
        private var urlObserver: NSKeyValueObservation?
        private var titleObserver: NSKeyValueObservation?

        init(_ parent: CustomWebView) { 
            self.parent = parent 
        }

        deinit {
            removeLoadingObservers(for: webView)
        }

        // MARK: - ✨ 로딩 상태 동기화를 위한 KVO 설정
        func setupLoadingObservers(for webView: WKWebView) {
            // isLoading 상태 관찰
            loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
                guard let self = self else { return }
                let isLoading = change.newValue ?? false
                
                DispatchQueue.main.async {
                    // ✨ StateModel의 isLoading과 동기화
                    if self.parent.stateModel.isLoading != isLoading {
                        self.parent.stateModel.isLoading = isLoading
                        TabPersistenceManager.debugMessages.append("📡 CustomWebView 로딩 상태 동기화: \(isLoading)")
                    }
                }
            }

            // URL 변경 관찰
            urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
                guard let self = self, let newURL = change.newValue, let url = newURL else { return }
                
                DispatchQueue.main.async {
                    // StateModel의 currentURL과 동기화 (무한 루프 방지)
                    if self.parent.stateModel.currentURL != url {
                        self.parent.stateModel.isNavigatingFromWebView = true
                        self.parent.stateModel.currentURL = url
                        self.parent.stateModel.isNavigatingFromWebView = false
                        TabPersistenceManager.debugMessages.append("🔄 CustomWebView URL 동기화: \(url.absoluteString)")
                    }
                }
            }

            // 제목 변경 관찰
            titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, change in
                guard let self = self, let title = change.newValue, let title = title, !title.isEmpty else { return }
                
                DispatchQueue.main.async {
                    self.parent.stateModel.updateCurrentPageTitle(title)
                    TabPersistenceManager.debugMessages.append("📝 CustomWebView 제목 동기화: \(title)")
                }
            }
        }

        func removeLoadingObservers(for webView: WKWebView?) {
            loadingObserver?.invalidate()
            urlObserver?.invalidate()
            titleObserver?.invalidate()
            loadingObserver = nil
            urlObserver = nil
            titleObserver = nil
        }

        // MARK: - ✨ WKNavigationDelegate (에러 처리 강화)
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // ✨ 로딩 시작을 StateModel에 전달 (이미 KVO로 동기화되지만 명시적으로도 설정)
            DispatchQueue.main.async {
                if !self.parent.stateModel.isLoading {
                    self.parent.stateModel.isLoading = true
                    TabPersistenceManager.debugMessages.append("🌐 CustomWebView 로딩 시작")
                }
            }
            
            // 기존 StateModel의 didStartProvisionalNavigation 호출
            parent.stateModel.webView(webView, didStartProvisionalNavigation: navigation)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // ✨ 로딩 완료를 StateModel에 전달
            DispatchQueue.main.async {
                if self.parent.stateModel.isLoading {
                    self.parent.stateModel.isLoading = false
                    TabPersistenceManager.debugMessages.append("✅ CustomWebView 로딩 완료")
                }
            }
            
            // 기존 StateModel의 didFinish 호출
            parent.stateModel.webView(webView, didFinish: navigation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // ✨ 로딩 실패 처리
            DispatchQueue.main.async {
                if self.parent.stateModel.isLoading {
                    self.parent.stateModel.isLoading = false
                    TabPersistenceManager.debugMessages.append("❌ CustomWebView 로딩 실패(Provisional)")
                }
            }
            
            // ✨ 에러 알림 전송 (StateModel의 tabID 사용)
            if let tabID = parent.stateModel.tabID {
                NotificationCenter.default.post(
                    name: .webViewDidFailLoad,
                    object: nil,
                    userInfo: [
                        "tabID": tabID.uuidString,
                        "error": error,
                        "url": webView.url?.absoluteString ?? parent.stateModel.currentURL?.absoluteString ?? ""
                    ]
                )
                TabPersistenceManager.debugMessages.append("📡 CustomWebView 에러 알림 전송: \(error.localizedDescription)")
            }
            
            // 기존 StateModel의 didFailProvisionalNavigation 호출
            parent.stateModel.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // ✨ 로딩 실패 처리
            DispatchQueue.main.async {
                if self.parent.stateModel.isLoading {
                    self.parent.stateModel.isLoading = false
                    TabPersistenceManager.debugMessages.append("❌ CustomWebView 로딩 실패(Navigation)")
                }
            }
            
            // ✨ 에러 알림 전송
            if let tabID = parent.stateModel.tabID {
                NotificationCenter.default.post(
                    name: .webViewDidFailLoad,
                    object: nil,
                    userInfo: [
                        "tabID": tabID.uuidString,
                        "error": error,
                        "url": webView.url?.absoluteString ?? parent.stateModel.currentURL?.absoluteString ?? ""
                    ]
                )
                TabPersistenceManager.debugMessages.append("📡 CustomWebView 에러 알림 전송: \(error.localizedDescription)")
            }
            
            // 기존 StateModel의 didFail 호출
            parent.stateModel.webView(webView, didFail: navigation, withError: error)
        }

        // ✨ HTTP 상태 코드 에러 감지 (decidePolicyFor navigationResponse에서)
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            
            // HTTP 응답 상태 코드 체크
            if let httpResponse = navigationResponse.response as? HTTPURLResponse {
                let statusCode = httpResponse.statusCode
                TabPersistenceManager.debugMessages.append("📡 CustomWebView HTTP 상태: \(statusCode)")
                
                // 4xx, 5xx 에러 상태 코드 감지
                if statusCode >= 400 {
                    TabPersistenceManager.debugMessages.append("❌ CustomWebView HTTP 에러 감지: \(statusCode)")
                    
                    // ✨ HTTP 에러 알림 전송
                    if let tabID = parent.stateModel.tabID {
                        NotificationCenter.default.post(
                            name: .webViewDidFailLoad,
                            object: nil,
                            userInfo: [
                                "tabID": tabID.uuidString,
                                "statusCode": statusCode,
                                "url": navigationResponse.response.url?.absoluteString ?? ""
                            ]
                        )
                        TabPersistenceManager.debugMessages.append("📡 CustomWebView HTTP 에러 알림 전송: \(statusCode)")
                    }
                }
            }
            
            // 다운로드 처리 (iOS 14+)
            if #available(iOS 14.0, *) {
                if let http = navigationResponse.response as? HTTPURLResponse,
                   let disp = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
                   disp.contains("attachment") {
                    decisionHandler(.download)
                    return
                }
            }
            
            decisionHandler(.allow)
        }

        // ✨ 다운로드 지원 (iOS 14+)
        @available(iOS 14.0, *)
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = parent.stateModel
            TabPersistenceManager.debugMessages.append("⬇️ CustomWebView 다운로드 시작")
        }

        // MARK: JS → 네이티브 메시지 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "playVideo" else { return }
            if let urlString = message.body as? String, let url = URL(string: urlString) {
                DispatchQueue.main.async {
                    self.parent.playerURL = url
                    self.parent.showAVPlayer = true
                    TabPersistenceManager.debugMessages.append("🎬 비디오 AVPlayer 재생: \(urlString)")
                }
            }
        }

        // MARK: Pull to Refresh
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
            TabPersistenceManager.debugMessages.append("🔄 Pull-to-Refresh 새로고침")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                sender.endRefreshing()
            }
        }

        // MARK: 외부 URL 오픈
        @objc func handleExternalOpenURL(_ note: Notification) {
            guard
                let userInfo = note.userInfo,
                let url = userInfo["url"] as? URL,
                let webView = webView
            else { return }
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("🔗 외부 URL 오픈: \(url.absoluteString)")
        }

        // MARK: 네비게이션 명령
        @objc func reloadWebView() { 
            webView?.reload()
            TabPersistenceManager.debugMessages.append("🔄 WebView 새로고침")
        }
        @objc func goBack() { 
            if webView?.canGoBack == true { 
                webView?.goBack()
                TabPersistenceManager.debugMessages.append("⬅️ WebView 뒤로가기")
            }
        }
        @objc func goForward() { 
            if webView?.canGoForward == true { 
                webView?.goForward()
                TabPersistenceManager.debugMessages.append("➡️ WebView 앞으로가기")
            }
        }

        // MARK: 스크롤 전달
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll?(scrollView.contentOffset.y)
        }

        // ✨ SSL 인증서 경고 처리 (신뢰하지 않는 인증서 무시하고 방문)
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            
            let host = challenge.protectionSpace.host
            TabPersistenceManager.debugMessages.append("🔒 SSL 인증서 검증 요청: \(host)")
            
            // 서버 신뢰성 검증 (SSL/TLS)
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                
                // ✨ 사용자에게 SSL 경고 알림 표시
                DispatchQueue.main.async {
                    guard let topVC = self.topMostViewController() else {
                        // UI가 없으면 기본적으로 허용
                        if let serverTrust = challenge.protectionSpace.serverTrust {
                            let credential = URLCredential(trust: serverTrust)
                            completionHandler(.useCredential, credential)
                            TabPersistenceManager.debugMessages.append("🔓 SSL 인증서 자동 허용: \(host)")
                        } else {
                            completionHandler(.performDefaultHandling, nil)
                        }
                        return
                    }
                    
                    let alert = UIAlertController(
                        title: "보안 연결 경고", 
                        message: "\(host)의 보안 인증서를 신뢰할 수 없습니다.\n\n• 인증서가 만료되었거나\n• 자체 서명된 인증서이거나\n• 신뢰할 수 없는 기관에서 발급되었습니다.\n\n그래도 계속 방문하시겠습니까?",
                        preferredStyle: .alert
                    )
                    
                    // 무시하고 방문
                    alert.addAction(UIAlertAction(title: "무시하고 방문", style: .destructive) { _ in
                        if let serverTrust = challenge.protectionSpace.serverTrust {
                            let credential = URLCredential(trust: serverTrust)
                            completionHandler(.useCredential, credential)
                            TabPersistenceManager.debugMessages.append("🔓 SSL 인증서 사용자 허용: \(host)")
                        } else {
                            completionHandler(.performDefaultHandling, nil)
                        }
                    })
                    
                    // 취소 (안전한 선택)
                    alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                        completionHandler(.cancelAuthenticationChallenge, nil)
                        TabPersistenceManager.debugMessages.append("🚫 SSL 인증서 사용자 거부: \(host)")
                        
                        // ✨ SSL 에러 알림 전송
                        if let tabID = self.parent.stateModel.tabID {
                            NotificationCenter.default.post(
                                name: .webViewDidFailLoad,
                                object: nil,
                                userInfo: [
                                    "tabID": tabID.uuidString,
                                    "sslError": true,
                                    "url": "https://\(host)"
                                ]
                            )
                        }
                    })
                    
                    topVC.present(alert, animated: true)
                }
                return
            }
            
            // 다른 인증 방법은 기본 처리
            completionHandler(.performDefaultHandling, nil)
        }

        // ✨ 최상위 뷰컨트롤러 찾기 (SSL 알림용)
        private func topMostViewController() -> UIViewController? {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first,
                  let root = window.rootViewController else { return nil }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            return top
        }

        // MARK: 팝업(새창) → 현재 탭에서 열기
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
                TabPersistenceManager.debugMessages.append("🆕 팝업 → 현재 탭: \(url.absoluteString)")
            }
            return nil
        }

        // MARK: - 다운로드 진행률 오버레이

        func installDownloadOverlay(on webView: WKWebView) {
            guard overlayContainer == nil else { return }

            let blur = UIBlurEffect(style: .systemThinMaterial)
            let container = UIVisualEffectView(effect: blur)
            container.translatesAutoresizingMaskIntoConstraints = false
            container.alpha = 0.0
            container.layer.cornerRadius = 10
            container.clipsToBounds = true

            let title = UILabel()
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = .preferredFont(forTextStyle: .caption1)
            title.textColor = .label
            title.text = "다운로드 준비 중..."

            let percent = UILabel()
            percent.translatesAutoresizingMaskIntoConstraints = false
            percent.font = .preferredFont(forTextStyle: .caption1)
            percent.textColor = .secondaryLabel
            percent.text = "0%"

            let progress = UIProgressView(progressViewStyle: .bar)
            progress.translatesAutoresizingMaskIntoConstraints = false
            progress.progress = 0.0

            container.contentView.addSubview(title)
            container.contentView.addSubview(percent)
            container.contentView.addSubview(progress)

            webView.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                container.trailingAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                container.topAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.topAnchor, constant: 12),

                title.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 12),
                title.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: 10),

                percent.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -12),
                percent.centerYAnchor.constraint(equalTo: title.centerYAnchor),

                progress.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 12),
                progress.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -12),
                progress.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
                progress.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -10),
                progress.heightAnchor.constraint(equalToConstant: 3)
            ])

            overlayContainer = container
            overlayTitleLabel = title
            overlayPercentLabel = percent
            overlayProgress = progress
        }

        private func showOverlay(filename: String?) {
            overlayTitleLabel?.text = filename ?? "다운로드 중"
            overlayPercentLabel?.text = "0%"
            overlayProgress?.setProgress(0.0, animated: false)
            UIView.animate(withDuration: 0.2) { self.overlayContainer?.alpha = 1.0 }
        }

        private func updateOverlay(progress: Double) {
            overlayProgress?.setProgress(Float(progress), animated: true)
            let pct = max(0, min(100, Int(progress * 100)))
            overlayPercentLabel?.text = "\(pct)%"
        }

        private func hideOverlay() {
            UIView.animate(withDuration: 0.2) { self.overlayContainer?.alpha = 0.0 }
        }

        // MARK: 다운로드 이벤트 핸들러
        @objc func handleDownloadStart(_ note: Notification) {
            let filename = note.userInfo?["filename"] as? String
            showOverlay(filename: filename)
        }

        @objc func handleDownloadProgress(_ note: Notification) {
            let progress = note.userInfo?["progress"] as? Double ?? 0
            updateOverlay(progress: progress)
        }

        @objc func handleDownloadFinish(_ note: Notification) {
            hideOverlay()
        }

        @objc func handleDownloadFailed(_ note: Notification) {
            hideOverlay()
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

// MARK: - CookieSyncManager (쿠키 세션 공유)
enum CookieSyncManager {
    static func syncAppToWebView(_ webView: WKWebView, completion: (() -> Void)? = nil) {
        let appCookies = HTTPCookieStorage.shared.cookies ?? []
        guard !appCookies.isEmpty else { completion?(); return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        appCookies.forEach { cookie in
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { completion?() }
    }

    static func syncWebToApp(_ store: WKHTTPCookieStore, completion: (() -> Void)? = nil) {
        store.getAllCookies { cookies in
            let appStorage = HTTPCookieStorage.shared
            cookies.forEach { appStorage.setCookie($0) }
            completion?()
        }
    }
}

// MARK: - 전역 쿠키 동기화 추적
private let _cookieSyncInstalledModels = NSHashTable<AnyObject>.weakObjects()

// MARK: - WebViewStateModel 확장 (CustomWebView 연동용)
extension WebViewStateModel {
    /// CustomWebView에서 사용하는 isNavigatingFromWebView 플래그 제어
    func setNavigatingFromWebView(_ value: Bool) {
        isNavigatingFromWebView = value
    }
}

// MARK: - WebViewStateModel 확장 (쿠키 세션 공유)
extension WebViewStateModel {
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        _installCookieSyncIfNeeded(for: webView)
        CookieSyncManager.syncAppToWebView(webView, completion: nil)
    }

    private func _installCookieSyncIfNeeded(for webView: WKWebView) {
        if _cookieSyncInstalledModels.contains(self) { return }
        _cookieSyncInstalledModels.add(self)

        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.add(self)

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSHTTPCookieManagerCookiesChanged"),
            object: HTTPCookieStorage.shared,
            queue: .main
        ) { [weak webView] _ in
            guard let webView = webView else { return }
            CookieSyncManager.syncAppToWebView(webView, completion: nil)
            if let host = webView.url?.host {
                TabPersistenceManager.debugMessages.append("🍪 App→Web 쿠키 동기화(\(host))")
            }
        }
        if let host = webView.url?.host {
            TabPersistenceManager.debugMessages.append("🍪 쿠키 동기화 설치됨(\(host))")
        }
    }
}

extension WebViewStateModel: WKHTTPCookieStoreObserver {
    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        CookieSyncManager.syncWebToApp(cookieStore) {
            TabPersistenceManager.debugMessages.append("🍪 Web→App 쿠키 동기화 완료")
        }
    }
}

// MARK: - 파일 다운로드 지원 (iOS 14+)
private final class DownloadCoordinator {
    static let shared = DownloadCoordinator()
    private init() {}
    private var map = [ObjectIdentifier: URL]()
    func set(url: URL, for download: WKDownload) { map[ObjectIdentifier(download)] = url }
    func url(for download: WKDownload) -> URL? { map[ObjectIdentifier(download)] }
    func remove(_ download: WKDownload) { map.removeValue(forKey: ObjectIdentifier(download)) }
}

private func sanitizedFilename(_ name: String) -> String {
    var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    result = result.components(separatedBy: forbidden).joined(separator: "_")
    if result.count > 150 {
        result = String(result.prefix(150))
    }
    return result.isEmpty ? "download" : result
}

private func topMostViewController() -> UIViewController? {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let root = window.rootViewController else { return nil }
    var top = root
    while let presented = top.presentedViewController { top = presented }
    return top
}

// MARK: - WebViewStateModel: WKDownloadDelegate
extension WebViewStateModel: WKDownloadDelegate {
    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         decideDestinationUsing response: URLResponse,
                         suggestedFilename: String,
                         completionHandler: @escaping (URL?) -> Void) {

        NotificationCenter.default.post(name: .WebViewDownloadStart,
                                        object: nil,
                                        userInfo: ["filename": suggestedFilename])

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsDir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let safeName = sanitizedFilename(suggestedFilename)
        let dst = downloadsDir.appendingPathComponent(safeName)

        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
        }

        DownloadCoordinator.shared.set(url: dst, for: download)
        completionHandler(dst)
        TabPersistenceManager.debugMessages.append("⬇️ 다운로드 저장 경로: \(dst.lastPathComponent)")
    }

    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         didWriteData bytesWritten: Int64,
                         totalBytesWritten: Int64,
                         totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        
        NotificationCenter.default.post(name: .WebViewDownloadProgress,
                                        object: nil,
                                        userInfo: ["progress": progress])
    }

    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         didFailWithError error: Error,
                         resumeData: Data?) {
        let filename = DownloadCoordinator.shared.url(for: download)?.lastPathComponent ?? "파일"
        DownloadCoordinator.shared.remove(download)

        NotificationCenter.default.post(name: .WebViewDownloadFailed, object: nil)

        DispatchQueue.main.async {
            if let top = topMostViewController() {
                let alert = UIAlertController(title: "다운로드 실패",
                                              message: "\(filename) 다운로드 중 오류가 발생했습니다.\n\(error.localizedDescription)",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "확인", style: .default))
                top.present(alert, animated: true)
            }
        }
        TabPersistenceManager.debugMessages.append("❌ 다운로드 실패: \(error.localizedDescription)")
    }

    @available(iOS 14.0, *)
    public func downloadDidFinish(_ download: WKDownload) {
        guard let fileURL = DownloadCoordinator.shared.url(for: download) else {
            TabPersistenceManager.debugMessages.append("⚠️ 다운로드 완료했지만 파일 경로를 찾을 수 없음")
            NotificationCenter.default.post(name: .WebViewDownloadFinish, object: nil)
            return
        }
        DownloadCoordinator.shared.remove(download)

        NotificationCenter.default.post(name: .WebViewDownloadFinish, object: nil)

        DispatchQueue.main.async {
            guard let top = topMostViewController() else { return }
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activityVC.popoverPresentationController?.sourceView = top.view
            top.present(activityVC, animated: true)
        }
        TabPersistenceManager.debugMessages.append("✅ 다운로드 완료: \(fileURL.lastPathComponent)")
    }
}