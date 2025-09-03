//
//  BFCacheSwipeTransition.swift
//  🔥 **네이티브 강제 복원 BFCache 시스템 - 스크롤 복원 개선판**
//  ✅ 사파리/네이버카페 방식 모방 - WKWebView 네이티브 처리
//  🎯 개선된 타이머 기반 연속 복원 (지연 시작 + 강화된 네이티브 우선)
//  📊 비율 기반 저장 (절대좌표 → 상대비율)
//  🔍 Intersection Observer 기반 스마트 추적
//  ⚡ JavaScript 스크롤 함수 무력화 강화
//  🚀 성능 최적화: DOM 스캔 제거, 네이티브 우선
//  🔧 **스크롤 복원 대폭 개선**: 지연 로드 완료 대기 + 네이티브 우선 점진적 복원
//  🛡️ **웹페이지 스크롤 간섭 차단**: Observer 기반 실시간 복원 + 더 강력한 JS 무력화
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

// MARK: - 약한 참조 제스처 컨텍스트 (순환 참조 방지)
private class WeakGestureContext {
    let tabID: UUID
    weak var webView: WKWebView?
    weak var stateModel: WebViewStateModel?
    
    init(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        self.tabID = tabID
        self.webView = webView
        self.stateModel = stateModel
    }
}

// MARK: - 🔄 적응형 타이밍 학습 시스템
struct SiteTimingProfile: Codable {
    let hostname: String
    var loadingSamples: [TimeInterval] = []
    var averageLoadingTime: TimeInterval = 0.5
    var successfulRestores: Int = 0
    var totalRestores: Int = 0
    var lastUpdated: Date = Date()
    
    var successRate: Double {
        guard totalRestores > 0 else { return 0.0 }
        return Double(successfulRestores) / Double(totalRestores)
    }
    
    mutating func recordLoadingTime(_ duration: TimeInterval) {
        loadingSamples.append(duration)
        // 최근 10개 샘플만 유지
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
    
    // 적응형 대기 시간 계산
    func getAdaptiveWaitTime(step: Int) -> TimeInterval {
        let baseTime = averageLoadingTime
        let stepMultiplier = Double(step) * 0.1
        let successFactor = successRate > 0.8 ? 0.8 : 1.0 // 성공률 높으면 빠르게
        return (baseTime + stepMultiplier) * successFactor
    }
}

// MARK: - 🔥 **스마트 스크롤 상태** (비율 기반 + 앵커)
struct SmartScrollState: Codable {
    let pageRecord: PageRecord
    
    // 🎯 **비율 기반 위치** (동적 콘텐츠 대응)
    var scrollRatio: Double = 0.0           // 전체 스크롤 비율 (0.0 ~ 1.0)
    var viewportRatio: Double = 0.0         // 뷰포트 내 위치 비율
    
    // 📍 **앵커 요소 정보** (정확한 위치 복원)
    var anchorSelector: String? = nil       // 가장 가까운 고정 요소
    var anchorOffset: Double = 0.0          // 앵커로부터의 오프셋
    var anchorText: String? = nil          // 앵커 요소 텍스트 (검증용)
    
    // 📊 **콘텐츠 메타데이터**
    var contentHeight: Double = 0.0         // 전체 콘텐츠 높이
    var viewportHeight: Double = 0.0        // 뷰포트 높이
    var timestamp: Date = Date()
    
    // 🔍 **Intersection Observer 데이터**
    var visibleElements: [VisibleElement] = []
    
    struct VisibleElement: Codable {
        let selector: String
        let intersectionRatio: Double
        let boundingRect: CGRect
        let text: String?
    }
    
    // 🔥 **절대 좌표는 백업용으로만**
    var absolutePosition: CGPoint = .zero
    
    enum CodingKeys: String, CodingKey {
        case pageRecord, scrollRatio, viewportRatio
        case anchorSelector, anchorOffset, anchorText
        case contentHeight, viewportHeight, timestamp
        case visibleElements, absolutePosition
    }
}

// MARK: - 📸 BFCache 페이지 스냅샷 (네이티브 우선)
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    
    // 🔥 **스마트 스크롤 상태로 교체**
    var smartScrollState: SmartScrollState
    
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
        case smartScrollState
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
        smartScrollState = try container.decode(SmartScrollState.self, forKey: .smartScrollState)
        
        // JSON decode for [String: Any]
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
        try container.encode(smartScrollState, forKey: .smartScrollState)
        
