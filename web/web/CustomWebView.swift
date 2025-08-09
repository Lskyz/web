//
//  CustomWebView.swift
//
//  ✅ 전체 주석 포함 / 불필요한 부분 수정 없이 기능만 추가
//  - WebView: 비디오 클릭 시 AVPlayer 재생, 배경 투명 처리, Pull-to-Refresh 등
//  - 쿠키 세션 공유: WKHTTPCookieStore ↔︎ HTTPCookieStorage 동기화
//  - 파일 다운로드: iOS 14+ WKDownload 사용 (Content-Disposition: attachment 처리)
//  - 다운로드 진행률 UI: CustomWebView 내부에 상단 오버레이(블러 + 라벨 + Progress 바)
//  - 빌드 경고/에러 수정: as!, cookiesDidChangeNotification, as? 관련 정리
//
//  ⚠️ 메모리(기억) 안내: 이 코드를 자동으로 '기억'하진 못해요.
//  장기 저장 원하시면 앱/도구의 메모리 기능을 켜주세요.
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers   // 파일 선택을 위한 UTType 사용
import Foundation

// MARK: - 다운로드 진행 알림 이름 정의
/// WebViewStateModel(WKDownloadDelegate) → CustomWebView(Coordinator)로
/// 진행률 이벤트를 전달하기 위한 Notification 이름들
extension Notification.Name {
    static let WebViewDownloadStart    = Notification.Name("WebViewDownloadStart")
    static let WebViewDownloadProgress = Notification.Name("WebViewDownloadProgress")
    static let WebViewDownloadFinish   = Notification.Name("WebViewDownloadFinish")
    static let WebViewDownloadFailed   = Notification.Name("WebViewDownloadFailed")
}

// MARK: - CustomWebView (UIViewRepresentable)
/// SwiftUI에서 사용할 WKWebView 래퍼.
/// 내부적으로 WKWebView 위에 다운로드 진행률 UI(블러 + 라벨 + ProgressView)를 오버레이로 올림.
struct CustomWebView: UIViewRepresentable {
    // 외부에서 주입되는 상태 모델(네비게이션 델리게이트 용도)
    @ObservedObject var stateModel: WebViewStateModel
    // AVPlayer 재생을 위한 바인딩 (비디오 클릭 시 세팅됨)
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool

    // 외부로 스크롤 Y를 전달하고 싶을 때 사용하는 콜백 (선택)
    var onScroll: ((CGFloat) -> Void)? = nil

    // Coordinator 생성
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - makeUIView
    /// WKWebView + 다운로드 오버레이 UI를 구성
    func makeUIView(context: Context) -> WKWebView {
        // ✅ 오디오 세션 활성화 (다른 앱 오디오와 믹싱 허용)
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
        controller.addUserScript(makeVideoScript())                          // 비디오 처리 스크립트
        controller.add(context.coordinator, name: "playVideo")               // JS → 네이티브 메시지 핸들러
        controller.addUserScript(makeTransparentBackgroundScript())          // HTML/CSS 배경 투명화
        config.userContentController = controller

        // WKWebView 생성
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.decelerationRate = .normal

        // WKWebView 자체를 투명 처리 (배경이 비치도록)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isOpaque = false
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = .clear   // ✅ 핵심 추가: 흰 under-page 배경 제거
        }

        // 흰 띠 방지: 인셋 제거
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero

        // Delegate 연결
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

