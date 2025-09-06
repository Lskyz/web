//
//  BFCacheSwipeTransition.swift
//  🔧 **스크롤 복원 문제 완전 해결 - 실행→확인→실행 구조로 변경**
//  ✅ 순차 실행으로 충돌 방지
//  ✅ 각 단계별 검증 후 다음 단계 진행
//  ✅ 상한선 방식 + 스크롤 위치 확인 강화
//  🔧 Swift 네이티브와 JavaScript 스크롤 동기화 수정
//

import UIKit
import WebKit
import SwiftUI

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 🧵 **개선된 제스처 컨텍스트 (먹통 방지)**
private class GestureContext {
    let tabID: UUID
    let gestureID: UUID = UUID()
    weak var webView: WKWebView?
    weak var stateModel: WebViewStateModel?
    private var isValid: Bool = true
    private let validationQueue = DispatchQueue(label: "gesture.validation", attributes: .concurrent)
    
    init(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        self.tabID = tabID
        self.webView = webView
        self.stateModel = stateModel
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 생성: \(String(gestureID.uuidString.prefix(8)))")
    }
    
    func validateAndExecute(_ operation: () -> Void) {
        validationQueue.sync {
            guard isValid else {
                TabPersistenceManager.debugMessages.append("🧵 무효한 컨텍스트 - 작업 취소: \(String(gestureID.uuidString.prefix(8)))")
                return
            }
            operation()
        }
    }
    
    func invalidate() {
        validationQueue.async(flags: .barrier) {
            self.isValid = false
            TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 무효화: \(String(self.gestureID.uuidString.prefix(8)))")
        }
    }
    
    deinit {
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 해제: \(String(gestureID.uuidString.prefix(8)))")
    }
}

// MARK: - 🔄 프레임 기반 적응형 타이밍 시스템
struct SiteTimingProfile: Codable {
    let hostname: String
    var loadingSamples: [TimeInterval] = []
    var averageLoadingTime: TimeInterval = 0.35
    var successfulRestores: Int = 0
    var totalRestores: Int = 0
    var lastUpdated: Date = Date()
    
    var successRate: Double {
        guard totalRestores > 0 else { return 0.0 }
        return Double(successfulRestores) / Double(totalRestores)
    }
    
    mutating func recordLoadingTime(_ duration: TimeInterval) {
        loadingSamples.append(duration)
        if loadingSamples.count > 10 {
            loadingSamples.removeFirst()
        }
        averageLoadingTime = loadingSamples.reduce(0, +) / Double(loadingSamples.count)
        lastUpdated = Date()
    }
    
    mutating func recordRestoreAttempt(success: Bool) {
        totalRestores += 1
        if success {
            successfulRestores += 1
        }
        lastUpdated = Date()
    }
    
    func getAdaptiveWaitTime(step: Int) -> TimeInterval {
        let baseTime = max(averageLoadingTime, 0.28)
        let stepMultiplier = Double(step) * 0.08
        let successFactor: Double = (successRate > 0.8) ? 0.75 : (successRate > 0.6 ? 0.85 : 1.0)
        return (baseTime + stepMultiplier) * successFactor
    }
}

