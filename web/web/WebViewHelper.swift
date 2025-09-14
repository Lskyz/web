//
//  WebViewHelper.swift
//  CustomWebView의 모든 기능 구현체들을 완전 분리 + 통합된 파일 업다운로드 시스템
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

func handleWebViewRefresh(_ sender: UIRefreshControl, webView: WKWebView?) {
    webView?.reload()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        sender.endRefreshing()
    }
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

// MARK: - 🔧 터치 이벤트 제거된 이미지 저장 스크립트 (롱프레스 전용)
func makeImageSaveScript() -> WKUserScript {
    let scriptSource = #"""
    (function(){
      'use strict';
      
      // 전역 설치 중복 방지
      if (window.__IMG_SAVE_V3_INSTALLED__) return;
      window.__IMG_SAVE_V3_INSTALLED__ = true;
      
      // 디바운싱을 위한 상태
      let lastSaveTime = 0;
      const MIN_SAVE_INTERVAL = 500; // 최소 500ms 간격
      
      // 안전한 이미지 URL 검증
      function isValidImageUrl(url) {
        if (!url || typeof url !== 'string' || url.length === 0) return false;
        if (url.length > 10000) return false; // 너무 긴 URL 거부
        
        // data URL 체크
        if (url.startsWith('data:image/')) {
          const parts = url.split(',');
          if (parts.length !== 2) return false;
          if (parts[1].length < 10) return false; // 너무 짧은 데이터
          return true;
        }
        
        // 일반 URL 체크
        try {
          const parsedUrl = new URL(url, window.location.href);
          const ext = parsedUrl.pathname.split('.').pop()?.toLowerCase() || '';
          const imageExts = ['jpg','jpeg','png','gif','webp','bmp','svg','ico','tiff','tif'];
          return imageExts.includes(ext) || parsedUrl.pathname.includes('/image');
        } catch(e) {
          // URL 파싱 실패는 무시
          return false;
        }
      }
      
      // 안전한 부모 노드 탐색
      function hasAncestorTag(element, tagName, maxDepth = 10) {
        if (!element || !tagName) return false;
        let current = element;
        let depth = 0;
        
        while (current && depth < maxDepth) {
          try {
            if (current.tagName === tagName) return true;
            current = current.parentElement;
            depth++;
          } catch(e) {
            return false;
          }
        }
        return false;
      }
      
      // 실제 이미지 저장 요청
      function requestImageSave(url) {
        const now = Date.now();
        
        // 쓰로틀링: 너무 빠른 연속 호출 방지
        if (now - lastSaveTime < MIN_SAVE_INTERVAL) {
          console.log('⏳ 이미지 저장 요청 쓰로틀링');
          return;
        }
        
        lastSaveTime = now;
        
        // 메시지 핸들러 안전 호출
        try {
          if (window.webkit?.messageHandlers?.saveImage?.postMessage) {
            window.webkit.messageHandlers.saveImage.postMessage({ 
              url: url, 
              gesture: 'longpress',
              timestamp: now
            });
            console.log('📷 이미지 저장 요청 전송:', url.substring(0, 100));
          }
        } catch(e) {
          console.error('⚠️ 이미지 저장 메시지 전송 실패:', e.message);
        }
      }
      
      // 컨텍스트 메뉴 이벤트 핸들러 (롱프레스 전용)
      function handleContextMenu(event) {
        // 이벤트 기본 검증
        if (!event || !event.target) return;
        
        try {
          const target = event.target;
          
          // IMG 태그인지 확인
          if (target.tagName !== 'IMG') return;
          
          // 링크 안의 이미지는 제외 (깔끔한 체크)
          if (hasAncestorTag(target, 'A', 5)) {
            console.log('🔗 링크 내부 이미지 - 저장 스킵');
            return;
          }
          
          // 버튼 안의 이미지는 제외
          if (hasAncestorTag(target, 'BUTTON', 3)) {
            console.log('🔘 버튼 내부 이미지 - 저장 스킵');
            return;
          }
          
          // 이미지 URL 추출
          const imgUrl = target.currentSrc || target.src || target.getAttribute('data-src');
          
          // URL 유효성 검증
          if (!isValidImageUrl(imgUrl)) {
            console.log('❌ 유효하지 않은 이미지 URL');
            return;
          }
          
          // 크기 체크 (1x1 추적 픽셀 등 제외)
          if (target.naturalWidth <= 1 || target.naturalHeight <= 1) {
            console.log('🔍 너무 작은 이미지 - 저장 스킵');
            return;
          }
          
          // 이미지 저장 요청
          requestImageSave(imgUrl);
          
        } catch(err) {
          console.error('⚠️ 컨텍스트 메뉴 처리 중 오류:', err.message);
        }
      }
      
      // 이벤트 리스너 등록 - 컨텍스트 메뉴(롱프레스)만 처리
      try {
        // 컨텍스트 메뉴 (롱프레스) 이벤트만 처리
        document.addEventListener('contextmenu', handleContextMenu, { 
          capture: true, 
          passive: true 
        });
        
        console.log('✅ 이미지 저장 스크립트 V3 초기화 완료 (롱프레스 전용, 터치 이벤트 제거)');
      } catch(e) {
        console.error('⚠️ 이벤트 리스너 등록 실패:', e.message);
      }
      
    })();
    """#
    return WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
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
            guard let topVC = getTopViewController() else {
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

func getTopViewController() -> UIViewController? {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let root = window.rootViewController else { return nil }
    var top = root
    while let presented = top.presentedViewController { top = presented }
    return top
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

// MARK: - ===== 통합된 파일 업다운로드 시스템 =====

// MARK: - 파일 타입 감지 및 확장자 매핑
enum FileTypeDetector {
    
    // Content-Type과 확장자 매핑
    private static let contentTypeToExtension: [String: String] = [
        // ===== 문서 파일 =====
        "application/pdf": "pdf",
        "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/vnd.oasis.opendocument.text": "odt",
        "application/vnd.oasis.opendocument.spreadsheet": "ods",
        "application/vnd.oasis.opendocument.presentation": "odp",
        "text/plain": "txt",
        "text/csv": "csv",
        "application/rtf": "rtf",
        "application/epub+zip": "epub",
        "application/x-mobipocket-ebook": "mobi",
        "application/vnd.amazon.ebook": "azw",
        
        // ===== 이미지 파일 =====
        "image/jpeg": "jpg",
        "image/jpg": "jpg",
        "image/png": "png",
        "image/gif": "gif",
        "image/svg+xml": "svg",
        "image/webp": "webp",
        "image/bmp": "bmp",
        "image/x-ms-bmp": "bmp",
        "image/tiff": "tiff",
        "image/tif": "tiff",
        "image/heic": "heic",
        "image/heif": "heif",
        "image/avif": "avif",
        "image/x-icon": "ico",
        "image/vnd.microsoft.icon": "ico",
        "image/x-photoshop": "psd",
        "image/vnd.adobe.photoshop": "psd",
        "image/x-portable-pixmap": "ppm",
        "image/x-portable-graymap": "pgm",
        "image/x-portable-bitmap": "pbm",
        "image/x-portable-anymap": "pnm",
        
        // ===== 동영상 파일 =====
        "video/mp4": "mp4",
        "video/mpeg": "mpg",
        "video/avi": "avi",
        "video/quicktime": "mov",
        "video/x-msvideo": "avi",
        "video/x-ms-wmv": "wmv",
        "video/x-matroska": "mkv",
        "video/webm": "webm",
        "video/3gpp": "3gp",
        "video/3gpp2": "3g2",
        "video/x-flv": "flv",
        "video/mp2t": "ts",
        "video/x-m4v": "m4v",
        "application/x-mpegURL": "m3u8",
        "video/vnd.dlna.mpeg-tts": "ts",
        
        // ===== 오디오 파일 =====
        "audio/mpeg": "mp3",
        "audio/mp3": "mp3",
        "audio/wav": "wav",
        "audio/wave": "wav",
        "audio/x-wav": "wav",
        "audio/aac": "aac",
        "audio/x-aac": "aac",
        "audio/ogg": "ogg",
        "audio/vorbis": "ogg",
        "audio/flac": "flac",
        "audio/x-flac": "flac",
        "audio/x-ms-wma": "wma",
        "audio/mp4": "m4a",
        "audio/x-m4a": "m4a",
        "audio/amr": "amr",
        "audio/3gpp": "3ga",
        "audio/midi": "mid",
        "audio/x-midi": "midi",
        "audio/opus": "opus",
        
        // ===== 압축 파일 =====
        "application/zip": "zip",
        "application/x-zip-compressed": "zip",
        "application/x-rar-compressed": "rar",
        "application/vnd.rar": "rar",
        "application/x-7z-compressed": "7z",
        "application/gzip": "gz",
        "application/x-gzip": "gz",
        "application/x-tar": "tar",
        "application/x-bzip2": "bz2",
        "application/x-bzip": "bz",
        "application/x-xz": "xz",
        "application/x-lzip": "lz",
        "application/x-compress": "Z",
        "application/x-ace-compressed": "ace",
        "application/x-alz-compressed": "alz",
        "application/vnd.ms-cab-compressed": "cab",
        "application/x-deb": "deb",
        "application/x-rpm": "rpm",
        "application/x-stuffit": "sit",
        "application/x-stuffitx": "sitx",
        
        // ===== 프로그래밍 파일 =====
        "application/json": "json",
        "application/ld+json": "jsonld",
        "application/xml": "xml",
        "text/xml": "xml",
        "text/html": "html",
        "text/css": "css",
        "text/javascript": "js",
        "application/javascript": "js",
        "application/x-javascript": "js",
        "text/typescript": "ts",
        "application/x-php": "php",
        "text/x-python": "py",
        "text/x-java-source": "java",
        "text/x-c": "c",
        "text/x-c++": "cpp",
        "text/x-csharp": "cs",
        "text/x-swift": "swift",
        "text/x-ruby": "rb",
        "text/x-perl": "pl",
        "text/x-shellscript": "sh",
        "application/x-sql": "sql",
        "text/yaml": "yml",
        "application/x-yaml": "yaml",
        "application/toml": "toml",
        "text/x-ini": "ini",
        "text/x-properties": "properties",
        
        // ===== 실행 파일 =====
        "application/octet-stream": "bin",
        "application/x-msdownload": "exe",
        "application/x-executable": "exe",
        "application/x-msi": "msi",
        "application/x-debian-package": "deb",
        "application/x-redhat-package-manager": "rpm",
        "application/vnd.android.package-archive": "apk",
        "application/x-apple-diskimage": "dmg",
        "application/x-shockwave-flash": "swf",
        
        // ===== 폰트 파일 =====
        "font/ttf": "ttf",
        "font/otf": "otf",
        "font/woff": "woff",
        "font/woff2": "woff2",
        "application/font-woff": "woff",
        "application/font-woff2": "woff2",
        "application/vnd.ms-fontobject": "eot",
        "font/collection": "ttc",
        
        // ===== 3D 모델 파일 =====
        "model/gltf+json": "gltf",
        "model/gltf-binary": "glb",
        "model/obj": "obj",
        "model/stl": "stl",
        "model/ply": "ply",
        "model/x3d+xml": "x3d",
        "model/3mf": "3mf",
        
        // ===== 기타 특수 형식 =====
        "application/vnd.sqlite3": "sqlite",
        "application/x-sqlite3": "db",
        "application/postscript": "ps",
        "application/x-dvi": "dvi",
        "application/x-latex": "latex",
        "application/x-tex": "tex",
        "application/mathematica": "nb",
        "application/vnd.wolfram.mathematica": "nb",
        "application/vnd.wolfram.cdf": "cdf",
        "application/x-iwork-keynote-sffkey": "key",
        "application/x-iwork-numbers-sffnumbers": "numbers",
        "application/x-iwork-pages-sffpages": "pages",
        "application/vnd.google-earth.kml+xml": "kml",
        "application/vnd.google-earth.kmz": "kmz",
        "application/gpx+xml": "gpx",
        "application/x-subrip": "srt",
        "text/vtt": "vtt",
        "application/x-ass": "ass",
        "text/x-ssa": "ssa"
    ]
    
    // 파일 확장자로부터 MIME 타입 추측
    private static let extensionToContentType: [String: String] = Dictionary(
        uniqueKeysWithValues: contentTypeToExtension.map { ($0.value, $0.key) }
    )
    
    // 파일 시그니처 (매직 넘버) 감지
    private static let fileSignatures: [String: [UInt8]] = [
        // ===== 이미지 파일 =====
        "png": [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], // PNG
        "jpg": [0xFF, 0xD8, 0xFF], // JPEG
        "gif": [0x47, 0x49, 0x46, 0x38], // GIF87a/89a
        "bmp": [0x42, 0x4D], // BMP
        "tiff": [0x49, 0x49, 0x2A, 0x00], // TIFF (little endian)
        "tif": [0x4D, 0x4D, 0x00, 0x2A], // TIFF (big endian)
        "webp": [0x57, 0x45, 0x42, 0x50], // WEBP (offset 8)
        "ico": [0x00, 0x00, 0x01, 0x00], // ICO
        "psd": [0x38, 0x42, 0x50, 0x53], // PSD
        
        // ===== 문서 파일 =====
        "pdf": [0x25, 0x50, 0x44, 0x46], // %PDF
        "doc": [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], // MS Office 97-2003
        "docx": [0x50, 0x4B, 0x03, 0x04], // Office 2007+ (ZIP-based)
        "rtf": [0x7B, 0x5C, 0x72, 0x74, 0x66], // {\rtf
        "eps": [0x25, 0x21, 0x50, 0x53], // %!PS
        
        // ===== 압축 파일 =====
        "zip": [0x50, 0x4B, 0x03, 0x04], // ZIP
        "rar": [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], // RAR
        "7z": [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], // 7-Zip
        "gz": [0x1F, 0x8B], // GZIP
        "bz2": [0x42, 0x5A, 0x68], // BZIP2
        "xz": [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], // XZ
        "cab": [0x4D, 0x53, 0x43, 0x46], // MS CAB
        
        // ===== 동영상 파일 =====
        "mp4": [0x66, 0x74, 0x79, 0x70], // MP4 (offset 4)
        "avi": [0x52, 0x49, 0x46, 0x46], // AVI (RIFF)
        "mov": [0x66, 0x74, 0x79, 0x70, 0x71, 0x74], // QuickTime
        "mkv": [0x1A, 0x45, 0xDF, 0xA3], // Matroska
        "wmv": [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11], // Windows Media
        "flv": [0x46, 0x4C, 0x56], // Flash Video
        "webm": [0x1A, 0x45, 0xDF, 0xA3], // WebM (same as MKV)
        "3gp": [0x66, 0x74, 0x79, 0x70, 0x33, 0x67], // 3GPP
        
        // ===== 오디오 파일 =====
        "mp3": [0xFF, 0xFB], // MP3 (MPEG Layer 3)
        "wav": [0x52, 0x49, 0x46, 0x46], // WAV (RIFF)
        "flac": [0x66, 0x4C, 0x61, 0x43], // FLAC
        "ogg": [0x4F, 0x67, 0x67, 0x53], // OGG
        "m4a": [0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41], // M4A
        "aac": [0xFF, 0xF1], // AAC
        "amr": [0x23, 0x21, 0x41, 0x4D, 0x52], // AMR
        "mid": [0x4D, 0x54, 0x68, 0x64], // MIDI
        
        // ===== 실행 파일 =====
        "exe": [0x4D, 0x5A], // PE/COFF (Windows)
        "msi": [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], // MSI
        "deb": [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E], // DEB
        "rpm": [0xED, 0xAB, 0xEE, 0xDB], // RPM
        "dmg": [0x78, 0x01, 0x73, 0x0D], // Apple DMG
        "apk": [0x50, 0x4B, 0x03, 0x04], // APK (ZIP-based)
        
        // ===== 폰트 파일 =====
        "ttf": [0x00, 0x01, 0x00, 0x00], // TrueType
        "otf": [0x4F, 0x54, 0x54, 0x4F], // OpenType
        "woff": [0x77, 0x4F, 0x46, 0x46], // WOFF
        "woff2": [0x77, 0x4F, 0x46, 0x32], // WOFF2
        
        // ===== 기타 특수 형식 =====
        "sqlite": [0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66], // SQLite
        "class": [0xCA, 0xFE, 0xBA, 0xBE], // Java Class
        "swf": [0x46, 0x57, 0x53], // Flash SWF (uncompressed)
        "swf_compressed": [0x43, 0x57, 0x53], // Flash SWF (compressed)
        "iso": [0x43, 0x44, 0x30, 0x30, 0x31], // ISO 9660
        "tar": [0x75, 0x73, 0x74, 0x61, 0x72], // TAR (offset 257)
        "blend": [0x42, 0x4C, 0x45, 0x4E, 0x44, 0x45, 0x52], // Blender
        "plist": [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74], // Binary plist
        "torrent": [0x64, 0x38, 0x3A, 0x61, 0x6E, 0x6E, 0x6F, 0x75], // BitTorrent
        
        // ===== 개발 관련 =====
        "node": [0x7F, 0x45, 0x4C, 0x46], // ELF (Linux executables)
        "macho": [0xFE, 0xED, 0xFA, 0xCE], // Mach-O (macOS executables)
        "macho64": [0xFE, 0xED, 0xFA, 0xCF], // Mach-O 64-bit
        "java": [0xCA, 0xFE, 0xBA, 0xBE], // Java bytecode
        "wasm": [0x00, 0x61, 0x73, 0x6D] // WebAssembly
    ]
    
    /// Content-Type 헤더로부터 적절한 파일 확장자 감지
    static func detectFileExtension(from contentType: String, suggestedFilename: String? = nil) -> String {
        // 1. 제안된 파일명에서 확장자 추출 (우선순위 최고)
        if let filename = suggestedFilename?.lowercased(),
           let dotIndex = filename.lastIndex(of: ".") {
            let extractedExt = String(filename[filename.index(after: dotIndex)...])
            if !extractedExt.isEmpty && extractedExt.count <= 5 {
                // 추출된 확장자가 유효한지 확인
                let validImageExts = [
                    "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "avif", 
                    "ico", "psd", "svg", "ppm", "pgm", "pbm", "pnm", "raw", "cr2", "nef", "dng", "arw"
                ]
                let validDocExts = [
                    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp",
                    "epub", "mobi", "azw", "csv", "tsv", "pages", "numbers", "key"
                ]
                let validArchiveExts = [
                    "zip", "rar", "7z", "tar", "gz", "bz2", "bz", "xz", "lz", "Z", "ace", "alz", "cab",
                    "deb", "rpm", "sit", "sitx", "dmg", "iso", "img"
                ]
                let validVideoExts = [
                    "mp4", "avi", "mov", "mkv", "wmv", "flv", "webm", "3gp", "3g2", "m4v", "mpg", "mpeg",
                    "ts", "m2ts", "mts", "vob", "asf", "rm", "rmvb", "ogv"
                ]
                let validAudioExts = [
                    "mp3", "wav", "aac", "ogg", "flac", "wma", "m4a", "amr", "3ga", "mid", "midi", "opus",
                    "ape", "ac3", "dts", "ra", "au", "aiff", "caf"
                ]
                let validProgExts = [
                    "js", "ts", "html", "css", "json", "xml", "py", "java", "c", "cpp", "cs", "swift",
                    "rb", "pl", "sh", "sql", "yml", "yaml", "toml", "ini", "properties", "md", "rst"
                ]
                let validExecExts = [
                    "exe", "msi", "deb", "rpm", "apk", "dmg", "pkg", "appx", "snap", "flatpak", "bin", "run"
                ]
                let validFontExts = [
                    "ttf", "otf", "woff", "woff2", "eot", "ttc", "fon", "pfb", "pfm"
                ]
                let valid3DExts = [
                    "gltf", "glb", "obj", "stl", "ply", "x3d", "3mf", "dae", "fbx", "blend", "max", "3ds"
                ]
                let validMiscExts = [
                    "sqlite", "db", "ps", "dvi", "latex", "tex", "nb", "cdf", "kml", "kmz", "gpx", 
                    "srt", "vtt", "ass", "ssa", "torrent", "rss", "atom"
                ]
                
                if validImageExts.contains(extractedExt) || 
                   validDocExts.contains(extractedExt) || 
                   validArchiveExts.contains(extractedExt) ||
                   validVideoExts.contains(extractedExt) ||
                   validAudioExts.contains(extractedExt) ||
                   validProgExts.contains(extractedExt) ||
                   validExecExts.contains(extractedExt) ||
                   validFontExts.contains(extractedExt) ||
                   valid3DExts.contains(extractedExt) ||
                   validMiscExts.contains(extractedExt) {
                    TabPersistenceManager.debugMessages.append("📁 파일명 확장자 추출: \(filename) → .\(extractedExt)")
                    return extractedExt
                }
            }
        }
        
        // 2. Content-Type에서 직접 매핑
        let normalizedContentType = contentType.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        
        if let fileExtension = contentTypeToExtension[normalizedContentType] {
            TabPersistenceManager.debugMessages.append("📁 Content-Type 매핑: \(contentType) → .\(fileExtension)")
            return fileExtension
        }
        
        // 3. Content-Type 패턴 매칭
        if normalizedContentType.contains("image") {
            return "jpg" // 기본 이미지 확장자
        } else if normalizedContentType.contains("video") {
            return "mp4" // 기본 동영상 확장자
        } else if normalizedContentType.contains("audio") {
            return "mp3" // 기본 오디오 확장자
        } else if normalizedContentType.contains("text") {
            return "txt" // 기본 텍스트 확장자
        } else if normalizedContentType.contains("pdf") {
            return "pdf"
        } else if normalizedContentType.contains("zip") {
            return "zip"
        }
        
        // 4. 기본값
        TabPersistenceManager.debugMessages.append("📁 확장자 감지 실패, 기본값 사용: \(contentType)")
        return "bin"
    }
    
    /// 파일 데이터의 시그니처로부터 실제 파일 타입 감지
    static func detectFileTypeFromData(_ data: Data) -> String? {
        guard data.count >= 8 else { return nil }
        
        let bytes = Array(data.prefix(512)) // 처음 512바이트 확인 (확장)
        
        // 오프셋이 필요한 특수 케이스들 먼저 확인
        
        // MP4/MOV 계열 (offset 4에서 확인)
        if bytes.count >= 8 {
            let mp4Signatures: [(String, [UInt8])] = [
                ("mp4", [0x66, 0x74, 0x79, 0x70]),
                ("mov", [0x66, 0x74, 0x79, 0x70, 0x71, 0x74]),
                ("3gp", [0x66, 0x74, 0x79, 0x70, 0x33, 0x67]),
                ("m4a", [0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41])
            ]
            
            for (type, signature) in mp4Signatures {
                if signature.count <= bytes.count - 4 {
                    let isMatch = signature.enumerated().allSatisfy { index, byte in
                        bytes[4 + index] == byte
                    }
                    if isMatch {
                        TabPersistenceManager.debugMessages.append("📁 파일 시그니처 감지 (offset 4): .\(type)")
                        return type
                    }
                }
            }
        }
        
        // WEBP (offset 8에서 확인)
        if bytes.count >= 12 {
            let webpSignature: [UInt8] = [0x57, 0x45, 0x42, 0x50]
            let isWebp = webpSignature.enumerated().allSatisfy { index, byte in
                bytes[8 + index] == byte
            }
            if isWebp {
                TabPersistenceManager.debugMessages.append("📁 파일 시그니처 감지 (offset 8): .webp")
                return "webp"
            }
        }
        
        // TAR (offset 257에서 확인)
        if bytes.count >= 262 {
            let tarSignature: [UInt8] = [0x75, 0x73, 0x74, 0x61, 0x72]
            let isTar = tarSignature.enumerated().allSatisfy { index, byte in
                bytes[257 + index] == byte
            }
            if isTar {
                TabPersistenceManager.debugMessages.append("📁 파일 시그니처 감지 (offset 257): .tar")
                return "tar"
            }
        }
        
        // 일반적인 시그니처 확인 (offset 0)
        for (fileType, signature) in fileSignatures {
            if signature.count <= bytes.count {
                let isMatch = signature.enumerated().allSatisfy { index, byte in
                    bytes[index] == byte
                }
                if isMatch {
                    TabPersistenceManager.debugMessages.append("📁 파일 시그니처 감지: .\(fileType)")
                    return fileType
                }
            }
        }
        
        // 추가 특수 케이스들
        
        // XML 파일 감지 (텍스트 기반)
        if let string = String(data: data.prefix(100), encoding: .utf8) {
            let xmlStart = string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if xmlStart.hasPrefix("<?xml") {
                TabPersistenceManager.debugMessages.append("📁 XML 헤더 감지: .xml")
                return "xml"
            }
            if xmlStart.hasPrefix("<!doctype html") || xmlStart.hasPrefix("<html") {
                TabPersistenceManager.debugMessages.append("📁 HTML 헤더 감지: .html")
                return "html"
            }
            if xmlStart.hasPrefix("{") && xmlStart.contains("\"") {
                TabPersistenceManager.debugMessages.append("📁 JSON 헤더 감지: .json")
                return "json"
            }
        }
        
        return nil
    }
    
    /// 다운로드 응답 분석
    static func analyzeDownloadResponse(_ response: URLResponse, suggestedFilename: String) -> (extension: String, contentType: String, isAttachment: Bool) {
        let contentType = response.mimeType ?? "application/octet-stream"
        
        // Content-Disposition 헤더 확인
        var isAttachment = false
        if let httpResponse = response as? HTTPURLResponse,
           let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() {
            isAttachment = disposition.contains("attachment")
        }
        
        let detectedExtension = detectFileExtension(from: contentType, suggestedFilename: suggestedFilename)
        
        TabPersistenceManager.debugMessages.append("📁 다운로드 분석: \(suggestedFilename) → .\(detectedExtension) (\(contentType))")
        
        return (extension: detectedExtension, contentType: contentType, isAttachment: isAttachment)
    }
}

// MARK: - 다운로드 델리게이트 관리자 (메모리 안전성 보장)
class DownloadDelegateManager {
    static let shared = DownloadDelegateManager()
    private var activeDelegates: [ObjectIdentifier: WebViewDownloadDelegate] = [:]
    private let queue = DispatchQueue(label: "downloadDelegateManager", attributes: .concurrent)
    
    private init() {}
    
    func createDelegate(for download: WKDownload, stateModel: WebViewStateModel?) -> WebViewDownloadDelegate {
        return queue.sync(flags: .barrier) {
            let delegate = WebViewDownloadDelegate(stateModel: stateModel)
            activeDelegates[ObjectIdentifier(download)] = delegate
            return delegate
        }
    }
    
    func removeDelegate(for download: WKDownload) {
        queue.async(flags: .barrier) {
            self.activeDelegates.removeValue(forKey: ObjectIdentifier(download))
        }
    }
}

// MARK: - 다운로드 코디네이터 (StateModel에서 이관)
final class DownloadCoordinator {
    static let shared = DownloadCoordinator()
    private init() {}
    private var map = [ObjectIdentifier: URL]()
    func set(url: URL, for download: WKDownload) { map[ObjectIdentifier(download)] = url }
    func url(for download: WKDownload) -> URL? { map[ObjectIdentifier(download)] }
    func remove(_ download: WKDownload) { map.removeValue(forKey: ObjectIdentifier(download)) }
}

// MARK: - 파일명 정리 (StateModel에서 이관)
func sanitizedFilename(name: String) -> String {
    var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    result = result.components(separatedBy: forbidden).joined(separator: "")
    if result.count > 150 {
        result = String(result.prefix(150))
    }
    return result.isEmpty ? "download" : result
}

// MARK: - WKDownloadDelegate 구현 (StateModel에서 이관)
@available(iOS 14.0, *)
class WebViewDownloadDelegate: NSObject, WKDownloadDelegate {
    weak var stateModel: WebViewStateModel?
    
    init(stateModel: WebViewStateModel?) {
        self.stateModel = stateModel
        super.init()
    }
    
    func download(_ download: WKDownload,
                 decideDestinationUsing response: URLResponse,
                 suggestedFilename: String,
                 completionHandler: @escaping (URL?) -> Void) {

        // 파일 타입 분석
        let analysis = FileTypeDetector.analyzeDownloadResponse(response, suggestedFilename: suggestedFilename)
        
        // 확장자가 없다면 감지된 확장자 추가
        var finalFilename = suggestedFilename
        if !suggestedFilename.contains(".") {
            finalFilename = "\(suggestedFilename).\(analysis.extension)"
        }
        
        NotificationCenter.default.post(name: .WebViewDownloadStart,
                                        object: nil,
                                        userInfo: [
                                            "filename": finalFilename,
                                            "contentType": analysis.contentType,
                                            "isAttachment": analysis.isAttachment,
                                            "originalFilename": suggestedFilename,
                                            "detectedExtension": analysis.extension,
                                            "fileSize": response.expectedContentLength
                                        ])

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsDir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let safeName = sanitizedFilename(name: finalFilename)
        let dst = downloadsDir.appendingPathComponent(safeName)

        // 동일한 파일이 있으면 번호 추가
        var finalDst = dst
        var counter = 1
        while FileManager.default.fileExists(atPath: finalDst.path) {
            let nameWithoutExt = dst.deletingPathExtension().lastPathComponent
            let ext = dst.pathExtension
            let numberedName = ext.isEmpty ? "\(nameWithoutExt)_\(counter)" : "\(nameWithoutExt)_\(counter).\(ext)"
            finalDst = downloadsDir.appendingPathComponent(numberedName)
            counter += 1
        }

        DownloadCoordinator.shared.set(url: finalDst, for: download)
        TabPersistenceManager.debugMessages.append("📁 다운로드 시작: \(finalFilename) → \(finalDst.lastPathComponent)")
        completionHandler(finalDst)
    }

    func download(_ download: WKDownload,
                 didWriteData bytesWritten: Int64,
                 totalBytesWritten: Int64,
                 totalBytesExpectedToWrite: Int64) {
        let progress = if totalBytesExpectedToWrite > 0 {
            Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            // 파일 크기를 모르는 경우 totalBytesWritten 기반으로 추정
            min(0.9, Double(totalBytesWritten) / (1024 * 1024)) // 1MB 기준으로 추정
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .WebViewDownloadProgress,
                                            object: nil,
                                            userInfo: ["progress": progress])
        }
        
        TabPersistenceManager.debugMessages.append("📁 다운로드 진행: \(Int(progress * 100))% (\(totalBytesWritten)/\(totalBytesExpectedToWrite))")
    }

    func download(_ download: WKDownload,
                 didFailWithError error: Error,
                 resumeData: Data?) {
        let filename = DownloadCoordinator.shared.url(for: download)?.lastPathComponent ?? "파일"
        DownloadCoordinator.shared.remove(download)
        
        // 델리게이트 정리
        DownloadDelegateManager.shared.removeDelegate(for: download)

        NotificationCenter.default.post(name: .WebViewDownloadFailed, object: nil)

        DispatchQueue.main.async {
            if let top = getTopViewController() {
                let alert = UIAlertController(title: "다운로드 실패",
                                              message: "\(filename) 다운로드 중 오류가 발생했습니다.\n\(error.localizedDescription)",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "확인", style: .default))
                top.present(alert, animated: true)
            }
        }
        
        TabPersistenceManager.debugMessages.append("📁 다운로드 실패: \(filename) - \(error.localizedDescription)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let fileURL = DownloadCoordinator.shared.url(for: download) else {
            TabPersistenceManager.debugMessages.append("⚠️ 다운로드 완료했지만 파일 경로를 찾을 수 없음")
            NotificationCenter.default.post(name: .WebViewDownloadFinish, object: nil)
            // 델리게이트 정리
            DownloadDelegateManager.shared.removeDelegate(for: download)
            return
        }
        DownloadCoordinator.shared.remove(download)
        
        // 델리게이트 정리
        DownloadDelegateManager.shared.removeDelegate(for: download)

        NotificationCenter.default.post(name: .WebViewDownloadFinish, object: nil)
        TabPersistenceManager.debugMessages.append("📁 다운로드 완료: \(fileURL.lastPathComponent)")

        DispatchQueue.main.async {
            guard let top = getTopViewController() else { return }
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activityVC.popoverPresentationController?.sourceView = top.view
            top.present(activityVC, animated: true)
        }
    }
}

// MARK: - 🎯 **보수적인 다운로드 정책 결정** (수정됨)
func handleDownloadDecision(_ navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if #available(iOS 14.0, *) {
        // 🎯 **1순위: Content-Disposition attachment 헤더 확인**
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disp = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disp.contains("attachment") {
            TabPersistenceManager.debugMessages.append("📁 Content-Disposition attachment 감지")
            decisionHandler(.download)
            return
        }
        
        // 🎯 **2순위: 명확한 다운로드 Content-Type만 처리** (보수적)
        let contentType = navigationResponse.response.mimeType?.lowercased() ?? ""
        let definiteDownloadTypes = [
            // 압축 파일
            "application/zip",
            "application/x-rar-compressed", 
            "application/x-7z-compressed",
            "application/gzip",
            "application/x-tar",
            // 실행 파일
            "application/x-msdownload",
            "application/x-executable", 
            "application/x-msi",
            "application/vnd.android.package-archive",
            "application/x-apple-diskimage",
            // 바이너리 파일
            "application/octet-stream"
        ]
        
        if definiteDownloadTypes.contains(where: { contentType.contains($0) }) {
            TabPersistenceManager.debugMessages.append("📁 명확한 다운로드 Content-Type 감지: \(contentType)")
            decisionHandler(.download)
            return
        }
        
        // 🎯 **3순위: 파일 확장자 기반 결정** (매우 보수적 - 명백한 다운로드 파일만)
        if let url = navigationResponse.response.url {
            let pathExt = url.pathExtension.lowercased()
            let obviousDownloadExtensions = [
                // 압축 파일만
                "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
                // 실행 파일만
                "exe", "msi", "dmg", "pkg", "deb", "rpm", "apk",
                // 바이너리 파일만
                "bin", "iso", "img"
            ]
            
            if obviousDownloadExtensions.contains(pathExt) {
                TabPersistenceManager.debugMessages.append("📁 명백한 다운로드 확장자 감지: .\(pathExt)")
                decisionHandler(.download)
                return
            }
            
            // 🎯 **4순위: URL에 명시적 다운로드 키워드가 있는 경우만** (매우 제한적)
            let urlString = url.absoluteString.lowercased()
            if (urlString.contains("/download/") || 
                urlString.contains("?download=") || 
                urlString.contains("&download=") ||
                urlString.contains("attachment=true")) &&
               !urlString.contains(".php") && // PHP 파일은 제외
               !urlString.contains(".html") && // HTML 파일은 제외
               !urlString.contains(".htm") {  // HTM 파일은 제외
                TabPersistenceManager.debugMessages.append("📁 명시적 다운로드 URL 패턴 감지: \(url.absoluteString)")
                decisionHandler(.download)
                return
            }
        }
        
       
    }
    
    decisionHandler(.allow)
}

// MARK: - NavigationDelegate 확장 (DataModel에서 이관)
func setupDownloadHandling(for webView: WKWebView, stateModel: WebViewStateModel) {
    // iOS 14+ 다운로드 델리게이트 설정은 navigationAction에서 처리
    TabPersistenceManager.debugMessages.append("📁 다운로드 핸들링 설정 완료")
}

// MARK: - 다운로드 델리게이트 연결 (DataModel에서 이관)
@available(iOS 14.0, *)
func connectDownloadDelegate(download: WKDownload, stateModel: WebViewStateModel?) {
    let downloadDelegate = DownloadDelegateManager.shared.createDelegate(for: download, stateModel: stateModel)
    download.delegate = downloadDelegate
    TabPersistenceManager.debugMessages.append("📁 다운로드 델리게이트 연결: \(download) (메모리 안전)")
}

// MARK: - 파일 업로드 처리 구현체
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

// MARK: - 파일 업로드 트리거
@available(iOS 14.0, *)
func triggerFileUpload(completion: @escaping ([URL]?) -> Void) {
    guard let topVC = getTopViewController() else {
        completion(nil)
        return
    }
    
    let filePicker = FilePicker { urls in
        completion(urls)
    }
    
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.delegate = filePicker
    picker.allowsMultipleSelection = true
    
    // FilePicker 참조 유지를 위한 임시 저장
    objc_setAssociatedObject(picker, "filePicker", filePicker, .OBJC_ASSOCIATION_RETAIN)
    
    topVC.present(picker, animated: true)
    TabPersistenceManager.debugMessages.append("📁 파일 선택기 표시")
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

// MARK: - 통합된 다운로드 인터페이스 (커스텀뷰에서 호출용)

/// WebView 다운로드 기능 설정
@available(iOS 14.0, *)
func setupWebViewDownloads(webView: WKWebView, stateModel: WebViewStateModel) {
    // 다운로드 핸들링 설정
    setupDownloadHandling(for: webView, stateModel: stateModel)
    
    TabPersistenceManager.debugMessages.append("📁 WebView 다운로드 기능 설정 완료")
}

/// 다운로드 델리게이트 연결 (navigationAction/navigationResponse에서 호출)
@available(iOS 14.0, *)
func handleDownloadStart(download: WKDownload, stateModel: WebViewStateModel?) {
    connectDownloadDelegate(download: download, stateModel: stateModel)
}

/// 다운로드 정책 결정 래퍼
func shouldDownloadResponse(_ navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    handleDownloadDecision(navigationResponse, decisionHandler: decisionHandler)
}
