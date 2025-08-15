//
//  WebViewHelpers.swift
//  오디오, 에러페이지, 인증서, 파일 업다운, 데스크탑모드, 쿠키 구현체들
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import Foundation
import Security

// MARK: - 다운로드 진행 알림 이름 정의
extension Notification.Name {
    static let WebViewDownloadStart    = Notification.Name("WebViewDownloadStart")
    static let WebViewDownloadProgress = Notification.Name("WebViewDownloadProgress")
    static let WebViewDownloadFinish   = Notification.Name("WebViewDownloadFinish")
    static let WebViewDownloadFailed   = Notification.Name("WebViewDownloadFailed")
}

// MARK: - 오디오 관리 구현체
func configureAudioSessionForMixing() {
    // SilentAudioPlayer 사용하여 통합 관리
    _ = SilentAudioPlayer.shared
}

func deactivateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setActive(false, options: [.notifyOthersOnDeactivation])
}

// MARK: - 비디오 스크립트 구현체
func makeVideoScript() -> WKUserScript {
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

// MARK: - 데스크탑 모드 스크립트 구현체
func makeDesktopModeScript() -> WKUserScript {
    let scriptSource = """
    (function() {
        'use strict';
        
        window.desktopModeEnabled = false;
        window.desktopModeApplied = false;
        
        window.toggleDesktopMode = function(enabled) {
            window.desktopModeEnabled = enabled;
            
            if (enabled && !window.desktopModeApplied) {
                applyDesktopMode();
            } else if (!enabled && window.desktopModeApplied) {
                removeDesktopMode();
            }
        };
        
        function applyDesktopMode() {
            if (window.desktopModeApplied) return;
            window.desktopModeApplied = true;
            
            Object.defineProperty(screen, 'width', { 
                get: function() { return 1920; },
                configurable: false
            });
            Object.defineProperty(screen, 'height', { 
                get: function() { return 1080; },
                configurable: false
            });
            
            Object.defineProperty(window, 'innerWidth', { 
                get: function() { return 1920; },
                configurable: false
            });
            Object.defineProperty(window, 'innerHeight', { 
                get: function() { return 1080; },
                configurable: false
            });
            
            Object.defineProperty(window, 'ontouchstart', { 
                get: function() { return undefined; },
                configurable: false
            });
            
            setupZoomFunction();
            console.log('✅ 데스크탑 모드 적용 완료');
        }
        
        function setupZoomFunction() {
            window.setPageZoom = function(scale) {
                scale = Math.max(0.3, Math.min(3.0, scale));
                
                requestAnimationFrame(() => {
                    document.body.style.transform = `scale(${scale})`;
                    document.body.style.transformOrigin = '0 0';
                    document.body.style.width = `${100/scale}%`;
                    document.body.style.height = `${100/scale}%`;
                    
                    window.currentZoomLevel = scale;
                    
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.setZoom) {
                        window.webkit.messageHandlers.setZoom.postMessage({
                            zoom: scale,
                            action: 'update'
                        });
                    }
                });
            };
        }
        
        console.log('✅ 데스크탑 모드 스크립트 로드됨');
    })();
    """
    return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
}

// MARK: - 데스크탑 모드 관리 구현체
func updateUserAgentIfNeeded(webView: WKWebView, stateModel: WebViewStateModel) {
    if stateModel.isDesktopMode {
        let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        webView.customUserAgent = desktopUA
    } else {
        webView.customUserAgent = nil
    }
}

func updateDesktopModeIfNeeded(webView: WKWebView, stateModel: WebViewStateModel, lastDesktopMode: inout Bool) {
    updateUserAgentIfNeeded(webView: webView, stateModel: stateModel)
    
    if stateModel.isDesktopMode != lastDesktopMode {
        lastDesktopMode = stateModel.isDesktopMode
        
        let script = "if (window.toggleDesktopMode) { window.toggleDesktopMode(\(stateModel.isDesktopMode)); }"
        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                print("데스크탑 모드 토글 실패: \(error)")
            }
        }
    }
}