// MARK: - 📸 BFCache 페이지 스냅샷
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord
        case domSnapshot
        case scrollPosition
        case jsState
        case timestamp
        case webViewSnapshotPath
        case captureStatus
        case version
    }
    
    // Custom encoding/decoding for [String: Any]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
    }
    
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
    }
    
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🔧 **핵심 수정: 순차 실행 스크롤 복원 시스템 (실행→확인→실행)**
    func restore(to webView: WKWebView, siteProfile: SiteTimingProfile?, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🔧 순차 스크롤 복원 시작 - 상태: \(captureStatus.rawValue)")
        
        // 🔧 **Step 1: DOM 준비 확인 → 확인 → 다음 단계**
        checkDOMReady(webView: webView) { [weak self] domReady in
            guard let self = self else {
                completion(false)
                return
            }
            
            if !domReady {
                TabPersistenceManager.debugMessages.append("❌ DOM 준비 실패")
                completion(false)
                return
            }
            
            TabPersistenceManager.debugMessages.append("✅ DOM 준비 완료")
            
            // 🔧 **Step 2: 기본 스크롤 실행 → 확인 → 다음 단계**
            self.performBasicScrollRestore(webView: webView) { basicSuccess in
                TabPersistenceManager.debugMessages.append("🔧 기본 스크롤: \(basicSuccess ? "성공" : "실패")")
                
                // 기본 스크롤 실패해도 다음 단계 진행 (부분 성공)
                
                // 🔧 **Step 3: 컨테이너 스크롤 실행 → 확인 → 다음 단계**
                self.performContainerScrollRestore(webView: webView) { containerSuccess in
                    TabPersistenceManager.debugMessages.append("🔧 컨테이너 스크롤: \(containerSuccess ? "성공" : "실패")")
                    
                    // 🔧 **Step 4: iframe 스크롤 실행 → 확인 → 최종 검증**
                    self.performIframeScrollRestore(webView: webView) { iframeSuccess in
                        TabPersistenceManager.debugMessages.append("🔧 iframe 스크롤: \(iframeSuccess ? "성공" : "실패")")
                        
                        // 🔧 **Step 5: 최종 검증**
                        self.performFinalVerification(webView: webView) { finalSuccess in
                            let overallSuccess = basicSuccess && finalSuccess
                            TabPersistenceManager.debugMessages.append("🔧 최종 결과: \(overallSuccess ? "✅ 성공" : "❌ 실패")")
                            completion(overallSuccess)
                        }
                    }
                }
            }
        }
    }
    
    // 🔧 **Step 1: DOM 준비 확인 (상한선 200ms)**
    private func checkDOMReady(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let checkScript = """
        (function() {
            return new Promise(function(resolve) {
                function checkReady() {
                    if (document.readyState === 'complete') {
                        // DOM 완료 후 추가 100ms 대기 (렌더링 완료)
                        setTimeout(function() {
                            console.log('🔧 DOM 완전 준비 완료');
                            resolve(true);
                        }, 100);
                    } else {
                        setTimeout(checkReady, 50);
                    }
                }
                
                checkReady();
                
                // 상한선 2초 (DOM 로딩이 너무 오래 걸리면 강제 진행)
                setTimeout(function() {
                    console.log('🔧 DOM 준비 상한선 도달');
                    resolve(document.readyState !== 'loading');
                }, 2000);
            });
        })()
        """
        
        BFCacheTransitionSystem.shared.evalAwaitBool(on: webView, source: checkScript, timeout: 2.5) { success in
            completion(success)
        }
    }
    
    // 🔧 **Step 2: 기본 스크롤 복원 (실행 → 확인)**
    private func performBasicScrollRestore(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let targetPos = self.scrollPosition
        
        let basicScrollScript = """
        (function() {
            return new Promise(function(resolve) {
                try {
                    console.log('🔧 기본 스크롤 복원 시작:', [\(Int(targetPos.x)), \(Int(targetPos.y))]);
                    
                    // 🔧 **스크롤 차단 설정**
                    if (!window.__bfcache_scroll_setup) {
                        const style = document.createElement('style');
                        style.textContent = `
                            html, body {
                                scroll-behavior: auto !important;
                                overflow-anchor: none !important;
                            }
                            * { scroll-behavior: auto !important; }
                        `;
                        document.head.appendChild(style);
                        
                        if ('scrollRestoration' in history) {
                            history.scrollRestoration = 'manual';
                        }
                        
                        window.__bfcache_scroll_setup = true;
                    }
                    
                    // 🔧 **통합 스크롤 실행**
                    function executeScroll() {
                        window.scrollTo(\(Int(targetPos.x)), \(Int(targetPos.y)));
                        
                        const scrollingElement = document.scrollingElement;
                        if (scrollingElement) {
                            scrollingElement.scrollTop = \(Int(targetPos.y));
                            scrollingElement.scrollLeft = \(Int(targetPos.x));
                        }
                        
                        if (document.documentElement) {
                            document.documentElement.scrollTop = \(Int(targetPos.y));
                            document.documentElement.scrollLeft = \(Int(targetPos.x));
                        }
                        
                        if (document.body) {
                            document.body.scrollTop = \(Int(targetPos.y));
                            document.body.scrollLeft = \(Int(targetPos.x));
                        }
                    }
                    
                    // 🔧 **실행 → 확인 → 재시도 루프**
                    let attempts = 0;
                    const maxAttempts = 10;
                    const tolerance = 5; // ±5px 허용
                    
                    function verifyAndRetry() {
                        executeScroll();
                        
                        // 위치 확인
                        requestAnimationFrame(function() {
                            const currentX = window.pageXOffset || document.documentElement.scrollLeft || 0;
                            const currentY = window.pageYOffset || document.documentElement.scrollTop || 0;
                            const deltaX = Math.abs(currentX - \(Int(targetPos.x)));
                            const deltaY = Math.abs(currentY - \(Int(targetPos.y)));
                            
                            console.log('🔧 스크롤 확인:', {
                                target: [\(Int(targetPos.x)), \(Int(targetPos.y))],
                                current: [currentX, currentY],
                                delta: [deltaX, deltaY],
                                attempt: attempts + 1
                            });
                            
                            if (deltaX <= tolerance && deltaY <= tolerance) {
                                console.log('🔧 기본 스크롤 성공');
                                resolve(true);
                                return;
                            }
                            
                            attempts++;
                            if (attempts >= maxAttempts) {
                                console.log('🔧 기본 스크롤 최대 시도 도달');
                                // 20px 이내면 부분 성공으로 간주
                                resolve(deltaX <= 20 && deltaY <= 20);
                                return;
                            }
                            
                            // 재시도
                            setTimeout(verifyAndRetry, 50);
                        });
                    }
                    
                    verifyAndRetry();
                    
                    // 상한선 2초
                    setTimeout(function() {
                        console.log('🔧 기본 스크롤 상한선 도달');
                        resolve(false);
                    }, 2000);
                    
                } catch(e) {
                    console.error('🔧 기본 스크롤 실행 실패:', e);
                    resolve(false);
                }
            });
        })()
        """
        
        BFCacheTransitionSystem.shared.evalAwaitBool(on: webView, source: basicScrollScript, timeout: 2.5) { success in
            // 🔧 **기본 스크롤 완료 후 네이티브 스크롤뷰도 동기화**
            if success {
                DispatchQueue.main.async {
                    webView.scrollView.setContentOffset(targetPos, animated: false)
                    TabPersistenceManager.debugMessages.append("🔧 네이티브 스크롤뷰 동기화 완료")
                }
            }
            completion(success)
        }
    }
    
    // 🔧 **Step 3: 컨테이너 스크롤 복원**
    private func performContainerScrollRestore(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let jsState = self.jsState,
              let scrollData = jsState["scroll"] as? [String: Any],
              let elements = scrollData["elements"] as? [[String: Any]], !elements.isEmpty else {
            TabPersistenceManager.debugMessages.append("🔧 컨테이너 스크롤 요소 없음 - 스킵")
            completion(true) // 요소가 없으면 성공으로 간주
            return
        }
        
        let containerScript = """
        (function() {
            return new Promise(function(resolve) {
                try {
                    const elements = \(convertToJSONString(elements) ?? "[]");
                    let restored = 0;
                    let processed = 0;
                    const total = elements.length;
                    
                    console.log('🔧 컨테이너 스크롤 복원 시작:', total, '개 요소');
                    
                    if (total === 0) {
                        resolve(true);
                        return;
                    }
                    
                    elements.forEach(function(item, index) {
                        if (!item.selector) {
                            processed++;
                            if (processed === total) {
                                resolve(restored > 0);
                            }
                            return;
                        }
                        
                        const selectors = [
                            item.selector,
                            item.selector.replace(/\\[\\d+\\]/g, ''),
                            item.className ? '.' + item.className : null,
                            item.id ? '#' + item.id : null
                        ].filter(s => s);
                        
                        let found = false;
                        for (const sel of selectors) {
                            const elements = document.querySelectorAll(sel);
                            if (elements.length > 0) {
                                elements.forEach(function(el) {
                                    if (el && typeof el.scrollTop === 'number') {
                                        el.scrollTop = item.top || 0;
                                        el.scrollLeft = item.left || 0;
                                        restored++;
                                        found = true;
                                    }
                                });
                                break;
                            }
                        }
                        
                        processed++;
                        if (processed === total) {
                            console.log('🔧 컨테이너 스크롤 완료:', restored, '개 복원');
                            resolve(restored > 0);
                        }
                    });
                    
                    // 상한선 1초
                    setTimeout(function() {
                        console.log('🔧 컨테이너 스크롤 상한선 도달');
                        resolve(restored > 0);
                    }, 1000);
                    
                } catch(e) {
                    console.error('🔧 컨테이너 스크롤 실패:', e);
                    resolve(false);
                }
            });
        })()
        """
        
        BFCacheTransitionSystem.shared.evalAwaitBool(on: webView, source: containerScript, timeout: 1.5) { success in
            completion(success)
        }
    }
    
    // 🔧 **Step 4: iframe 스크롤 복원**
    private func performIframeScrollRestore(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let jsState = self.jsState,
              let iframeData = jsState["iframes"] as? [[String: Any]], !iframeData.isEmpty else {
            TabPersistenceManager.debugMessages.append("🔧 iframe 요소 없음 - 스킵")
            completion(true) // 요소가 없으면 성공으로 간주
            return
        }
        
        let iframeScript = """
        (function() {
            return new Promise(function(resolve) {
                try {
                    const iframes = \(convertToJSONString(iframeData) ?? "[]");
                    let restored = 0;
                    
                    console.log('🔧 iframe 스크롤 복원 시작:', iframes.length, '개 iframe');
                    
                    if (iframes.length === 0) {
                        resolve(true);
                        return;
                    }
                    
                    iframes.forEach(function(iframeInfo) {
                        const iframe = document.querySelector(iframeInfo.selector);
                        if (iframe && iframe.contentWindow) {
                            try {
                                iframe.contentWindow.scrollTo(
                                    iframeInfo.scrollX || 0,
                                    iframeInfo.scrollY || 0
                                );
                                restored++;
                            } catch(e) {
                                try {
                                    iframe.contentWindow.postMessage({
                                        type: 'restoreScroll',
                                        scrollX: iframeInfo.scrollX || 0,
                                        scrollY: iframeInfo.scrollY || 0
                                    }, '*');
                                    restored++;
                                } catch(crossOriginError) {
                                    console.log('Cross-origin iframe 접근 불가:', iframeInfo.selector);
                                }
                            }
                        }
                    });
                    
                    console.log('🔧 iframe 스크롤 완료:', restored, '개 복원');
                    resolve(restored > 0 || iframes.length === 0);
                    
                } catch(e) {
                    console.error('🔧 iframe 스크롤 실패:', e);
                    resolve(false);
                }
            });
        })()
        """
        
        BFCacheTransitionSystem.shared.evalAwaitBool(on: webView, source: iframeScript, timeout: 1.0) { success in
            completion(success)
        }
    }
    
    // 🔧 **Step 5: 최종 검증**
    private func performFinalVerification(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let targetPos = self.scrollPosition
        
        let verificationScript = """
        (function() {
            return new Promise(function(resolve) {
                try {
                    // 100ms 대기 후 최종 위치 확인
                    setTimeout(function() {
                        const currentX = window.pageXOffset || document.documentElement.scrollLeft || 0;
                        const currentY = window.pageYOffset || document.documentElement.scrollTop || 0;
                        const deltaX = Math.abs(currentX - \(Int(targetPos.x)));
                        const deltaY = Math.abs(currentY - \(Int(targetPos.y)));
                        
                        console.log('🔧 최종 검증:', {
                            target: [\(Int(targetPos.x)), \(Int(targetPos.y))],
                            current: [currentX, currentY],
                            delta: [deltaX, deltaY]
                        });
                        
                        // 10px 이내면 성공
                        const success = deltaX <= 10 && deltaY <= 10;
                        console.log('🔧 최종 검증 결과:', success ? '성공' : '실패');
                        resolve(success);
                        
                    }, 100);
                    
                } catch(e) {
                    console.error('🔧 최종 검증 실패:', e);
                    resolve(false);
                }
            });
        })()
        """
        
        BFCacheTransitionSystem.shared.evalAwaitBool(on: webView, source: verificationScript, timeout: 0.5) { success in
            completion(success)
        }
    }
    
    // 안전한 JSON 변환 유틸리티
    private func convertToJSONString(_ object: Any) -> String? {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: object, options: [])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            TabPersistenceManager.debugMessages.append("JSON 변환 실패: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - 📸 **네비게이션 이벤트 감지 시스템 - 모든 네비게이션에서 떠나기 전 캡처**
extension BFCacheTransitionSystem {
    
    /// CustomWebView에서 네비게이션 이벤트 구독
    static func registerNavigationObserver(for webView: WKWebView, stateModel: WebViewStateModel) {
        guard let tabID = stateModel.tabID else { return }
        
        // KVO로 URL 변경 감지
        let urlObserver = webView.observe(\.url, options: [.old, .new]) { [weak webView] observedWebView, change in
            guard let webView = webView,
                  let oldURL = change.oldValue as? URL,
                  let newURL = change.newValue as? URL,
                  oldURL != newURL else { return }
            
            // 📸 **URL이 바뀌는 순간 이전 페이지 캡처**
            if let currentRecord = stateModel.dataModel.currentPageRecord {
                shared.storeLeavingSnapshotIfPossible(webView: webView, stateModel: stateModel)
                shared.dbg("📸 URL 변경 감지 - 떠나기 전 캐시: \(oldURL.absoluteString) → \(newURL.absoluteString)")
            }
        }
        
        // 옵저버를 webView에 연결하여 생명주기 관리
        objc_setAssociatedObject(webView, "bfcache_url_observer", urlObserver, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        shared.dbg("📸 포괄적 네비게이션 감지 등록: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    /// CustomWebView 해제 시 옵저버 정리
    static func unregisterNavigationObserver(for webView: WKWebView) {
        if let observer = objc_getAssociatedObject(webView, "bfcache_url_observer") as? NSKeyValueObservation {
            observer.invalidate()
            objc_setAssociatedObject(webView, "bfcache_url_observer", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        shared.dbg("📸 네비게이션 감지 해제 완료")
    }
}

// MARK: - 🎯 **프레임 기반 BFCache 전환 시스템 + Promise 브릿지**
final class BFCacheTransitionSystem: NSObject, WKScriptMessageHandler {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        loadSiteTimingProfiles()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 🔧 **Promise 브릿지 시스템**
    private let jsBridgeQueue = DispatchQueue(label: "bfcache.jsbridge", attributes: .concurrent)
    private var pendingJS: [String: (Bool) -> Void] = [:]

    // JS → Swift 콜백
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bfcache",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let ok = body["ok"] as? Bool
        else { return }

        var cb: ((Bool)->Void)?
        jsBridgeQueue.sync { cb = pendingJS[id] }
        jsBridgeQueue.async(flags: .barrier) { self.pendingJS.removeValue(forKey: id) }
        cb?(ok)
    }

    // Promise를 기다려서 Bool로 돌려주는 eval
    func evalAwaitBool(on webView: WKWebView, source: String, timeout: TimeInterval = 0.6, completion: @escaping (Bool)->Void) {
        let id = UUID().uuidString
        jsBridgeQueue.async(flags: .barrier) { self.pendingJS[id] = completion }

        // source가 Promise든, 그냥 Bool이든 상관없이 resolve → postMessage
        let wrapped = """
        (function(){
          try{
            Promise.resolve((function(){ return ( \(source) ); })())
              .then(function(v){ window.webkit?.messageHandlers?.bfcache?.postMessage({id:'\(id)', ok: !!v}); })
              .catch(function(e){ console.error(e); window.webkit?.messageHandlers?.bfcache?.postMessage({id:'\(id)', ok:false}); });
            return 'PENDING:\(id)';
          }catch(e){
            try{ window.webkit?.messageHandlers?.bfcache?.postMessage({id:'\(id)', ok:false}); }catch(_){}
            return 'ERROR';
          }
        })();
        """
        webView.evaluateJavaScript(wrapped, completionHandler: nil)

        // 세이프가드 타임아웃
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            var stillPending = false
            self.jsBridgeQueue.sync { stillPending = (self.pendingJS[id] != nil) }
            if stillPending {
                self.jsBridgeQueue.async(flags: .barrier) { self.pendingJS.removeValue(forKey: id) }
                completion(false)
            }
        }
    }
    
    // MARK: - 📸 **핵심 개선: 단일 직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // MARK: - 💾 스레드 안전 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
    // 🔄 **사이트별 타이밍 프로파일**
    private var _siteTimingProfiles: [String: SiteTimingProfile] = [:]
    
    // 스레드 안전 액세서
    private var memoryCache: [UUID: BFCacheSnapshot] {
        get { cacheAccessQueue.sync { _memoryCache } }
    }
    
    private func setMemoryCache(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache[pageID] = snapshot
        }
    }
    
    private func removeFromMemoryCache(_ pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache.removeValue(forKey: pageID)
        }
    }
    
    private var diskCacheIndex: [UUID: String] {
        get { cacheAccessQueue.sync { _diskCacheIndex } }
    }
    
    private func setDiskIndex(_ path: String, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._diskCacheIndex[pageID] = path
        }
    }
    
    // 🔄 **사이트별 타이밍 프로파일 관리**
    private func getSiteProfile(for url: URL) -> SiteTimingProfile? {
        guard let hostname = url.host else { return nil }
        return cacheAccessQueue.sync { _siteTimingProfiles[hostname] }
    }
    
    private func updateSiteProfile(_ profile: SiteTimingProfile) {
        cacheAccessQueue.async(flags: .barrier) {
            self._siteTimingProfiles[profile.hostname] = profile
        }
        saveSiteTimingProfiles()
    }
    
    // MARK: - 📁 파일 시스템 경로
    private var bfCacheDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("BFCache", isDirectory: true)
    }
    
    private func tabDirectory(for tabID: UUID) -> URL {
        return bfCacheDirectory.appendingPathComponent("Tab_\(tabID.uuidString)", isDirectory: true)
    }
    
    private func pageDirectory(for pageID: UUID, tabID: UUID, version: Int) -> URL {
        return tabDirectory(for: tabID).appendingPathComponent("Page_\(pageID.uuidString)_v\(version)", isDirectory: true)
    }
    
    // MARK: - 🧵 **제스처 전환 상태 (리팩토링된 스레드 안전 관리)**
    private let gestureQueue = DispatchQueue(label: "gesture.management", attributes: .concurrent)
    private var _activeTransitions: [UUID: TransitionContext] = [:]
    private var _gestureContexts: [UUID: GestureContext] = [:]
    
    // 🧵 **스레드 안전 activeTransitions 접근**
    private var activeTransitions: [UUID: TransitionContext] {
        get { gestureQueue.sync { _activeTransitions } }
    }
    
    private func setActiveTransition(_ context: TransitionContext, for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions[tabID] = context
        }
    }
    
    private func removeActiveTransition(for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions.removeValue(forKey: tabID)
        }
    }
    
    private func getActiveTransition(for tabID: UUID) -> TransitionContext? {
        return gestureQueue.sync { _activeTransitions[tabID] }
    }
    
    // 🧵 **제스처 컨텍스트 관리**
    private func setGestureContext(_ context: GestureContext, for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._gestureContexts[key] = context
        }
    }
    
    private func removeGestureContext(for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            if let context = self._gestureContexts.removeValue(forKey: key) {
                context.invalidate()
            }
        }
    }
    
    private func getGestureContext(for key: UUID) -> GestureContext? {
        return gestureQueue.sync { _gestureContexts[key] }
    }
    
    // 전환 컨텍스트
    private struct TransitionContext {
        let tabID: UUID
        weak var webView: WKWebView?
        weak var stateModel: WebViewStateModel?
        var isGesture: Bool
        var direction: NavigationDirection
        var initialTransform: CGAffineTransform
        var previewContainer: UIView?
        var currentSnapshot: UIImage?
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    enum CaptureType {
        case immediate  // 현재 페이지 (높은 우선순위)
        case background // 과거 페이지 (일반 우선순위)
    }
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (강화된 스크롤 감지)**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    // 중복 방지를 위한 진행 중인 캡처 추적
    private var pendingCaptures: Set<UUID> = []
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        // 🌐 캡처 대상 사이트 로그
        dbg("🔍 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 중복 캡처 방지 (진행 중인 것만)
        guard !pendingCaptures.contains(pageID) else {
            dbg("⏸️ 중복 캡처 방지: \(task.pageRecord.title)")
            return
        }
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 진행 중 표시
        pendingCaptures.insert(pageID)
        dbg("🎯 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🔧 **개선된 캡처 로직 - 실패 시 재시도**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
        )
        
        // 🌐 캡처된 jsState 로그
        if let jsState = captureResult.snapshot.jsState {
            dbg("🔍 캡처된 jsState 키: \(Array(jsState.keys))")
            if let scrollData = jsState["scroll"] as? [String: Any],
               let elements = scrollData["elements"] as? [[String: Any]] {
                dbg("🔍 캡처된 스크롤 요소: \(elements.count)개")
            }
        }
        
        // 캐처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        // 진행 중 해제
        pendingCaptures.remove(pageID)
        dbg("✅ 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔧 **실패 복구 기능 추가된 캡처 - 🚀 재시도 대기시간 최적화**
    private func performRobustCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기 - 🚀 80ms → 60ms (-20ms)
            dbg("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.06) // 🚀 0.08초 → 0.06초 (-20ms)
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드) - 캡처 타임아웃은 그대로 유지
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    // Fallback: layer 렌더링
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                semaphore.signal()
            }
        }
        
        // ⚡ 캡처 타임아웃 그대로 유지 (3초)
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처 - 캡처 타임아웃 그대로 유지 (1초)
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 🚫 **눌린 상태/활성 상태 모두 제거**
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(el => {
                        el.classList.remove(...Array.from(el.classList).filter(c => 
                            c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus')
                        ));
                    });
                    
                    // input focus 제거
                    document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(el => {
                        el.blur();
                    });
                    
                    const html = document.documentElement.outerHTML;
                    return html.length > 100000 ? html.substring(0, 100000) : html;
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                domSnapshot = result as? String
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 1.0) // 캡처 타임아웃 그대로 유지
        
        // 3. 🔍 **강화된 JS 상태 캡처 - 범용 스크롤 감지** - 캡처 타임아웃 그대로 유지 (2초)
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = generateEnhancedScrollCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 2.0) // 캡처 타임아웃 그대로 유지
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 버전 증가 (스레드 안전)
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            jsState: jsState,
            timestamp: Date(),
            webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
            captureStatus: captureStatus,
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🔍 **핵심 개선: 범용 스크롤 감지 JavaScript 생성 - 🚀 동적 콘텐츠 대기시간 최적화**
    private func generateEnhancedScrollCaptureScript() -> String {
        return """
        (function() {
            return new Promise(resolve => {
                // 🌐 **동적 콘텐츠 로딩 대기 (MutationObserver 활용) - 🚀 최적화 적용**
                function waitForDynamicContent(callback) {
                    let timeout;
                    const observer = new MutationObserver(() => {
                        clearTimeout(timeout);
                        timeout = setTimeout(() => {
                            observer.disconnect();
                            callback();
                        }, 120); // 🚀 150ms → 120ms (-30ms)
                    });
                    observer.observe(document.body, { childList: true, subtree: true });
                    setTimeout(() => {
                        observer.disconnect();
                        callback();
                    }, 2200); // 🚀 최대 2.2초 대기 (2500ms → 2200ms, -300ms)
                }

                function captureScrollData() {
                    try {
                        // 🔍 **1단계: 범용 스크롤 요소 스캔**
                        function findAllScrollableElements() {
                            const scrollables = [];
                            const maxElements = 50; // 성능 고려 제한
                            
                            // 1) 명시적 overflow 스타일을 가진 요소들
                            const explicitScrollables = document.querySelectorAll('*');
                            let count = 0;
                            
                            for (const el of explicitScrollables) {
                                if (count >= maxElements) break;
                                
                                const style = window.getComputedStyle(el);
                                const overflowY = style.overflowY;
                                const overflowX = style.overflowX;
                                
                                // 스크롤 가능한 요소 판별
                                if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                                    (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) {
                                    
                                    // 현재 스크롤 위치가 0이 아닌 경우만 저장
                                    if (el.scrollTop > 0 || el.scrollLeft > 0) {
                                        const selector = generateBestSelector(el);
                                        if (selector) {
                                            // 🌐 동적 콘텐츠 식별을 위한 데이터 속성 저장
                                            const dynamicAttrs = {};
                                            for (const attr of el.attributes) {
                                                if (attr.name.startsWith('data-')) {
                                                    dynamicAttrs[attr.name] = attr.value;
                                                }
                                            }
                                            scrollables.push({
                                                selector: selector,
                                                top: el.scrollTop,
                                                left: el.scrollLeft,
                                                maxTop: el.scrollHeight - el.clientHeight,
                                                maxLeft: el.scrollWidth - el.clientWidth,
                                                id: el.id || '',
                                                className: el.className || '',
                                                tagName: el.tagName.toLowerCase(),
                                                dynamicAttrs: dynamicAttrs // 🌐 동적 속성 추가
                                            });
                                            count++;
                                        }
                                    }
                                }
                            }
                            
                            // 🌐 2) 무한 스크롤 사이트에 흔한 컨테이너들 (디시인사이드, 네이버 카페 고려)
                            const commonScrollContainers = [
                                '.scroll-container', '.scrollable', '.content', '.main', '.body',
                                '[data-scroll]', '[data-scrollable]', '.overflow-auto', '.overflow-scroll',
                                '.list', '.feed', '.timeline', '.board', '.gallery', '.gall_list', '.article-board'
                            ];
                            
                            for (const selector of commonScrollContainers) {
                                if (count >= maxElements) break;
                                
                                const elements = document.querySelectorAll(selector);
                                for (const el of elements) {
                                    if (count >= maxElements) break;
                                    
                                    if ((el.scrollTop > 0 || el.scrollLeft > 0) && 
                                        !scrollables.some(s => s.selector === generateBestSelector(el))) {
                                        
                                        // 🌐 동적 속성 수집
                                        const dynamicAttrs = {};
                                        for (const attr of el.attributes) {
                                            if (attr.name.startsWith('data-')) {
                                                dynamicAttrs[attr.name] = attr.value;
                                            }
                                        }
                                        
                                        scrollables.push({
                                            selector: generateBestSelector(el) || selector,
                                            top: el.scrollTop,
                                            left: el.scrollLeft,
                                            maxTop: el.scrollHeight - el.clientHeight,
                                            maxLeft: el.scrollWidth - el.clientWidth,
                                            id: el.id || '',
                                            className: el.className || '',
                                            tagName: el.tagName.toLowerCase(),
                                            dynamicAttrs: dynamicAttrs
                                        });
                                        count++;
                                    }
                                }
                            }
                            
                            return scrollables;
                        }
                        
                        // 🖼️ **2단계: iframe 스크롤 감지 (Same-Origin + Cross-origin 대응)**
                        function detectIframeScrolls() {
                            const iframes = [];
                            const iframeElements = document.querySelectorAll('iframe');
                            
                            for (const iframe of iframeElements) {
                                try {
                                    // Same-origin 체크
                                    const contentWindow = iframe.contentWindow;
                                    if (contentWindow && contentWindow.location) {
                                        const scrollX = contentWindow.scrollX || 0;
                                        const scrollY = contentWindow.scrollY || 0;
                                        
                                        if (scrollX > 0 || scrollY > 0) {
                                            // 🌐 동적 속성 수집
                                            const dynamicAttrs = {};
                                            for (const attr of iframe.attributes) {
                                                if (attr.name.startsWith('data-')) {
                                                    dynamicAttrs[attr.name] = attr.value;
                                                }
                                            }
                                            
                                            iframes.push({
                                                selector: generateBestSelector(iframe) || `iframe[src*="${iframe.src.split('/').pop()}"]`,
                                                scrollX: scrollX,
                                                scrollY: scrollY,
                                                src: iframe.src || '',
                                                id: iframe.id || '',
                                                className: iframe.className || '',
                                                dynamicAttrs: dynamicAttrs
                                            });
                                        }
                                    }
                                } catch(e) {
                                    // 🌐 Cross-origin iframe도 기본 정보 저장 (복원 시 postMessage 활용)
                                    const dynamicAttrs = {};
                                    for (const attr of iframe.attributes) {
                                        if (attr.name.startsWith('data-')) {
                                            dynamicAttrs[attr.name] = attr.value;
                                        }
                                    }
                                    
                                    // iframe 추정 스크롤 (외부에서 추정 불가하므로 0으로 기록)
                                    iframes.push({
                                        selector: generateBestSelector(iframe) || `iframe[src*="${iframe.src.split('/').pop() || 'unknown'}"]`,
                                        scrollX: 0,
                                        scrollY: 0,
                                        src: iframe.src || '',
                                        id: iframe.id || '',
                                        className: iframe.className || '',
                                        dynamicAttrs: dynamicAttrs,
                                        crossOrigin: true
                                    });
                                    console.log('🌐 Cross-origin iframe 기록:', iframe.src);
                                }
                            }
                            
                            return iframes;
                        }
                        
                        // 🌐 **개선된 셀렉터 생성** - 동적 사이트 대응
                        function generateBestSelector(element) {
                            if (!element || element.nodeType !== 1) return null;
                            
                            // 1순위: ID가 있으면 ID 사용
                            if (element.id) {
                                return `#${element.id}`;
                            }
                            
                            // 🌐 2순위: 데이터 속성 기반 (동적 사이트에서 중요)
                            const dataAttrs = Array.from(element.attributes)
                                .filter(attr => attr.name.startsWith('data-'))
                                .map(attr => `[${attr.name}="${attr.value}"]`);
                            if (dataAttrs.length > 0) {
                                const attrSelector = element.tagName.toLowerCase() + dataAttrs.join('');
                                if (document.querySelectorAll(attrSelector).length === 1) {
                                    return attrSelector;
                                }
                            }
                            
                            // 3순위: 고유한 클래스 조합
                            if (element.className) {
                                const classes = element.className.trim().split(/\\s+/);
                                const uniqueClasses = classes.filter(cls => {
                                    const elements = document.querySelectorAll(`.${cls}`);
                                    return elements.length === 1 && elements[0] === element;
                                });
                                
                                if (uniqueClasses.length > 0) {
                                    return `.${uniqueClasses.join('.')}`;
                                }
                                
                                // 클래스 조합으로 고유성 확보
                                if (classes.length > 0) {
                                    const classSelector = `.${classes.join('.')}`;
                                    if (document.querySelectorAll(classSelector).length === 1) {
                                        return classSelector;
                                    }
                                }
                            }
                            
                            // 🌐 4순위: 상위 경로 포함 (동적 사이트의 복잡한 DOM 구조 대응)
                            let path = [];
                            let current = element;
                            while (current && current !== document.documentElement) {
                                let selector = current.tagName.toLowerCase();
                                if (current.id) {
                                    path.unshift(`#${current.id}`);
                                    break;
                                }
                                if (current.className) {
                                    const classes = current.className.trim().split(/\\s+/).join('.');
                                    selector += `.${classes}`;
                                }
                                path.unshift(selector);
                                current = current.parentElement;
                                
                                // 경로가 너무 길어지면 중단
                                if (path.length > 5) break;
                            }
                            return path.join(' > ');
                        }
                        
                        // 🔍 **메인 실행**
                        const scrollableElements = findAllScrollableElements();
                        const iframeScrolls = detectIframeScrolls();
                        
                        console.log(`🌐 동적 사이트 스크롤 요소 감지: 일반 ${scrollableElements.length}개, iframe ${iframeScrolls.length}개`);
                        
                        resolve({
                            scroll: { 
                                x: window.scrollX, 
                                y: window.scrollY,
                                elements: scrollableElements
                            },
                            iframes: iframeScrolls,
                            href: window.location.href,
                            title: document.title,
                            timestamp: Date.now(),
                            userAgent: navigator.userAgent,
                            viewport: {
                                width: window.innerWidth,
                                height: window.innerHeight
                            }
                        });
                    } catch(e) { 
                        console.error('🌐 동적 사이트 스크롤 감지 실패:', e);
                        resolve({
                            scroll: { x: window.scrollX, y: window.scrollY, elements: [] },
                            iframes: [],
                            href: window.location.href,
                            title: document.title
                        });
                    }
                }

                // 🌐 동적 콘텐츠 완료 대기 후 캡처
                if (document.readyState === 'complete') {
                    waitForDynamicContent(captureScrollData);
                } else {
                    document.addEventListener('DOMContentLoaded', () => waitForDynamicContent(captureScrollData));
                }
            });
        })()
        """
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 **개선된 디스크 저장 시스템**
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            // 디렉토리 생성
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // 1. 이미지 저장 (JPEG 압축)
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    do {
                        try jpegData.write(to: imagePath)
                        finalSnapshot.webViewSnapshotPath = imagePath.path
                        self.dbg("💾 이미지 저장 성공: \(imagePath.lastPathComponent)")
                    } catch {
                        self.dbg("❌ 이미지 저장 실패: \(error.localizedDescription)")
                        // 저장 실패해도 계속 진행
                    }
                }
            }
            
            // 2. 상태 데이터 저장 (JSON)
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                do {
                    try stateData.write(to: statePath)
                    self.dbg("💾 상태 저장 성공: \(statePath.lastPathComponent)")
                } catch {
                    self.dbg("❌상태 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 3. 메타데이터 저장
            let metadata = CacheMetadata(
                pageID: pageID,
                tabID: tabID,
                version: version,
                timestamp: Date(),
                url: snapshot.snapshot.pageRecord.url.absoluteString,
                title: snapshot.snapshot.pageRecord.title
            )
            
            let metadataPath = pageDir.appendingPathComponent("metadata.json")
            if let metadataData = try? JSONEncoder().encode(metadata) {
                do {
                    try metadataData.write(to: metadataPath)
                } catch {
                    self.dbg("❌ 메타데이터 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 4. 인덱스 업데이트 (원자적)
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
            // 5. 이전 버전 정리 (최신 3개만 유지)
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
        }
    }
    
    private struct CacheMetadata: Codable {
        let pageID: UUID
        let tabID: UUID
        let version: Int
        let timestamp: Date
        let url: String
        let title: String
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private func cleanupOldVersions(pageID: UUID, tabID: UUID, currentVersion: Int) {
        let tabDir = tabDirectory(for: tabID)
        let pagePrefix = "Page_\(pageID.uuidString)_v"
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil)
            let pageDirs = contents.filter { $0.lastPathComponent.hasPrefix(pagePrefix) }
                .sorted { url1, url2 in
                    // 버전 번호 추출하여 정렬
                    let v1 = Int(url1.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    let v2 = Int(url2.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    return v1 > v2  // 최신 버전부터
                }
            
            // 최신 3개 제외하고 삭제
            if pageDirs.count > 3 {
                for i in 3..<pageDirs.count {
                    try FileManager.default.removeItem(at: pageDirs[i])
                    dbg("🗑️ 이전 버전 삭제: \(pageDirs[i].lastPathComponent)")
                }
            }
        } catch {
            dbg("⚠️ 이전 버전 정리 실패: \(error)")
        }
    }
    
    // MARK: - 💾 **개선된 디스크 캐시 로딩**
    
    private func loadDiskCacheIndex() {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            // BFCache 디렉토리 생성
            self.createDirectoryIfNeeded(at: self.bfCacheDirectory)
            
            var loadedCount = 0
            
            // 모든 탭 디렉토리 스캔
            do {
                let tabDirs = try FileManager.default.contentsOfDirectory(at: self.bfCacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                
                for tabDir in tabDirs {
                    if tabDir.lastPathComponent.hasPrefix("Tab_") {
                        // 각 페이지 디렉토리 스캔
                        let pageDirs = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        
                        for pageDir in pageDirs {
                            if pageDir.lastPathComponent.hasPrefix("Page_") {
                                // metadata.json 로드
                                let metadataPath = pageDir.appendingPathComponent("metadata.json")
                                if let data = try? Data(contentsOf: metadataPath),
                                   let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) {
                                    
                                    // 스레드 안전하게 인덱스 업데이트
                                    self.setDiskIndex(pageDir.path, for: metadata.pageID)
                                    self.cacheAccessQueue.async(flags: .barrier) {
                                        self._cacheVersion[metadata.pageID] = metadata.version
                                    }
                                    loadedCount += 1
                                }
                            }
                        }
                    }
                }
                
                self.dbg("💾 디스크 캐시 인덱스 로드 완료: \(loadedCount)개 항목")
            } catch {
                self.dbg("❌ 디스크 캐시 로드 실패: \(error)")
            }
        }
    }
    
    // MARK: - 🔄 **사이트별 타이밍 프로파일 관리**
    
    private func loadSiteTimingProfiles() {
        if let data = UserDefaults.standard.data(forKey: "BFCache.SiteTimingProfiles"),
           let profiles = try? JSONDecoder().decode([String: SiteTimingProfile].self, from: data) {
            cacheAccessQueue.async(flags: .barrier) {
                self._siteTimingProfiles = profiles
            }
            dbg("🔄 사이트 타이밍 프로파일 로드: \(profiles.count)개")
        }
    }
    
    private func saveSiteTimingProfiles() {
        let profiles = cacheAccessQueue.sync { _siteTimingProfiles }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "BFCache.SiteTimingProfiles")
        }
    }
    
    // MARK: - 🔍 **개선된 스냅샷 조회 시스템**
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        // 1. 먼저 메모리 캐시 확인 (스레드 안전)
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인 (스레드 안전)
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장 (최적화)
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title)")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
    // MARK: - 🔧 **수정: hasCache 메서드 추가**
    func hasCache(for pageID: UUID) -> Bool {
        // 메모리 캐시 체크
        if cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) != nil {
            return true
        }
        
        // 디스크 캐시 인덱스 체크
        if cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) != nil {
            return true
        }
        
        return false
    }
    
    // MARK: - 메모리 캐시 관리
    
    private func storeInMemory(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        setMemoryCache(snapshot, for: pageID)
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)]")
    }
    
    // MARK: - 🧹 **개선된 캐시 정리**
    
    // 탭 닫을 때만 호출 (무제한 캐시 정책)
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        // 🧵 제스처 컨텍스트 정리
        removeGestureContext(for: tabID)
        removeActiveTransition(for: tabID)
        
        // 메모리에서 제거 (스레드 안전)
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
                self._cacheVersion.removeValue(forKey: pageID)
            }
        }
        
        // 디스크에서 제거
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            let tabDir = self.tabDirectory(for: tabID)
            do {
                try FileManager.default.removeItem(at: tabDir)
                self.dbg("🗑️ 탭 캐시 완전 삭제: \(tabID.uuidString)")
            } catch {
                self.dbg("⚠️ 탭 캐시 삭제 실패: \(error)")
            }
        }
    }
    
    // 메모리 경고 처리 (메모리 캐시만 일부 정리)
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }
    
    private func handleMemoryWarning() {
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let beforeCount = self._memoryCache.count
            
            // 메모리 캐시의 절반 정리 (오래된 것부터)
            let sorted = self._memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            self.dbg("⚠️ 메모리 경고 - 메모리 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🧵 **리팩토링된 제스처 시스템 (먹통 방지)**
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        // 네이티브 제스처 비활성화
        webView.allowsBackForwardNavigationGestures = false
        
        guard let tabID = stateModel.tabID else {
            dbg("🧵 탭 ID 없음 - 제스처 설정 스킵")
            return
        }
        
        // 🧵 **기존 제스처 정리 (중복 방지)**
        cleanupExistingGestures(for: webView, tabID: tabID)
        
        // 🧵 **새로운 제스처 컨텍스트 생성**
        let gestureContext = GestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
        setGestureContext(gestureContext, for: tabID)
        
        // 🧵 **메인 스레드에서 제스처 생성 및 설정**
        DispatchQueue.main.async { [weak self] in
            self?.createAndAttachGestures(webView: webView, tabID: tabID)
        }
        
        // 📸 **포괄적 네비게이션 감지 등록**
        Self.registerNavigationObserver(for: webView, stateModel: stateModel)
        
        dbg("🧵 프레임 기반 BFCache 제스처 설정 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 🧵 **기존 제스처 정리**
    private func cleanupExistingGestures(for webView: WKWebView, tabID: UUID) {
        // 기존 제스처 컨텍스트 무효화
        removeGestureContext(for: tabID)
        
        // 웹뷰에서 기존 BFCache 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if let edgeGesture = gesture as? UIScreenEdgePanGestureRecognizer,
               edgeGesture.edges == .left || edgeGesture.edges == .right {
                webView.removeGestureRecognizer(gesture)
                dbg("🧵 기존 제스처 제거: \(edgeGesture.edges)")
            }
        }
    }
    
    // 🧵 **제스처 생성 및 연결**
    private func createAndAttachGestures(webView: WKWebView, tabID: UUID) {
        // 왼쪽 엣지 - 뒤로가기
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        
        // 오른쪽 엣지 - 앞으로가기  
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        
        // 🧵 **제스처에 탭 ID 연결 (컨텍스트 검색용)**
        objc_setAssociatedObject(leftEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(rightEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        webView.addGestureRecognizer(leftEdge)
        webView.addGestureRecognizer(rightEdge)
        
        dbg("🧵 제스처 연결 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 🧵 **리팩토링된 제스처 핸들러 (메인 스레드 최적화)**
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        // 🧵 **메인 스레드 확인 및 강제 이동**
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleGesture(gesture)
            }
            return
        }
        
        // 🧵 **제스처에서 탭 ID 조회**
        guard let tabIDString = objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String,
              let tabID = UUID(uuidString: tabIDString) else {
            dbg("🧵 제스처에서 탭 ID 조회 실패")
            gesture.state = .cancelled
            return
        }
        
        // 🧵 **컨텍스트 유효성 검사 및 조회**
        guard let context = getGestureContext(for: tabID) else {
            dbg("🧵 제스처 컨텍스트 없음 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
            gesture.state = .cancelled
            return
        }
        
        // 🧵 **컨텍스트 내에서 안전하게 실행**
        context.validateAndExecute { [weak self] in
            guard let self = self,
                  let webView = context.webView,
                  let stateModel = context.stateModel else {
                TabPersistenceManager.debugMessages.append("🧵 컨텍스트 무효 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
                gesture.state = .cancelled
                return
            }
            
            self.processGestureState(
                gesture: gesture,
                tabID: tabID,
                webView: webView,
                stateModel: stateModel
            )
        }
    }
    
    // 🧵 **제스처 상태 처리 (핵심 로직은 그대로 유지)**
    private func processGestureState(gesture: UIScreenEdgePanGestureRecognizer, tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        let width = gesture.view?.bounds.width ?? 1
        
        // 수직 슬롭/부호 반대 방지
        let absX = abs(translation.x), absY = abs(translation.y)
        let horizontalEnough = absX > 8 && absX > absY
        let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
        
        switch gesture.state {
        case .began:
            // 🛡️ **전환 중이면 새 제스처 무시**
            guard getActiveTransition(for: tabID) == nil else { 
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 🛡️ **기존 전환 강제 정리**
                if let existing = getActiveTransition(for: tabID) {
                    existing.previewContainer?.removeFromSuperview()
                    removeActiveTransition(for: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                // 현재 페이지 즉시 캐시 (높은 우선순위)
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                }
                
                // 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
                captureCurrentSnapshot(webView: webView) { [weak self] snapshot in
                    DispatchQueue.main.async {
                        self?.beginGestureTransitionWithSnapshot(
                            tabID: tabID,
                            webView: webView,
                            stateModel: stateModel,
                            direction: direction,
                            currentSnapshot: snapshot
                        )
                    }
                }
            } else {
                gesture.state = .cancelled
            }
            
        case .changed:
            guard horizontalEnough && signOK else { return }
            updateGestureProgress(tabID: tabID, translation: translation.x, isLeftEdge: isLeftEdge)
            
        case .ended:
            let progress = min(1.0, absX / width)
            let shouldComplete = progress > 0.3 || abs(velocity.x) > 800
            if shouldComplete {
                completeGestureTransition(tabID: tabID)
            } else {
                cancelGestureTransition(tabID: tabID)
            }
            
        case .cancelled, .failed:
            cancelGestureTransition(tabID: tabID)
            
        default:
            break
        }
    }
    
    // MARK: - 🎯 **나머지 제스처/전환 로직 (기존 유지)**
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let captureConfig = WKSnapshotConfiguration()
        captureConfig.rect = webView.bounds
        captureConfig.afterScreenUpdates = false
        
        webView.takeSnapshot(with: captureConfig) { image, error in
            if let error = error {
                self.dbg("📸 현재 페이지 스냅샷 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let fallbackImage = self.renderWebViewToImage(webView)
                    completion(fallbackImage)
                }
            } else {
                completion(image)
            }
        }
    }
    
    private func beginGestureTransitionWithSnapshot(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection, currentSnapshot: UIImage?) {
        let initialTransform = webView.transform
        
        let previewContainer = createPreviewContainer(
            webView: webView,
            direction: direction,
            stateModel: stateModel,
            currentSnapshot: currentSnapshot
        )
        
        let context = TransitionContext(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            isGesture: true,
            direction: direction,
            initialTransform: initialTransform,
            previewContainer: previewContainer,
            currentSnapshot: currentSnapshot
        )
        setActiveTransition(context, for: tabID)
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = getActiveTransition(for: tabID),
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentWebView = previewContainer.viewWithTag(1001)
        let targetPreview = previewContainer.viewWithTag(1002)
        
        if isLeftEdge {
            let moveDistance = max(0, min(screenWidth, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = -screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (moveDistance / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        } else {
            let moveDistance = max(-screenWidth, min(0, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (abs(moveDistance) / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        }
    }
    
    private func createPreviewContainer(webView: WKWebView, direction: NavigationDirection, stateModel: WebViewStateModel, currentSnapshot: UIImage? = nil) -> UIView {
        let container = UIView(frame: webView.bounds)
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        
        // 현재 웹뷰 스냅샷 사용
        let currentView: UIView
        if let snapshot = currentSnapshot {
            let imageView = UIImageView(image: snapshot)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            currentView = imageView
        } else {
            if let fallbackImage = renderWebViewToImage(webView) {
                let imageView = UIImageView(image: fallbackImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                currentView = imageView
            } else {
                currentView = UIView(frame: webView.bounds)
                currentView.backgroundColor = .systemBackground
            }
        }
        
        currentView.frame = webView.bounds
        currentView.tag = 1001
        
        // 그림자 설정
        currentView.layer.shadowColor = UIColor.black.cgColor
        currentView.layer.shadowOpacity = 0.3
        currentView.layer.shadowOffset = CGSize(width: direction == .back ? -5 : 5, height: 0)
        currentView.layer.shadowRadius = 10
        
        container.addSubview(currentView)
        
        // 타겟 페이지 미리보기
        let targetIndex = direction == .back ?
            stateModel.dataModel.currentPageIndex - 1 :
            stateModel.dataModel.currentPageIndex + 1
        
        var targetView: UIView
        
        if targetIndex >= 0, targetIndex < stateModel.dataModel.pageHistory.count {
            let targetRecord = stateModel.dataModel.pageHistory[targetIndex]
            
            if let snapshot = retrieveSnapshot(for: targetRecord.id),
               let targetImage = snapshot.loadImage() {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
                dbg("📸 타겟 페이지 BFCache 스냅샷 사용: \(targetRecord.title)")
            } else {
                targetView = createInfoCard(for: targetRecord, in: webView.bounds)
                dbg("ℹ️ 타겟 페이지 정보 카드 생성: \(targetRecord.title)")
            }
        } else {
            targetView = UIView()
            targetView.backgroundColor = .systemBackground
        }
        
        targetView.frame = webView.bounds
        targetView.tag = 1002
        
        if direction == .back {
            targetView.frame.origin.x = -webView.bounds.width
        } else {
            targetView.frame.origin.x = webView.bounds.width
        }
        
        container.insertSubview(targetView, at: 0)
        webView.addSubview(container)
        return container
    }
    
    private func createInfoCard(for record: PageRecord, in bounds: CGRect) -> UIView {
        let card = UIView(frame: bounds)
        card.backgroundColor = .systemBackground
        
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 12
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.1
        contentView.layer.shadowOffset = CGSize(width: 0, height: 2)
        contentView.layer.shadowRadius = 8
        card.addSubview(contentView)
        
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "globe")
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        contentView.addSubview(iconView)
        
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = record.title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)
        
        let urlLabel = UILabel()
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.text = record.url.host ?? record.url.absoluteString
        urlLabel.font = .systemFont(ofSize: 14)
        urlLabel.textColor = .secondaryLabel
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 1
        contentView.addSubview(urlLabel)
        
        let timeLabel = UILabel()
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        timeLabel.text = formatter.string(from: record.lastAccessed)
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.textAlignment = .center
        contentView.addSubview(timeLabel)
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 180),
            
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            timeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            timeLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
        
        return card
    }
    
    // 🎬 **핵심 개선: 미리보기 컨테이너 타임아웃 제거 - 제스처 먹통 해결**
    private func completeGestureTransition(tabID: UUID) {
        guard let context = getActiveTransition(for: tabID),
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                if context.direction == .back {
                    currentView?.frame.origin.x = screenWidth
                    targetView?.frame.origin.x = 0
                } else {
                    currentView?.frame.origin.x = -screenWidth
                    targetView?.frame.origin.x = 0
                }
                currentView?.layer.shadowOpacity = 0
            },
            completion: { [weak self] _ in
                // 🎬 **프레임 기반 적응형 타이밍으로 네비게이션 수행**
                self?.performNavigationWithFrameBasedTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🔄 **프레임 기반 적응형 타이밍을 적용한 네비게이션 수행 - 타임아웃 제거**
    private func performNavigationWithFrameBasedTiming(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            // 실패 시 즉시 정리
            previewContainer.removeFromSuperview()
            removeActiveTransition(for: context.tabID)
            return
        }
        
        // 로딩 시간 측정 시작
        let navigationStartTime = Date()
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // 🔄 **프레임 기반 BFCache 복원 + 타이밍 학습**
        tryFrameBasedBFCacheRestore(stateModel: stateModel, direction: context.direction, navigationStartTime: navigationStartTime) { [weak self] success in
            // BFCache 복원 완료 또는 실패 시 즉시 정리 (깜빡임 최소화)
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.removeActiveTransition(for: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - 프레임 기반 BFCache \(success ? "성공" : "실패")")
            }
        }
        
        dbg("🎬 미리보기 타임아웃 제거됨 - 프레임 기반 처리")
    }
    
    // 🔄 **프레임 기반 BFCache 복원 + 타이밍 학습** 
    private func tryFrameBasedBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, navigationStartTime: Date, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // 사이트별 프로파일 조회/생성
        var siteProfile = getSiteProfile(for: currentRecord.url) ?? SiteTimingProfile(hostname: currentRecord.url.host ?? "unknown")
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 프레임 기반 복원
            snapshot.restore(to: webView, siteProfile: siteProfile) { [weak self] success in
                // 로딩 시간 기록
                let loadingDuration = Date().timeIntervalSince(navigationStartTime)
                siteProfile.recordLoadingTime(loadingDuration)
                siteProfile.recordRestoreAttempt(success: success)
                self?.updateSiteProfile(siteProfile)
                
                if success {
                    self?.dbg("✅ 프레임 기반 BFCache 복원 성공: \(currentRecord.title) (소요: \(String(format: "%.2f", loadingDuration))초)")
                } else {
                    self?.dbg("⚠️ 프레임 기반 BFCache 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 기본 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            let loadingDuration = Date().timeIntervalSince(navigationStartTime)
            siteProfile.recordLoadingTime(loadingDuration)
            siteProfile.recordRestoreAttempt(success: false)
            updateSiteProfile(siteProfile)
            
            // 🚀 **프레임 기반 기본 대기 시간 (고정 지연 대신 적응형)**
            let waitTime = siteProfile.getAdaptiveWaitTime(step: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                completion(false)
            }
        }
    }
    

    private func cancelGestureTransition(tabID: UUID) {
        guard let context = getActiveTransition(for: tabID),
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.25,
            animations: {
                currentView?.frame.origin.x = 0
                
                if context.direction == .back {
                    targetView?.frame.origin.x = -screenWidth
                } else {
                    targetView?.frame.origin.x = screenWidth
                }
                
                currentView?.layer.shadowOpacity = 0.3
            },
            completion: { _ in
                previewContainer.removeFromSuperview()
                self.removeActiveTransition(for: tabID)
            }
        )
    }
    
    // MARK: - 버튼 네비게이션 (즉시 전환)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캐시 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryFrameBasedBFCacheRestore(stateModel: stateModel, direction: .back, navigationStartTime: Date()) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캐시 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        tryFrameBasedBFCacheRestore(stateModel: stateModel, direction: .forward, navigationStartTime: Date()) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    // MARK: - 스와이프 제스처 감지 처리 (DataModel에서 이관)
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        // 복원 중이면 무시
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        // 절대 원칙: 히스토리에서 찾더라도 무조건 새 페이지로 추가
        // 세션 점프 완전 방지
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가 (과거 점프 방지): \(url.absoluteString)")
    }
    
    // MARK: - 🌐 JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        // 🚀 **Step 1: 브라우저 자동 스크롤 복원/앵커링 사전 차단**
        try { 
            if ('scrollRestoration' in history) { 
                history.scrollRestoration = 'manual'; 
            } 
        } catch(e) {}
        
        try {
            const s=document.createElement('style');
            s.textContent='html,body{scroll-behavior:auto !important; overflow-anchor:none !important;} *{scroll-behavior:auto !important;}';
            document.documentElement.appendChild(s);
        } catch(e) {}
        
        // 🚀 **Step 2: 기존 BFCache 이벤트 처리**
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔄 BFCache 페이지 복원');
                
                // 🌐 동적 콘텐츠 새로고침 (필요시)
                if (window.location.pathname.includes('/feed') ||
                    window.location.pathname.includes('/timeline') ||
                    window.location.hostname.includes('twitter') ||
                    window.location.hostname.includes('facebook') ||
                    window.location.hostname.includes('dcinside') ||
                    window.location.hostname.includes('cafe.naver')) {
                    if (window.refreshDynamicContent) {
                        window.refreshDynamicContent();
                    }
                }
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 BFCache 페이지 저장');
            }
        });
        
        // 🌐 Cross-origin iframe 스크롤 복원 리스너
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                try {
                    window.scrollTo(event.data.scrollX || 0, event.data.scrollY || 0);
                    console.log('🌐 Cross-origin iframe 스크롤 복원:', event.data.scrollX, event.data.scrollY);
                } catch(e) {
                    console.error('Cross-origin iframe 스크롤 복원 실패:', e);
                }
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[순차스크롤복원] \(msg)")
    }
}

// MARK: - UIGestureRecognizerDelegate
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - CustomWebView 통합 인터페이스
extension BFCacheTransitionSystem {
    
    // CustomWebView의 makeUIView에서 호출
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        // BFCache 스크립트 설치
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        
        // 🔧 **Promise 브릿지 등록**
        webView.configuration.userContentController.add(shared, name: "bfcache")
        
        // 제스처 설치 + 📸 포괄적 네비게이션 감지
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ 🔧 순차 실행 스크롤 복원 BFCache 시스템 설치 완료 (실행→확인→실행 구조)")
    }
    
    // CustomWebView의 dismantleUIView에서 호출
    static func uninstall(from webView: WKWebView) {
        // 🧵 제스처 해제
        if let tabIDString = webView.gestureRecognizers?.compactMap({ gesture in
            objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String
        }).first, let tabID = UUID(uuidString: tabIDString) {
            shared.removeGestureContext(for: tabID)
            shared.removeActiveTransition(for: tabID)
        }
        
        // 📸 **네비게이션 감지 해제**
        unregisterNavigationObserver(for: webView)
        
        // 🔧 **Promise 브릿지 해제**
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bfcache")
        
        // 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        TabPersistenceManager.debugMessages.append("🔧 순차 스크롤 복원 시스템 제거 완료")
    }
    
    // 버튼 네비게이션 래퍼
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
}

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출
extension BFCacheTransitionSystem {

    /// 사용자가 링크/폼으로 **떠나기 직전** 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 즉시 캐시 (최고 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📸 떠나기 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화 - 🚀 도착 스냅샷 최적화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 캐시 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
        // 이전 페이지들도 순차적으로 캐시 확인 및 캐처
        if stateModel.dataModel.currentPageIndex > 0 {
            // 최근 3개 페이지만 체크 (성능 고려)
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                // 캐시가 없는 경우만 메타데이터 저장
                if !hasCache(for: previousRecord.id) {
                    // 메타데이터만 저장 (이미지는 없음)
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollPosition: .zero,
                        timestamp: Date(),
                        captureStatus: .failed,
                        version: 1
                    )
                    
                    // 디스크에 메타데이터만 저장
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