        // JSON encode for [String: Any]
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, smartScrollState: SmartScrollState, domSnapshot: String? = nil, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1) {
        self.pageRecord = pageRecord
        self.smartScrollState = smartScrollState
        self.domSnapshot = domSnapshot
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🔥 **핵심: 대폭 개선된 네이티브 강제 복원 메서드** (지연 로드 완료 대기 + 네이티브 우선 점진적 복원)
    func restore(to webView: WKWebView, siteProfile: SiteTimingProfile?, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🔥 개선된 네이티브 강제 복원 시작")
        
        // 캡처 상태에 따른 복원 전략
        switch captureStatus {
        case .failed:
            completion(false)
            return
            
        case .visualOnly:
            // 절대 좌표로만 즉시 복원
            DispatchQueue.main.async {
                webView.scrollView.setContentOffset(self.smartScrollState.absolutePosition, animated: false)
                TabPersistenceManager.debugMessages.append("🔥 시각적만: 절대 좌표 복원")
                completion(true)
            }
            return
            
        case .partial, .complete:
            break
        }
        
        DispatchQueue.main.async {
            self.performSuperEnhancedNativeForcedRestore(to: webView, completion: completion)
        }
    }
    
    // 🔥 **대폭 개선된 네이티브 강제 복원** - 지연 로드 완료 대기 + 네이티브 우선 점진적 복원
    private func performSuperEnhancedNativeForcedRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let startTime = Date()
        
        // 1️⃣ **더 강력한 JavaScript 스크롤 함수 무력화 + 웹페이지 스크롤 간섭 차단**
        setupAdvancedScrollBlocking(webView: webView) {
            // 2️⃣ **지연된 DOM 준비 상태 확인 및 대기** (더 신중한 타이밍)
            self.waitForAdvancedDOMReady(webView: webView, startTime: startTime, retryCount: 0, completion: completion)
        }
    }
    
    // 🛡️ **더 강력한 JavaScript 스크롤 차단 설정**
    private func setupAdvancedScrollBlocking(webView: WKWebView, completion: @escaping () -> Void) {
        let advancedBlockScript = """
        (function() {
            console.log('🛡️ 고급 스크롤 차단 시작');
            
            // 1. 전역 플래그 설정
            window._bfcache_scroll_blocking = true;
            window._bfcache_target_y = \(smartScrollState.absolutePosition.y);
            window._bfcache_target_ratio = \(smartScrollState.scrollRatio);
            
            // 2. 모든 스크롤 관련 함수 백업 및 무력화
            const originalFunctions = {
                scrollTo: window.scrollTo,
                scrollBy: window.scrollBy,
                scroll: window.scroll
            };
            
            window.scrollTo = function(x, y) {
                if (window._bfcache_scroll_blocking) {
                    console.log('🛡️ scrollTo 차단:', x, y);
                    return;
                }
                return originalFunctions.scrollTo.apply(this, arguments);
            };
            
            window.scrollBy = function(x, y) {
                if (window._bfcache_scroll_blocking) {
                    console.log('🛡️ scrollBy 차단:', x, y);
                    return;
                }
                return originalFunctions.scrollBy.apply(this, arguments);
            };
            
            window.scroll = function(x, y) {
                if (window._bfcache_scroll_blocking) {
                    console.log('🛡️ scroll 차단:', x, y);
                    return;
                }
                return originalFunctions.scroll.apply(this, arguments);
            };
            
            // 3. 히스토리 스크롤 복원 완전 무력화
            if (history.scrollRestoration) {
                history.scrollRestoration = 'manual';
            }
            
            // 4. 스크롤 이벤트 리스너 일시 차단
            const originalAddEventListener = EventTarget.prototype.addEventListener;
            EventTarget.prototype.addEventListener = function(type, listener, options) {
                if (window._bfcache_scroll_blocking && (type === 'scroll' || type === 'wheel' || type === 'touchmove')) {
                    console.log('🛡️ 스크롤 이벤트 리스너 차단:', type);
                    return;
                }
                return originalAddEventListener.call(this, type, listener, options);
            };
            
            // 5. CSS 기반 smooth scroll 무력화
            const style = document.createElement('style');
            style.textContent = `
                *, *::before, *::after {
                    scroll-behavior: auto !important;
                }
                html, body {
                    scroll-behavior: auto !important;
                }
            `;
            document.head.appendChild(style);
            
            // 6. 복원 함수들 저장 (나중에 복구용)
            window._bfcache_restore_functions = {
                scrollTo: originalFunctions.scrollTo,
                scrollBy: originalFunctions.scrollBy,
                scroll: originalFunctions.scroll,
                addEventListener: originalAddEventListener,
                style: style
            };
            
            console.log('🛡️ 고급 스크롤 차단 완료');
            return true;
        })()
        """
        
        webView.evaluateJavaScript(advancedBlockScript) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("⚠️ 고급 스크롤 차단 실패: \(error.localizedDescription)")
            } else {
                TabPersistenceManager.debugMessages.append("🛡️ 고급 스크롤 차단 설정 완료")
            }
            completion()
        }
    }
    
    // 🔥 **더 신중한 DOM 준비 상태 확인 및 대기** (지연된 시작)
    private func waitForAdvancedDOMReady(webView: WKWebView, startTime: Date, retryCount: Int, completion: @escaping (Bool) -> Void) {
        let maxRetries = 8 // 증가
        
        // 첫 번째 체크는 의도적으로 지연 (동적 콘텐츠 로딩 대기)
        let initialDelay = retryCount == 0 ? 0.8 : 0.3
        
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
            let advancedDOMReadyScript = """
            (function() {
                try {
                    // 1. 기본 DOM 준비 확인
                    if (document.readyState !== 'complete') {
                        return { ready: false, reason: 'loading', progress: 0.1 };
                    }
                    
                    // 2. 콘텐츠 높이 확인 (더 신중)
                    const contentHeight = Math.max(
                        document.documentElement.scrollHeight,
                        document.body ? document.body.scrollHeight : 0,
                        document.documentElement.clientHeight
                    );
                    
                    if (contentHeight < 200) { // 최소 높이 증가
                        return { ready: false, reason: 'insufficient_content', progress: 0.2, contentHeight };
                    }
                    
                    // 3. 주요 콘텐츠 요소 확인 (더 엄격)
                    const contentSelectors = [
                        'main', 'article', '#content', '.content', 
                        '.main-content', '[role="main"]', 'body > div'
                    ];
                    const hasMainContent = contentSelectors.some(sel => {
                        const el = document.querySelector(sel);
                        return el && el.offsetHeight > 100;
                    });
                    
                    if (!hasMainContent) {
                        return { ready: false, reason: 'no_significant_content', progress: 0.3 };
                    }
                    
                    // 4. 이미지/미디어 로딩 완료 확인
                    const images = Array.from(document.querySelectorAll('img, video'));
                    const loadedImages = images.filter(img => 
                        img.complete || img.readyState === 4 || img.offsetHeight > 0
                    );
                    const imageLoadRatio = images.length > 0 ? loadedImages.length / images.length : 1;
                    
                    if (imageLoadRatio < 0.5 && images.length > 5) { // 이미지가 많으면 더 대기
                        return { 
                            ready: false, 
                            reason: 'images_loading', 
                            progress: 0.4 + (imageLoadRatio * 0.3),
                            imageLoadRatio: imageLoadRatio
                        };
                    }
                    
                    // 5. JavaScript 프레임워크 로딩 완료 확인 (React, Vue 등)
                    let frameworkReady = true;
                    if (window.React && !document.querySelector('[data-reactroot]')) {
                        frameworkReady = false;
                    }
                    if (window.Vue && !document.querySelector('[data-v-]')) {
                        frameworkReady = false;
                    }
                    
                    if (!frameworkReady) {
                        return { ready: false, reason: 'framework_loading', progress: 0.7 };
                    }
                    
                    // 6. 동적 콘텐츠 안정화 확인 (높이 변화 체크)
                    if (!window._bfcache_height_stable) {
                        window._bfcache_height_stable = {
                            lastHeight: contentHeight,
                            stableCount: 0,
                            startTime: Date.now()
                        };
                        return { ready: false, reason: 'height_stabilizing', progress: 0.8 };
                    }
                    
                    const heightData = window._bfcache_height_stable;
                    const heightChanged = Math.abs(heightData.lastHeight - contentHeight) > 50;
                    const timeElapsed = Date.now() - heightData.startTime;
                    
                    if (heightChanged) {
                        heightData.lastHeight = contentHeight;
                        heightData.stableCount = 0;
                    } else {
                        heightData.stableCount++;
                    }
                    
                    // 높이가 2번 연속 안정적이거나 충분한 시간이 지났으면 준비 완료
                    const heightStable = heightData.stableCount >= 2 || timeElapsed > 2000;
                    
                    if (!heightStable) {
                        return { 
                            ready: false, 
                            reason: 'height_changing', 
                            progress: 0.85,
                            heightStable: heightData.stableCount,
                            timeElapsed: timeElapsed
                        };
                    }
                    
                    return { 
                        ready: true, 
                        contentHeight: contentHeight,
                        viewportHeight: window.innerHeight,
                        progress: 1.0,
                        imageLoadRatio: imageLoadRatio,
                        frameworkReady: frameworkReady,
                        heightStable: heightData.stableCount
                    };
                } catch(e) {
                    return { ready: false, reason: 'error', error: e.message, progress: 0.0 };
                }
            })()
            """
            
            webView.evaluateJavaScript(advancedDOMReadyScript) { result, error in
                
                if let data = result as? [String: Any],
                   let ready = data["ready"] as? Bool {
                    
                    let progress = data["progress"] as? Double ?? 0.0
                    let reason = data["reason"] as? String ?? "unknown"
                    
                    if ready {
                        // DOM 준비됨 - 스크롤 복원 시작
                        TabPersistenceManager.debugMessages.append("🔥 고급 DOM 준비 완료 - 스크롤 복원 시작 (진행도: \(String(format: "%.1f%%", progress * 100)))")
                        self.performSuperProgressiveScrollRestore(webView: webView, startTime: startTime, completion: completion)
                        
                    } else {
                        // DOM 준비 안됨 - 재시도
                        if retryCount < maxRetries {
                            TabPersistenceManager.debugMessages.append("🔥 고급 DOM 준비 대기 중 (시도 \(retryCount + 1)/\(maxRetries)): \(reason) (진행도: \(String(format: "%.1f%%", progress * 100)))")
                            
                            self.waitForAdvancedDOMReady(webView: webView, startTime: startTime, retryCount: retryCount + 1, completion: completion)
                        } else {
                            // 최대 재시도 도달 - 강제 복원 시도
                            TabPersistenceManager.debugMessages.append("🔥 고급 DOM 준비 타임아웃 - 강제 복원 시도 (최종 진행도: \(String(format: "%.1f%%", progress * 100)))")
                            self.performSuperProgressiveScrollRestore(webView: webView, startTime: startTime, completion: completion)
                        }
                    }
                } else {
                    // 스크립트 실행 오류 - 재시도 또는 강제 복원
                    if retryCount < maxRetries {
                        TabPersistenceManager.debugMessages.append("🔥 고급 DOM 체크 오류 - 재시도 (시도 \(retryCount + 1)/\(maxRetries)): \(error?.localizedDescription ?? "unknown")")
                        self.waitForAdvancedDOMReady(webView: webView, startTime: startTime, retryCount: retryCount + 1, completion: completion)
                    } else {
                        TabPersistenceManager.debugMessages.append("🔥 고급 DOM 체크 최종 실패 - 강제 복원 시도")
                        self.performSuperProgressiveScrollRestore(webView: webView, startTime: startTime, completion: completion)
                    }
                }
            }
        }
    }
    
    // 🔥 **대폭 개선된 점진적 스크롤 복원** - 네이티브 우선 + Observer 기반 실시간 복원
    private func performSuperProgressiveScrollRestore(webView: WKWebView, startTime: Date, completion: @escaping (Bool) -> Void) {
        let targetPosition = calculateOptimalPositionAdvanced(for: webView)
        
        TabPersistenceManager.debugMessages.append("🔥 대폭 개선된 점진적 스크롤 복원 시작: 목표위치 \(Int(targetPosition.y))")
        
        // 1단계: 네이티브 스크롤뷰 즉시 설정 (최우선)
        webView.scrollView.setContentOffset(targetPosition, animated: false)
        
        // 2단계: Observer 기반 실시간 복원 시작
        startAdvancedProgressiveRestoreLoop(
            webView: webView,
            targetPosition: targetPosition,
            startTime: startTime,
            completion: completion
        )
    }
    
    // 🔥 **고급 점진적 복원 루프** - Observer 기반 + 네이티브 우선 + 더 스마트한 복원
    private func startAdvancedProgressiveRestoreLoop(
        webView: WKWebView,
        targetPosition: CGPoint,
        startTime: Date,
        completion: @escaping (Bool) -> Void
    ) {
        var attemptCount = 0
        let maxAttempts = 50 // 증가 (5초간 0.1초마다)
        let tolerance: CGFloat = 15 // 허용 오차 줄임
        var consecutiveSuccessCount = 0 // 연속 성공 카운터
        var lastObservedPosition = webView.scrollView.contentOffset
        
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            attemptCount += 1
            let currentPosition = webView.scrollView.contentOffset
            let distance = abs(currentPosition.y - targetPosition.y)
            
            // 🛡️ **웹페이지에서 스크롤을 변경했는지 감지**
            let positionChangedByPage = abs(currentPosition.y - lastObservedPosition.y) > 10 && 
                                       abs(currentPosition.y - targetPosition.y) > tolerance
            
            if positionChangedByPage {
                TabPersistenceManager.debugMessages.append("🛡️ 웹페이지가 스크롤을 변경함: \(Int(lastObservedPosition.y)) → \(Int(currentPosition.y)) (목표: \(Int(targetPosition.y)))")
                consecutiveSuccessCount = 0 // 성공 카운터 리셋
            }
            
            // 🔥 **다중 복원 전략 적용**
            
            // A. 네이티브 스크롤뷰 직접 설정 (항상 최우선)
            if distance > tolerance {
                webView.scrollView.setContentOffset(targetPosition, animated: false)
            }
            
            // B. JavaScript window.scrollTo 사용 (강화된 버전)
            let enhancedJSScrollScript = """
            (function() {
                try {
                    // 현재 위치 확인
                    const currentY = window.pageYOffset || document.documentElement.scrollTop || 0;
                    const targetY = \(targetPosition.y);
                    const distance = Math.abs(currentY - targetY);
                    
                    if (distance > \(tolerance) && !window._bfcache_scroll_blocking) {
                        // 즉시 스크롤
                        window.scrollTo({
                            top: targetY,
                            left: \(targetPosition.x),
                            behavior: 'instant'
                        });
                        
                        // 대안 방법도 시도
                        if (Math.abs((window.pageYOffset || 0) - targetY) > 10) {
                            document.documentElement.scrollTop = targetY;
                            if (document.body) {
                                document.body.scrollTop = targetY;
                            }
                        }
                        
                        return {
                            applied: true,
                            from: currentY,
                            to: targetY,
                            final: window.pageYOffset || document.documentElement.scrollTop || 0
                        };
                    }
                    
                    return {
                        applied: false,
                        current: currentY,
                        target: targetY,
                        distance: distance
                    };
                } catch(e) {
                    return { error: e.message };
                }
            })()
            """
            
            webView.evaluateJavaScript(enhancedJSScrollScript) { result, _ in
                // JavaScript 실행 후 위치 재확인
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    let finalPosition = webView.scrollView.contentOffset
                    let finalDistance = abs(finalPosition.y - targetPosition.y)
                    
                    // 🎯 **성공 조건 체크**
                    if finalDistance <= tolerance {
                        consecutiveSuccessCount += 1
                    } else {
                        consecutiveSuccessCount = 0
                    }
                    
                    // 로그 출력 (더 상세히)
                    if attemptCount % 5 == 0 || finalDistance <= tolerance || attemptCount >= maxAttempts {
                        let jsResult = result as? [String: Any]
                        let jsApplied = jsResult?["applied"] as? Bool ?? false
                        let jsError = jsResult?["error"] as? String
                        
                        TabPersistenceManager.debugMessages.append(
                            "🔥 고급 복원 시도 \(attemptCount)/\(maxAttempts): " +
                            "현재 \(Int(currentPosition.y)) → 최종 \(Int(finalPosition.y)) → 목표 \(Int(targetPosition.y)) " +
                            "(오차: \(Int(finalDistance))px, 연속성공: \(consecutiveSuccessCount), JS: \(jsApplied ? "적용" : "스킵")" +
                            (jsError != nil ? ", 오류: \(jsError!)" : "") + ")"
                        )
                    }
                    
                    lastObservedPosition = finalPosition
                }
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            
            // 🎯 **고급 성공 조건 확인**
            let baseSuccess = distance <= tolerance
            let stableSuccess = consecutiveSuccessCount >= 3 // 3회 연속 성공
            let timeoutReached = attemptCount >= maxAttempts
            
            if (baseSuccess && stableSuccess) || timeoutReached {
                timer.invalidate()
                
                // 스크롤 차단 해제
                let restoreScrollScript = """
                (function() {
                    try {
                        window._bfcache_scroll_blocking = false;
                        
                        // 모든 함수 복구
                        if (window._bfcache_restore_functions) {
                            const restore = window._bfcache_restore_functions;
                            
                            window.scrollTo = restore.scrollTo;
                            window.scrollBy = restore.scrollBy;
                            window.scroll = restore.scroll;
                            EventTarget.prototype.addEventListener = restore.addEventListener;
                            
                            if (restore.style && restore.style.parentNode) {
                                restore.style.parentNode.removeChild(restore.style);
                            }
                            
                            delete window._bfcache_restore_functions;
                        }
                        
                        if (history.scrollRestoration) {
                            history.scrollRestoration = 'auto';
                        }
                        
                        console.log('🛡️ 스크롤 차단 해제 완료');
                        return true;
                    } catch(e) {
                        console.error('스크롤 차단 해제 실패:', e);
                        return false;
                    }
                })()
                """
                
                webView.evaluateJavaScript(restoreScrollScript) { _, _ in
                    let success = baseSuccess && stableSuccess
                    TabPersistenceManager.debugMessages.append(
                        "🔥 대폭 개선된 점진적 복원 완료: \(success ? "성공" : "최대시도도달") " +
                        "(시도: \(attemptCount), 소요: \(String(format: "%.2f", elapsed))초, " +
                        "최종오차: \(Int(distance))px, 연속성공: \(consecutiveSuccessCount), 허용: \(Int(tolerance))px)"
                    )
                    completion(success)
                }
            }
        }
        
        // 메인 스레드에서 실행되도록 보장
        RunLoop.main.add(timer, forMode: .common)
    }
    
    // 🎯 **고급 최적 위치 계산** (개선된 우선순위 + 더 정확한 앵커 검색)
    private func calculateOptimalPositionAdvanced(for webView: WKWebView) -> CGPoint {
        let currentContentHeight = webView.scrollView.contentSize.height
        let currentViewportHeight = webView.scrollView.bounds.height
        
        TabPersistenceManager.debugMessages.append(
            "🎯 고급 위치 계산: 콘텐츠높이 \(Int(currentContentHeight)), " +
            "뷰포트높이 \(Int(currentViewportHeight)), " +
            "저장된높이 \(Int(smartScrollState.contentHeight))"
        )
        
        // 🔥 **1순위: 앵커 기반 복원** (더 정확한 실시간 검색)
        if let anchorSelector = smartScrollState.anchorSelector, !anchorSelector.isEmpty {
            var anchorPosition: CGPoint?
            let semaphore = DispatchSemaphore(value: 0)
            
            let enhancedAnchorScript = """
            (function() {
                try {
                    let anchor = null;
                    const selector = '\(anchorSelector)';
                    
                    // 1. 정확한 선택자로 찾기
                    anchor = document.querySelector(selector);
                    
                    // 2. ID 기반 대안 검색
                    if (!anchor && selector.startsWith('#')) {
                        const id = selector.slice(1);
                        anchor = document.getElementById(id);
                    }
                    
                    // 3. 유사한 선택자 검색 (클래스명 변경 대비)
                    if (!anchor && selector.includes('.')) {
                        const className = selector.split('.')[1];
                        if (className) {
                            anchor = document.querySelector('.' + className);
                        }
                    }
                    
                    // 4. 텍스트 기반 검색 (앵커 텍스트가 있는 경우)
                    if (!anchor && '\(smartScrollState.anchorText ?? "")'.length > 0) {
                        const targetText = '\(smartScrollState.anchorText ?? "")';
                        const elements = document.querySelectorAll('h1, h2, h3, h4, h5, h6, [id], .title');
                        for (const el of elements) {
                            if (el.textContent && el.textContent.includes(targetText.substring(0, 20))) {
                                anchor = el;
                                break;
                            }
                        }
                    }
                    
                    if (anchor) {
                        const rect = anchor.getBoundingClientRect();
                        const scrollY = window.pageYOffset || document.documentElement.scrollTop || 0;
                        const absoluteY = rect.top + scrollY + \(smartScrollState.anchorOffset);
                        
                        // 유효한 위치인지 확인
                        const maxScroll = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
                        const clampedY = Math.max(0, Math.min(absoluteY, maxScroll));
                        
                        return {
                            found: true,
                            absoluteY: clampedY,
                            rectTop: rect.top,
                            scrollY: scrollY,
                            selectorUsed: selector,
                            anchorText: anchor.textContent ? anchor.textContent.substring(0, 50) : '',
                            clamped: clampedY !== absoluteY
                        };
                    }
                } catch(e) {
                    console.error('고급 앵커 검색 실패:', e);
                }
                return { found: false, error: 'not_found' };
            })()
            """
            
            DispatchQueue.main.async {
                webView.evaluateJavaScript(enhancedAnchorScript) { result, _ in
                    if let data = result as? [String: Any],
                       let found = data["found"] as? Bool, found,
                       let absoluteY = data["absoluteY"] as? Double {
                        anchorPosition = CGPoint(x: 0, y: absoluteY)
                        let selectorUsed = data["selectorUsed"] as? String ?? "unknown"
                        let clamped = data["clamped"] as? Bool ?? false
                        TabPersistenceManager.debugMessages.append("🎯 고급 앵커 기반 위치: \(Int(absoluteY)) (앵커: \(selectorUsed)\(clamped ? ", 범위제한됨" : ""))")
                    } else {
                        let error = (result as? [String: Any])?["error"] as? String ?? "unknown"
                        TabPersistenceManager.debugMessages.append("🎯 고급 앵커 검색 실패: \(error)")
                    }
                    semaphore.signal()
                }
            }
            
            if semaphore.wait(timeout: .now() + 1.5) != .timedOut,
               let position = anchorPosition {
                return position
            }
        }
        
        // 🔥 **2순위: 고급 비율 기반 복원** (콘텐츠 높이 변화 스마트 대응)
        if smartScrollState.scrollRatio > 0.02 { // 거의 최상단이 아닌 경우만
            let maxScrollY = max(0, currentContentHeight - currentViewportHeight)
            
            if maxScrollY > 100 { // 스크롤 가능한 콘텐츠가 충분한 경우
                // 콘텐츠 높이 변화율 계산
                let heightChangeRatio = smartScrollState.contentHeight > 0 ? 
                    currentContentHeight / smartScrollState.contentHeight : 1.0
                
                var adjustedRatio = smartScrollState.scrollRatio
                
                // 콘텐츠가 크게 변했으면 비율 조정
                if heightChangeRatio > 1.5 || heightChangeRatio < 0.7 {
                    // 콘텐츠 높이 변화에 따른 비율 보정
                    adjustedRatio = smartScrollState.scrollRatio * sqrt(heightChangeRatio)
                    adjustedRatio = max(0.0, min(1.0, adjustedRatio)) // 0~1 범위 제한
                    
                    TabPersistenceManager.debugMessages.append(
                        "🎯 콘텐츠 높이 변화 감지 - 비율 조정: " +
                        "\(String(format: "%.3f", smartScrollState.scrollRatio)) → \(String(format: "%.3f", adjustedRatio)) " +
                        "(높이변화: \(String(format: "%.2fx", heightChangeRatio)))"
                    )
                }
                
                let calculatedY = maxScrollY * adjustedRatio
                TabPersistenceManager.debugMessages.append(
                    "🔥 고급 비율 기반 복원: \(String(format: "%.1f", adjustedRatio * 100))% " +
                    "→ \(Int(calculatedY)) (최대스크롤: \(Int(maxScrollY)))"
                )
                return CGPoint(x: 0, y: calculatedY)
            }
        }
        
        // 🔥 **3순위: 절대 좌표 (스마트 조건부 적용)**
        let savedAbsoluteY = smartScrollState.absolutePosition.y
        let maxCurrentScrollY = max(0, currentContentHeight - currentViewportHeight)
        
        // 절대 좌표가 현재 콘텐츠 범위 내이고 의미있는 위치인 경우만 사용
        if savedAbsoluteY <= maxCurrentScrollY && savedAbsoluteY > 50 {
            TabPersistenceManager.debugMessages.append("🔥 고급 절대 좌표 복원: \(Int(savedAbsoluteY))")
            return CGPoint(x: 0, y: savedAbsoluteY)
        }
        
        // 🔥 **4순위: 최상단 (안전한 기본값)**
        TabPersistenceManager.debugMessages.append("🔥 고급 기본 위치 (최상단) 복원")
        return CGPoint(x: 0, y: 0)
    }
}