        // 초기 로드
        if let url = stateModel.currentURL {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("🌐 초기 URL 로드: \(url.absoluteString)")
        } else {
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            TabPersistenceManager.debugMessages.append("🌐 빈 페이지 로드")
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

        // 🔽 다운로드 진행률 UI 오버레이 구성
        context.coordinator.installDownloadOverlay(on: webView)

        // 🔽 다운로드 관련 이벤트 옵저버 등록
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
        // 연결이 끊겼을 경우만 다시 연결 (불필요한 수정 방지)
        if uiView.uiDelegate !== context.coordinator {
            uiView.uiDelegate = context.coordinator
        }
        if uiView.navigationDelegate !== stateModel {
            uiView.navigationDelegate = stateModel
        }
        if context.coordinator.webView !== uiView {
            context.coordinator.webView = uiView
        }

        // ✅ 핵심 추가: 테마 전환/재사용 시에도 항상 투명 배경 유지 보증
        if uiView.isOpaque { uiView.isOpaque = false }
        if uiView.backgroundColor != .clear { uiView.backgroundColor = .clear }
        if uiView.scrollView.backgroundColor != .clear { uiView.scrollView.backgroundColor = .clear }
        uiView.scrollView.isOpaque = false
        if #available(iOS 15.0, *) {
            if uiView.underPageBackgroundColor != .clear {
                uiView.underPageBackgroundColor = .clear
            }
        }
    }

    // MARK: - teardown
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // 스크롤/델리게이트 해제
        uiView.scrollView.delegate = nil
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil
        coordinator.webView = nil

        // 오디오 세션 비활성화
        coordinator.parent.deactivateAudioSession()

        // 메시지 핸들러 제거
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "playVideo")

        // 모든 옵저버 제거 (외부 제어 + 다운로드 이벤트)
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - 사용자 스크립트 (비디오 클릭 → AVPlayer로 재생 / PiP 시도)
    private func makeVideoScript() -> WKUserScript {
        let scriptSource = """
        function processVideos(doc) {
            [...doc.querySelectorAll('video')].forEach(video => {
                // iOS 자동재생 제약 회피: 기본 mute
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

                // 가능하면 PiP 자동 진입 시도(실패 무시)
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

    // MARK: - HTML/CSS 배경 투명화 스크립트
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

    // MARK: - Coordinator
    /// WKWebView UI 관련 델리게이트, 스크롤 이벤트, JS 메시지, 다운로드 UI 제어
    class Coordinator: NSObject, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler {

        // 부모와 웹뷰 참조
        var parent: CustomWebView
        weak var webView: WKWebView?

        // 파일 선택기(강한 참조 유지)
        var filePicker: FilePicker?

        // 다운로드 진행률 UI 구성 요소들 (오버레이)
        private var overlayContainer: UIVisualEffectView?
        private var overlayTitleLabel: UILabel?
        private var overlayPercentLabel: UILabel?
        private var overlayProgress: UIProgressView?

        init(_ parent: CustomWebView) { self.parent = parent }

        // MARK: JS → 네이티브 메시지 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "playVideo" else { return }
            if let urlString = message.body as? String, let url = URL(string: urlString) {
                DispatchQueue.main.async {
                    self.parent.playerURL = url
                    self.parent.showAVPlayer = true
                }
            }
        }

        // MARK: Pull to Refresh
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
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
        }

        // MARK: 네비게이션 명령
        @objc func reloadWebView() { webView?.reload() }
        @objc func goBack() { if webView?.canGoBack == true { webView?.goBack() } }
        @objc func goForward() { if webView?.canGoForward == true { webView?.goForward() } }

        // MARK: 스크롤 전달
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll?(scrollView.contentOffset.y)
        }

        // MARK: 팝업(새창) → 현재 탭에서 열기
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: - 다운로드 진행률 오버레이 설치/업데이트

        /// WKWebView 위에 블러 오버레이 + 타이틀 + 퍼센트 + 진행 바를 설치
        func installDownloadOverlay(on webView: WKWebView) {
            // 이미 설치되어 있으면 스킵
            guard overlayContainer == nil else { return }

            // 블러 컨테이너
            let blur = UIBlurEffect(style: .systemThinMaterial)
            let container = UIVisualEffectView(effect: blur)
            container.translatesAutoresizingMaskIntoConstraints = false
            container.alpha = 0.0          // 처음엔 숨김
            container.layer.cornerRadius = 10
            container.clipsToBounds = true

            // 상단 라벨들 (좌: 파일명, 우: 퍼센트)
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

            // 진행 바
            let progress = UIProgressView(progressViewStyle: .bar)
            progress.translatesAutoresizingMaskIntoConstraints = false
            progress.progress = 0.0

            // 컨테이너 서브뷰 구성
            container.contentView.addSubview(title)
            container.contentView.addSubview(percent)
            container.contentView.addSubview(progress)

            // 오토레이아웃 (컨테이너는 웹뷰 상단 안전영역에 고정)
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

            // 보관
            overlayContainer = container
            overlayTitleLabel = title
            overlayPercentLabel = percent
            overlayProgress = progress
        }

        /// 오버레이 표시 (파일명 설정)
        private func showOverlay(filename: String?) {
            overlayTitleLabel?.text = filename ?? "다운로드 중"
            overlayPercentLabel?.text = "0%"
            overlayProgress?.setProgress(0.0, animated: false)
            UIView.animate(withDuration: 0.2) { self.overlayContainer?.alpha = 1.0 }
        }

        /// 오버레이 진행률 업데이트
        private func updateOverlay(progress: Double) {
            overlayProgress?.setProgress(Float(progress), animated: true)
            let pct = max(0, min(100, Int(progress * 100)))
            overlayPercentLabel?.text = "\(pct)%"
        }

        /// 오버레이 숨김
        private func hideOverlay() {
            UIView.animate(withDuration: 0.2) { self.overlayContainer?.alpha = 0.0 }
        }

        // MARK: 다운로드 이벤트(Notification) 핸들러
        /// 시작: 파일명 수신 → 오버레이 표시
        @objc func handleDownloadStart(_ note: Notification) {
            let filename = note.userInfo?["filename"] as? String
            showOverlay(filename: filename)
        }

        /// 진행: 0~1.0 수신 → 진행률 갱신
        @objc func handleDownloadProgress(_ note: Notification) {
            let progress = note.userInfo?["progress"] as? Double ?? 0
            updateOverlay(progress: progress)
        }

        /// 완료: 오버레이 숨김 (공유시트는 WKDownloadDelegate에서 표시됨)
        @objc func handleDownloadFinish(_ note: Notification) {
            hideOverlay()
        }

        /// 실패: 오버레이 숨김 (알림은 WKDownloadDelegate에서 표시됨)
        @objc func handleDownloadFailed(_ note: Notification) {
            hideOverlay()
        }
    }
}

// MARK: - 파일 선택 헬퍼 (UIDocumentPicker)
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

// MARK: - CookieSyncManager
/// WKWebView의 `WKHTTPCookieStore`와 app 전역 `HTTPCookieStorage.shared`를
/// 양방향으로 동기화하여 **세션/로그인 쿠키를 공유**하기 위한 헬퍼.
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

// MARK: - 전역 Weak-Set: 쿠키 동기화 설치된 모델 추적 (중복 방지)
private let _cookieSyncInstalledModels = NSHashTable<AnyObject>.weakObjects()

// MARK: - WebViewStateModel 확장 (쿠키 세션 공유 설치 훅)
/// ⚠️ 기존 WebViewStateModel 선언은 수정하지 않고, 확장으로 네비 이벤트 지점에 훅을 건다.
extension WebViewStateModel {

    /// didCommit 시점에 1회 쿠키 동기화 설치 + App→WebView 초기 동기화
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        _installCookieSyncIfNeeded(for: webView)
        CookieSyncManager.syncAppToWebView(webView, completion: nil)
    }

    // 쿠키 동기화 설치(중복 방지)
    private func _installCookieSyncIfNeeded(for webView: WKWebView) {
        if _cookieSyncInstalledModels.contains(self) { return }
        _cookieSyncInstalledModels.add(self)

        // WebView 측 쿠키 변경을 감시 → App 전역 스토리지로 반영
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.add(self) // ✅ 수정: 강제 캐스팅(as!) 제거

        // App 전역 쿠키 변경 감시 → WebView로 반영 (iOS: NSHTTPCookieManagerCookiesChanged 사용)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSHTTPCookieManagerCookiesChanged"), // ✅ 수정
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
// MARK: - 파일 다운로드 지원 (iOS 14+ WKDownload) + 진행률 UI 이벤트 송신
///////////////////////////////////////////////////////////////

/// 다운로드 목적지 기록(다운로드 객체 ↔︎ 파일 URL 매핑)
private final class DownloadCoordinator {
    static let shared = DownloadCoordinator()
    private init() {}
    private var map = [ObjectIdentifier: URL]()
    func set(url: URL, for download: WKDownload) { map[ObjectIdentifier(download)] = url }
    func url(for download: WKDownload) -> URL? { map[ObjectIdentifier(download)] }
    func remove(_ download: WKDownload) { map.removeValue(forKey: ObjectIdentifier(download)) }
}

/// 파일명 안전화: 경로 구분자/제어문자 제거 + 길이 제한
private func sanitizedFilename(_ name: String) -> String {
    var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    result = result.components(separatedBy: forbidden).joined(separator: "_")
    if result.count > 150 {
        result = String(result.prefix(150))
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

// MARK: - WKNavigationResponse → 다운로드 전환 / 다운로드 델리게이트 연결
extension WebViewStateModel {

    /// Content-Disposition: attachment 응답은 **다운로드로 전환**
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
        download.delegate = self // ✅ 수정: 불필요한 as? 제거
    }
}

// MARK: - WebViewStateModel: WKDownloadDelegate 구현
extension WebViewStateModel: WKDownloadDelegate {

    /// 저장 위치 결정: Documents/Downloads/ 하위에 제안된 파일명으로 저장 + 시작 이벤트 송신
    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         decideDestinationUsing response: URLResponse,
                         suggestedFilename: String,
                         completionHandler: @escaping (URL?) -> Void) {

        // UI에 시작 알림 (파일명 전달)
        NotificationCenter.default.post(name: .WebViewDownloadStart,
                                        object: nil,
                                        userInfo: ["filename": suggestedFilename])

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

    /// 다운로드 진행 상황 → 진행률 이벤트 송신
    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         didWriteData bytesWritten: Int64,
                         totalBytesWritten: Int64,
                         totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        TabPersistenceManager.debugMessages.append(String(format: "⬇️ 다운로드 진행률: %.0f%%", progress * 100))

        // UI에 진행률 알림 (0.0 ~ 1.0)
        NotificationCenter.default.post(name: .WebViewDownloadProgress,
                                        object: nil,
                                        userInfo: ["progress": progress])
    }

    /// 다운로드 실패 처리 → 실패 이벤트 송신 + Alert
    @available(iOS 14.0, *)
    public func download(_ download: WKDownload,
                         didFailWithError error: Error,
                         resumeData: Data?) {
        let filename = DownloadCoordinator.shared.url(for: download)?.lastPathComponent ?? "파일"
        DownloadCoordinator.shared.remove(download)

        // UI 업데이트 (실패 알림)
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

    /// 다운로드 완료: 공유 시트 표시 → 완료 이벤트 송신
    @available(iOS 14.0, *)
    public func downloadDidFinish(_ download: WKDownload) {
        guard let fileURL = DownloadCoordinator.shared.url(for: download) else {
            TabPersistenceManager.debugMessages.append("⚠️ 다운로드 완료했지만 파일 경로를 찾을 수 없음")
            NotificationCenter.default.post(name: .WebViewDownloadFinish, object: nil)
            return
        }
        DownloadCoordinator.shared.remove(download)

        // UI 업데이트 (완료 알림)
        NotificationCenter.default.post(name: .WebViewDownloadFinish, object: nil)

        // 공유 시트 표시
        DispatchQueue.main.async {
            guard let top = topMostViewController() else { return }
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activityVC.popoverPresentationController?.sourceView = top.view
            top.present(activityVC, animated: true)
        }
        TabPersistenceManager.debugMessages.append("✅ 다운로드 완료: \(fileURL.lastPathComponent)")
    }
}