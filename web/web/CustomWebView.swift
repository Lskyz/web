import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers // 파일 선택을 위한 UTType 사용

// MARK: - CustomWebView (단순화된 시스템)
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    var onScroll: ((CGFloat) -> Void)? = nil

    // MARK: - Coordinator 생성
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - makeUIView (단순화)
    func makeUIView(context: Context) -> WKWebView {
        // ✅ 오디오 세션 활성화 (다른 앱 오디오와 믹싱 허용)
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
        controller.addUserScript(makeVideoScript()) // 함수명 일치
        controller.add(context.coordinator, name: "playVideo") // JS → 네이티브 메시지 핸들러 등록

        // ✨ 추가: HTML/CSS 배경을 강제 투명화하는 스크립트
        controller.addUserScript(makeTransparentBackgroundScript())

        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.decelerationRate = .normal

        // ✨ 추가: WKWebView 자체를 진짜 투명으로
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isOpaque = false

        // ✨ 추가: 자동 인셋을 끄고(흰 띠 방지) 모든 인셋 0으로
        // (위에서 .automatic을 썼지만, 여기서 끄는 건 "추가"로서 override만 함)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero

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

        // ✅ 오디오 세션 비활성화 추가
        coordinator.parent.deactivateAudioSession()

        // 메시지 핸들러 제거
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "playVideo")

        // NotificationCenter 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
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

    // MARK: - ✨ 추가: HTML/CSS 배경을 완전히 투명화하는 스크립트
    private func makeTransparentBackgroundScript() -> WKUserScript {
        let css = """
        html, body {
            background: transparent !important;
            background-color: transparent !important;
        }
        """
        let js = """
        (function(){
            try {
                var style = document.createElement('style');
                style.type = 'text/css';
                style.appendChild(document.createTextNode(`\(css)`));
                document.documentElement.appendChild(style);
            } catch (e) {}
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
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

    // JS → 네이티브: 비디오 클릭 시 AVPlayer로 재생
    class Coordinator: NSObject, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        var parent: CustomWebView
        weak var webView: WKWebView?
        var filePicker: FilePicker? // 강한 참조 유지용

        init(_ parent: CustomWebView) { self.parent = parent }

        // WKScriptMessageHandler: JS에서 보낸 메시지 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "playVideo" else { return }
            if let urlString = message.body as? String, let url = URL(string: urlString) {
                DispatchQueue.main.async {
                    self.parent.playerURL = url
                    self.parent.showAVPlayer = true
                }
            }
        }

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

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
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

        // 파일 업로드 처리 (iOS 버전 - 강한 참조 유지)
        @available(iOS 14.0, *)
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: Any, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            DispatchQueue.main.async {
                let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
                documentPicker.allowsMultipleSelection = true
                
                // 강한 참조 유지
                self.filePicker = FilePicker(completionHandler: { urls in
                    completionHandler(urls)
                    self.filePicker = nil // 완료 후 해제
                })
                documentPicker.delegate = self.filePicker
                
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
                    self.filePicker = nil
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

///////////////////////////////////////////////////////////////
// 🔽🔽🔽 여기부터 "추가" 코드 (위 코드 일절 수정 X) 🔽🔽🔽
///////////////////////////////////////////////////////////////

import Foundation

// MARK: - CookieSyncManager
/// WKWebView의 `WKHTTPCookieStore`와 app 전역 `HTTPCookieStorage.shared`를
/// 양방향으로 동기화하여 **세션/로그인 쿠키를 공유**하기 위한 헬퍼.
/// - 설계 포인트:
///   - 위쪽 기존 코드에 손대지 않기 위해, `WebViewStateModel`의 네비게이션 이벤트 훅을 이용(아래 extension 참조)
///   - 여러 WebView 인스턴스가 생겨도 전역 스토리지와 동기화되도록 구현
enum CookieSyncManager {
    /// App → WebView 로 쿠키 밀어넣기
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

    /// WebView → App 으로 쿠키 끌어오기
    static func syncWebToApp(_ store: WKHTTPCookieStore, completion: (() -> Void)? = nil) {
        store.getAllCookies { cookies in
            let appStorage = HTTPCookieStorage.shared
            cookies.forEach { appStorage.setCookie($0) }
            completion?()
        }
    }
}

// MARK: - 전역 Weak-Set: 쿠키 동기화가 설치된 모델 추적
/// 동일 모델에 중복 설치 방지(강한참조 방지 위해 weakObjects 사용)
private let _cookieSyncInstalledModels = NSHashTable<AnyObject>.weakObjects()

// MARK: - WebViewStateModel 확장 (쿠키 세션 공유 설치 훅)
/// ⚠️ 주의: 여기서는 **기존 WebViewStateModel 선언을 전혀 수정하지 않고**,  
/// 확장을 통해 네비게이션 이벤트 지점에서 쿠키 동기화를 "설치"한다.
/// 이미 동일 메서드를 구현해두었다면 충돌을 피하기 위해 아래 메서드들을 그대로 두거나 이름이 다른 메서드(예: didCommit)를 사용.
/// 일반적으로 didCommit은 많이 구현하지 않으므로 충돌 가능성 ↓
extension WebViewStateModel {

    /// didCommit 시점에 1회 쿠키 동기화 설치
    /// - 웹 컨텐츠가 로딩을 시작하면 전역 <-> WebView 쿠키를 즉시 1회 동기화
    /// - 이후에는 스토어 변경 이벤트 기반으로 자동 동기화
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        _installCookieSyncIfNeeded(for: webView)
        // 최초 1회: App → WebView 동기화(로그인 상태 즉시 반영)
        CookieSyncManager.syncAppToWebView(webView, completion: nil)
    }

    // 쿠키 동기화 설치(중복 방지)
    private func _installCookieSyncIfNeeded(for webView: WKWebView) {
        if _cookieSyncInstalledModels.contains(self) { return }
        _cookieSyncInstalledModels.add(self)

        // (1) WebView 측 쿠키 변경을 감시하여 App 전역 스토리지로 반영
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.add(self as! WKHTTPCookieStoreObserver) // 아래에서 프로토콜 채택

        // (2) App 전역 쿠키 변경을 감시하여 WebView로 반영
        NotificationCenter.default.addObserver(
            forName: HTTPCookieStorage.cookiesDidChangeNotification,
            object: HTTPCookieStorage.shared,
            queue: .main
        ) { [weak self, weak webView] _ in
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

// MARK: - WebViewStateModel: WKHTTPCookieStoreObserver 구현
/// WebView의 쿠키가 바뀔 때마다 호출 → App 전역 쿠키로 반영
extension WebViewStateModel: WKHTTPCookieStoreObserver {
    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        CookieSyncManager.syncWebToApp(cookieStore) {
            TabPersistenceManager.debugMessages.append("🍪 Web→App 쿠키 동기화 완료")
        }
    }
}

///////////////////////////////////////////////////////////////
// MARK: - 파일 다운로드 지원 (iOS 14+ WKDownload)
///////////////////////////////////////////////////////////////

/// 다운로드 목적지 기록(다운로드 객체 ↔︎ 파일 URL 매핑)
private final class DownloadCoordinator {
    static let shared = DownloadCoordinator()
    private init() {}
    private var map = [ObjectIdentifier: URL]()
    func set(url: URL, for download: WKDownload) {
        map[ObjectIdentifier(download)] = url
    }
    func url(for download: WKDownload) -> URL? {
        map[ObjectIdentifier(download)]
    }
    func remove(_ download: WKDownload) {
        map.removeValue(forKey: ObjectIdentifier(download))
    }
}

/// 파일명 안전화: 경로 구분자/제어문자 제거
private func sanitizedFilename(_ name: String) -> String {
    var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
    // 금지 문자 제거
    let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    result = result.components(separatedBy: forbidden).joined(separator: "_")
    // 너무 긴 파일명 방지
    if result.count > 150 {
        let end = result.index(result.startIndex, offsetBy: 150)
        result = String(result[..<end])
    }
    return result.isEmpty ? "download" : result
}

/// 최상위 표시 가능한 뷰컨트롤러 추출(공유시트/알림표시용)
private func topMostViewController() -> UIViewController? {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let root = window.rootViewController else { return nil }
    var top = root
    while let presented = top.presentedViewController { top = presented }
    return top
}

/// iOS 14+ WKDownload 를 이용한 파일 다운로드 구현
extension WebViewStateModel {

    /// (중요) Content-Disposition: attachment 응답은 **다운로드로 전환**
    /// 기존 동작과 충돌을 피하기 위해, 일반 케이스는 건드리지 않고 "첨부 응답"만 다운로드 처리.
    @available(iOS 14.0, *)
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disp = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disp.contains("attachment") {
            decisionHandler(.download) // ✅ 다운로드로 전환
            return
        }
        decisionHandler(.allow)
    }

    /// 응답이 다운로드로 전환되었을 때 호출 → WKDownload delegate 연결
    @available(iOS 14.0, *)
    public func webView(_ webView: WKWebView,
                        navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        download.delegate = self as? WKDownloadDelegate
    }

    /// (선택) iOS 14.5+: 사용자가 "다운로드로 수행"해야 하는 액션 지원
    /// 이미 구현되어 있는 경우를 고려해 여기서는 생략해도 충분하지만,
    /// 필요 시 아래 주석을 해제해서 사용할 수 있음.
    /*
    @available(iOS 14.5, *)
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    @available(iOS 14.5, *)
    public func webView(_ webView: WKWebView,
                        navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        download.delegate = self as? WKDownloadDelegate
    }
    */
}

// MARK: - WebViewStateModel: WKDownloadDelegate 구현
extension WebViewStateModel: WKDownloadDelegate {

    /// 저장 위치 결정: Documents/Downloads/ 하위에 제안된 파일명으로 저장
    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         decideDestinationUsing response: URLResponse,
                         suggestedFilename: String,
                         completionHandler: @escaping (URL?) -> Void) {

        // 저장 폴더 생성 (Documents/Downloads)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsDir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        // 파일명 안전화
        let safeName = sanitizedFilename(suggestedFilename)
        let dst = downloadsDir.appendingPathComponent(safeName)

        // 기존 파일이 있으면 제거(덮어쓰기)
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
        }

        // 목적지 기록(완료 시 공유시트 노출 위해)
        DownloadCoordinator.shared.set(url: dst, for: download)

        completionHandler(dst)
        TabPersistenceManager.debugMessages.append("⬇️ 다운로드 저장 경로 결정: \(dst.lastPathComponent)")
    }

    /// 다운로드 진행 상황(필요 시 로깅/프로그레스 바 연결 가능)
    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         didWriteData bytesWritten: Int64,
                         totalBytesWritten: Int64,
                         totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        TabPersistenceManager.debugMessages.append(String(format: "⬇️ 다운로드 진행률: %.0f%%", progress * 100))
    }

    /// 다운로드 실패 처리
    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         didFailWithError error: Error,
                         resumeData: Data?) {
        let filename = DownloadCoordinator.shared.url(for: download)?.lastPathComponent ?? "파일"
        DownloadCoordinator.shared.remove(download)

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

    /// 다운로드 완료: 공유 시트(파일 앱 저장/다른 앱 열기 등) 표시
    @available(iOS 14.0, *)
    public func downloadDidFinish(_ download: WKDownload) {
        guard let fileURL = DownloadCoordinator.shared.url(for: download) else {
            TabPersistenceManager.debugMessages.append("⚠️ 다운로드 완료했지만 파일 경로를 찾을 수 없음")
            return
        }
        DownloadCoordinator.shared.remove(download)

        DispatchQueue.main.async {
            guard let top = topMostViewController() else { return }
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activityVC.popoverPresentationController?.sourceView = top.view
            top.present(activityVC, animated: true)
        }
        TabPersistenceManager.debugMessages.append("✅ 다운로드 완료: \(fileURL.lastPathComponent)")
    }
}