// MARK: - 🎯 **강화된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        loadSiteTimingProfiles()
        setupMemoryWarningObserver()
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
    
    // MARK: - 전환 상태
    private var activeTransitions: [UUID: TransitionContext] = [:]
    
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
    
    // MARK: - 🔧 **핵심 개선: 스마트 스크롤 캡처** (네이티브 우선)
    
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
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performSmartCapture(task)
        }
    }
    
    private func performSmartCapture(_ task: CaptureTask) {
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
        dbg("🔥 스마트 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                contentSize: webView.scrollView.contentSize,
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🔥 **스마트 캡처 로직**
        let captureResult = performSmartScrollCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 1 : 0
        )
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        // 진행 중 해제
        pendingCaptures.remove(pageID)
        dbg("✅ 스마트 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔥 **스마트 스크롤 상태 캡처** (비율 기반 + Intersection Observer)
    private func performSmartScrollCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptSmartCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기
            dbg("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        // 여기까지 오면 모든 시도 실패
        let failedScrollState = SmartScrollState(pageRecord: pageRecord)
        return (BFCacheSnapshot(pageRecord: pageRecord, smartScrollState: failedScrollState, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptSmartCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var smartScrollState = SmartScrollState(pageRecord: pageRecord)
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. 🔥 **스마트 스크롤 상태 캡처**
        let scrollSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let smartScrollScript = generateSmartScrollCaptureScript()
            
            webView.evaluateJavaScript(smartScrollScript) { result, error in
                if let data = result as? [String: Any] {
                    self.parseSmartScrollData(data: data, scrollState: &smartScrollState, captureData: captureData)
                } else {
                    // 실패 시 기본 정보만 저장
                    self.setBasicScrollInfo(scrollState: &smartScrollState, captureData: captureData)
                }
                scrollSemaphore.signal()
            }
        }
        _ = scrollSemaphore.wait(timeout: .now() + 1.0)
        
        // 3. DOM 캡처 (필요시만)
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 간단한 DOM 스냅샷 (100KB 제한)
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
        _ = domSemaphore.wait(timeout: .now() + 0.5)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && smartScrollState.scrollRatio > 0 {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = .partial
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
            smartScrollState: smartScrollState,
            domSnapshot: domSnapshot,
            timestamp: Date(),
            webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
            captureStatus: captureStatus,
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🔥 **스마트 스크롤 캡처 스크립트** (웹 검색 결과 기반 최적화)
    private func generateSmartScrollCaptureScript() -> String {
        return """
        (function() {
            try {
                const startTime = performance.now();
                
                // 🔍 **웹 검색 결과**: document.documentElement.scrollTop이 더 안정적
                const scrollX = window.pageXOffset || document.documentElement.scrollLeft || 0;
                const scrollY = document.documentElement.scrollTop || window.pageYOffset || 0;
                
                const contentHeight = Math.max(
                    document.documentElement.scrollHeight,
                    document.body ? document.body.scrollHeight : 0,
                    document.documentElement.clientHeight
                );
                const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
                
                // 🔥 **비율 계산** (더 정확한 방법)
                const maxScrollY = Math.max(0, contentHeight - viewportHeight);
                const scrollRatio = maxScrollY > 0 ? Math.min(1, Math.max(0, scrollY / maxScrollY)) : 0;
                const viewportRatio = viewportHeight > 0 ? Math.min(1, Math.max(0, scrollY / viewportHeight)) : 0;
                
                // 🔍 **웹 검색 결과**: iOS WKWebView에서 더 안정적인 앵커 검색
                let anchorInfo = null;
                const anchorCandidates = [
                    // 1순위: 고정 ID가 있는 요소들 (가장 안정적)
                    ...Array.from(document.querySelectorAll('[id]')).filter(el => el.id && el.offsetHeight > 0),
                    // 2순위: 헤더 요소들 (구조적으로 안정적)
                    ...Array.from(document.querySelectorAll('h1, h2, h3, h4, h5, h6')).filter(el => el.offsetHeight > 0),
                    // 3순위: 시맨틱 요소들
                    ...Array.from(document.querySelectorAll('article, section, main, nav')).filter(el => el.offsetHeight > 0),
                    // 4순위: 클래스 기반 콘텐츠 요소들
                    ...Array.from(document.querySelectorAll('.content, .main, .container, .wrapper')).filter(el => el.offsetHeight > 0)
                ];
                
                // 현재 스크롤 위치 근처에서 가장 적합한 앵커 찾기
                for (const element of anchorCandidates) {
                    try {
                        const rect = element.getBoundingClientRect();
                        const elementTop = rect.top + scrollY;
                        
                        // 🎯 **개선된 앵커 선택 조건**
                        const isVisible = rect.height > 0 && rect.width > 0;
                        const isNearViewport = elementTop <= scrollY + viewportHeight && elementTop >= scrollY - viewportHeight * 0.5;
                        const hasStableIdentifier = element.id || element.tagName.match(/^H[1-6]$/);
                        
                        if (isVisible && isNearViewport && hasStableIdentifier) {
                            const selector = element.id ? `#${element.id}` : 
                                           element.tagName.toLowerCase() + 
                                           (element.className ? `.${element.className.split(' ')[0]}` : '');
                            
                            anchorInfo = {
                                selector: selector,
                                offset: scrollY - elementTop,
                                text: element.textContent ? element.textContent.trim().substring(0, 50) : '',
                                tagName: element.tagName,
                                hasId: !!element.id
                            };
                            break;
                        }
                    } catch(e) {
                        console.warn('앵커 검색 중 오류:', e);
                        continue;
                    }
                }
                
                // 🔍 **간소화된 가시 요소 추적** (성능 최적화)
                const visibleElements = [];
                try {
                    const importantElements = [
                        ...Array.from(document.querySelectorAll('[id]')).slice(0, 10),
                        ...Array.from(document.querySelectorAll('h1, h2, h3')).slice(0, 5),
                        ...Array.from(document.querySelectorAll('article, section, main')).slice(0, 5)
                    ];
                    
                    importantElements.forEach(el => {
                        if (el.offsetHeight > 0) {
                            const rect = el.getBoundingClientRect();
                            const isIntersecting = rect.top < viewportHeight && rect.bottom > 0;
                            
                            if (isIntersecting) {
                                const selector = el.id ? `#${el.id}` : el.tagName.toLowerCase();
                                visibleElements.push({
                                    selector: selector,
                                    intersectionRatio: Math.min(1, Math.max(0, 
                                        (Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0)) / rect.height
                                    )),
                                    boundingRect: {
                                        x: rect.x,
                                        y: rect.y,
                                        width: rect.width,
                                        height: rect.height
                                    },
                                    text: el.textContent ? el.textContent.trim().substring(0, 30) : null
                                });
                            }
                        }
                    });
                } catch(e) {
                    console.warn('가시 요소 추적 중 오류:', e);
                }
                
                const processingTime = performance.now() - startTime;
                console.log(`🔥 최적화된 스크롤 캡처 완료: ${processingTime.toFixed(1)}ms`);
                
                return {
                    scrollRatio: scrollRatio,
                    viewportRatio: viewportRatio,
                    anchorInfo: anchorInfo,
                    contentHeight: contentHeight,
                    viewportHeight: viewportHeight,
                    absolutePosition: { x: scrollX, y: scrollY },
                    visibleElements: visibleElements,
                    processingTime: processingTime,
                    scrollMethod: 'documentElement' // 사용된 스크롤 방법 추적
                };
                
            } catch(e) { 
                console.error('🔥 스크롤 캡처 실패:', e);
                // 🛡️ **안전장치**: 기본 방법으로 폴백
                const fallbackScrollY = window.pageYOffset || 0;
                const fallbackViewportHeight = window.innerHeight || 800;
                
                return {
                    scrollRatio: 0,
                    viewportRatio: 0,
                    anchorInfo: null,
                    contentHeight: fallbackViewportHeight,
                    viewportHeight: fallbackViewportHeight,
                    absolutePosition: { x: 0, y: fallbackScrollY },
                    visibleElements: [],
                    error: e.message,
                    scrollMethod: 'fallback'
                };
            }
        })()
        """
    }
    
    // JavaScript 데이터를 SmartScrollState로 파싱
    private func parseSmartScrollData(data: [String: Any], scrollState: inout SmartScrollState, captureData: CaptureData) {
        if let scrollRatio = data["scrollRatio"] as? Double {
            scrollState.scrollRatio = scrollRatio
        }
        
        if let viewportRatio = data["viewportRatio"] as? Double {
            scrollState.viewportRatio = viewportRatio
        }
        
        if let anchorInfo = data["anchorInfo"] as? [String: Any] {
            scrollState.anchorSelector = anchorInfo["selector"] as? String
            scrollState.anchorOffset = anchorInfo["offset"] as? Double ?? 0.0
            scrollState.anchorText = anchorInfo["text"] as? String
        }
        
        if let contentHeight = data["contentHeight"] as? Double {
            scrollState.contentHeight = contentHeight
        }
        
        if let viewportHeight = data["viewportHeight"] as? Double {
            scrollState.viewportHeight = viewportHeight
        }
        
        if let absolutePos = data["absolutePosition"] as? [String: Any],
           let x = absolutePos["x"] as? Double,
           let y = absolutePos["y"] as? Double {
            scrollState.absolutePosition = CGPoint(x: x, y: y)
        }
        
        if let visibleElementsData = data["visibleElements"] as? [[String: Any]] {
            scrollState.visibleElements = visibleElementsData.compactMap { elementData in
                guard let selector = elementData["selector"] as? String,
                      let ratio = elementData["intersectionRatio"] as? Double else { return nil }
                
                var rect = CGRect.zero
                if let rectData = elementData["boundingRect"] as? [String: Double] {
                    rect = CGRect(
                        x: rectData["x"] ?? 0,
                        y: rectData["y"] ?? 0,
                        width: rectData["width"] ?? 0,
                        height: rectData["height"] ?? 0
                    )
                }
                
                return SmartScrollState.VisibleElement(
                    selector: selector,
                    intersectionRatio: ratio,
                    boundingRect: rect,
                    text: elementData["text"] as? String
                )
            }
        }
        
        dbg("🔥 스마트 데이터 파싱 완료: 비율 \(String(format: "%.2f", scrollState.scrollRatio)), 앵커 \(scrollState.anchorSelector ?? "없음")")
    }
    
    // 기본 스크롤 정보 설정 (JavaScript 실패 시)
    private func setBasicScrollInfo(scrollState: inout SmartScrollState, captureData: CaptureData) {
        let maxScrollY = max(0, captureData.contentSize.height - captureData.bounds.height)
        scrollState.scrollRatio = maxScrollY > 0 ? min(1, captureData.scrollPosition.y / maxScrollY) : 0
        scrollState.viewportRatio = captureData.bounds.height > 0 ? min(1, captureData.scrollPosition.y / captureData.bounds.height) : 0
        scrollState.contentHeight = captureData.contentSize.height
        scrollState.viewportHeight = captureData.bounds.height
        scrollState.absolutePosition = captureData.scrollPosition
        
        dbg("🔥 기본 스크롤 정보 설정: 비율 \(String(format: "%.2f", scrollState.scrollRatio))")
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
                    self.dbg("❌ 상태 저장 실패: \(error.localizedDescription)")
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
    
    // MARK: - 🎯 **제스처 시스템 (🛡️ 연속 제스처 먹통 방지 적용)**
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        // 네이티브 제스처 비활성화
        webView.allowsBackForwardNavigationGestures = false
        
        // 왼쪽 엣지 - 뒤로가기
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        webView.addGestureRecognizer(leftEdge)
        
        // 오른쪽 엣지 - 앞으로가기  
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        webView.addGestureRecognizer(rightEdge)
        
        // 약한 참조 컨텍스트 생성 및 연결 (순환 참조 방지)
        if let tabID = stateModel.tabID {
            let ctx = WeakGestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
            objc_setAssociatedObject(leftEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(rightEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        dbg("🔥 네이티브 강제 복원 제스처 설정 완료")
    }
    
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        // 약한 참조 컨텍스트 조회 (순환 참조 방지)
        guard let ctx = objc_getAssociatedObject(gesture, "bfcache_ctx") as? WeakGestureContext,
              let stateModel = ctx.stateModel else { return }
        let webView = ctx.webView ?? (gesture.view as? WKWebView)
        guard let webView else { return }
        
        let tabID = ctx.tabID
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
            // 🛡️ **핵심 1: 전환 중이면 새 제스처 무시**
            guard activeTransitions[tabID] == nil else { 
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 🛡️ **핵심 3: 혹시 남아있는 기존 전환 강제 정리**
                if let existing = activeTransitions[tabID] {
                    existing.previewContainer?.removeFromSuperview()
                    activeTransitions.removeValue(forKey: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                // 현재 페이지 즉시 캡처 (높은 우선순위)
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                }
                
                // 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
                captureCurrentSnapshot(webView: webView) { [weak self] snapshot in
                    self?.beginGestureTransitionWithSnapshot(
                        tabID: tabID,
                        webView: webView,
                        stateModel: stateModel,
                        direction: direction,
                        currentSnapshot: snapshot
                    )
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
        activeTransitions[tabID] = context
        
        dbg("🔥 네이티브 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = activeTransitions[tabID],
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
    
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
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
                self?.performNavigationWithSuperEnhancedNativeRestore(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🔥 **대폭 개선된 네이티브 강제 복원을 적용한 네비게이션 수행**
    private func performNavigationWithSuperEnhancedNativeRestore(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 로딩 시간 측정 시작
        let navigationStartTime = Date()
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🔥 네이티브 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🔥 네이티브 앞으로가기 완료")
        }
        
        // 🔥 **대폭 개선된 네이티브 강제 BFCache 복원**
        trySuperEnhancedNativeForcedBFCacheRestore(stateModel: stateModel, direction: context.direction, navigationStartTime: navigationStartTime) { [weak self] success in
            // BFCache 복원 완료 또는 실패 시 즉시 정리
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🔥 미리보기 정리 완료 - 대폭 개선된 네이티브 BFCache \(success ? "성공" : "실패")")
            }
        }
        
        // 🛡️ **안전장치: 최대 3초 후 강제 정리** (증가된 시간)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (3초 타임아웃)")
            }
        }
    }
    
    // 🔥 **대폭 개선된 네이티브 강제 BFCache 복원**
    private func trySuperEnhancedNativeForcedBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, navigationStartTime: Date, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // 사이트별 프로파일 조회/생성
        var siteProfile = getSiteProfile(for: currentRecord.url) ?? SiteTimingProfile(hostname: currentRecord.url.host ?? "unknown")
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 대폭 개선된 네이티브 강제 복원
            snapshot.restore(to: webView, siteProfile: siteProfile) { [weak self] success in
                // 로딩 시간 기록
                let loadingDuration = Date().timeIntervalSince(navigationStartTime)
                siteProfile.recordLoadingTime(loadingDuration)
                siteProfile.recordRestoreAttempt(success: success)
                self?.updateSiteProfile(siteProfile)
                
                if success {
                    self?.dbg("✅ 대폭 개선된 네이티브 강제 BFCache 복원 성공: \(currentRecord.title) (소요: \(String(format: "%.2f", loadingDuration))초)")
                } else {
                    self?.dbg("⚠️ 대폭 개선된 네이티브 강제 BFCache 복원 실패: \(currentRecord.title)")
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
            
            // 기본 대기 시간 적용
            let waitTime = siteProfile.getAdaptiveWaitTime(step: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                completion(false)
            }
        }
    }
    
    private func cancelGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
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
                self.activeTransitions.removeValue(forKey: tabID)
            }
        )
    }
    
    // MARK: - 버튼 네비게이션 (대폭 개선된 네이티브 강제 복원)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        trySuperEnhancedNativeForcedBFCacheRestore(stateModel: stateModel, direction: .back, navigationStartTime: Date()) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        trySuperEnhancedNativeForcedBFCacheRestore(stateModel: stateModel, direction: .forward, navigationStartTime: Date()) { _ in
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
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔥 BFCache 페이지 복원');
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 BFCache 페이지 저장');
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[🔥BFCache] \(msg)")
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
        
        // 제스처 설치
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ 🔥 네이티브 강제 복원 BFCache 시스템 설치 완료")
    }
    
    // CustomWebView의 dismantleUIView에서 호출
    static func uninstall(from webView: WKWebView) {
        // 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        TabPersistenceManager.debugMessages.append("🧹 네이티브 BFCache 시스템 제거 완료")
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
        
        // 즉시 캡처 (최고 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📸 떠나기 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 캡처 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
        // 이전 페이지들도 순차적으로 캐시 확인 및 캡처
        if stateModel.dataModel.currentPageIndex > 0 {
            // 최근 3개 페이지만 체크 (성능 고려)
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                // 캐시가 없는 경우만 메타데이터 저장
                if !hasCache(for: previousRecord.id) {
                    // 메타데이터만 저장 (이미지는 없음)
                    let metadataScrollState = SmartScrollState(pageRecord: previousRecord)
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        smartScrollState: metadataScrollState,
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