// MARK: - SSL 인증서 처리 구현체
func handleSSLChallenge(webView: WKWebView, challenge: URLAuthenticationChallenge, stateModel: WebViewStateModel?, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    let host = challenge.protectionSpace.host

    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)

        if isValid {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
            return
        }

        DispatchQueue.main.async {
            guard let topVC = topMostViewController() else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let alert = UIAlertController(
                title: "보안 연결 경고", 
                message: "\(host)의 보안 인증서에 문제가 있습니다.\n\n• 인증서가 만료되었거나\n• 자체 서명된 인증서이거나\n• 신뢰할 수 없는 기관에서 발급되었습니다.\n\n그래도 계속 방문하시겠습니까?",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "무시하고 방문", style: .destructive) { _ in
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
            })

            alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
                completionHandler(.cancelAuthenticationChallenge, nil)

                if let tabID = stateModel?.tabID {
                    NotificationCenter.default.post(
                        name: Notification.Name("webViewDidFailLoad"),
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
    completionHandler(.performDefaultHandling, nil)
}

func topMostViewController() -> UIViewController? {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let root = window.rootViewController else { return nil }
    var top = root
    while let presented = top.presentedViewController { top = presented }
    return top
}

// MARK: - 파일 업다운로드 구현체
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

// MARK: - 다운로드 오버레이 구현체
func installDownloadOverlay(on webView: WKWebView, overlayContainer: inout UIVisualEffectView?, overlayTitleLabel: inout UILabel?, overlayPercentLabel: inout UILabel?, overlayProgress: inout UIProgressView?) {
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

func showOverlay(filename: String?, overlayContainer: UIVisualEffectView?, overlayTitleLabel: UILabel?, overlayPercentLabel: UILabel?, overlayProgress: UIProgressView?) {
    overlayTitleLabel?.text = filename ?? "다운로드 중"
    overlayPercentLabel?.text = "0%"
    overlayProgress?.setProgress(0.0, animated: false)
    UIView.animate(withDuration: 0.2) { overlayContainer?.alpha = 1.0 }
}

func updateOverlay(progress: Double, overlayProgress: UIProgressView?, overlayPercentLabel: UILabel?) {
    overlayProgress?.setProgress(Float(progress), animated: true)
    let pct = max(0, min(100, Int(progress * 100)))
    overlayPercentLabel?.text = "\(pct)%"
}

func hideOverlay(overlayContainer: UIVisualEffectView?) {
    UIView.animate(withDuration: 0.2) { overlayContainer?.alpha = 0.0 }
}

// MARK: - 투명 처리 구현체
func setupTransparentWebView(_ webView: WKWebView) {
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.isOpaque = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never 
    webView.scrollView.keyboardDismissMode = .interactive
    webView.scrollView.contentInset = .zero
    webView.scrollView.scrollIndicatorInsets = .zero
}

func maintainTransparentWebView(_ webView: WKWebView) {
    if webView.isOpaque { webView.isOpaque = false }
    if webView.backgroundColor != .clear { webView.backgroundColor = .clear }
    if webView.scrollView.backgroundColor != .clear { webView.scrollView.backgroundColor = .clear }
    webView.scrollView.isOpaque = false
}

// MARK: - Pull to Refresh 구현체
func setupPullToRefresh(for webView: WKWebView, target: Any, action: Selector) {
    let refreshControl = UIRefreshControl()
    refreshControl.addTarget(target, action: action, for: .valueChanged)
    webView.scrollView.refreshControl = refreshControl
}

@objc func handleRefresh(_ sender: UIRefreshControl, webView: WKWebView?) {
    webView?.reload()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        sender.endRefreshing()
    }
}

// MARK: - 쿠키 동기화 구현체
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
