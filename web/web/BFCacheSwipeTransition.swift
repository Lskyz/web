//
//  BFCacheSwipeTransition.swift
//  🎯 **설계서 기반 리팩토링: 동적 렌더링 대기 + DOM 앵커 복원 + 진행형 로딩 보정**
//  🔒 **보존**: 페이지 미리보기, 스와이프 → 새 페이지 추가, 끌어당겨 밀어내는 전환 애니메이션
//  ✅ **신규**: DOM 앵커 탐지, lazy-load 패턴 감지, MutationObserver 안정성 대기
//  📁 **저장소**: Library/Caches/BFCache 경로로 변경
//  🔄 **복원**: DOM 앵커 → 진행형 로딩 보정 → iframe 복원 순서
//  ⚡ **성능**: 단계별 시도 횟수 제한, 오차 허용치 관리
//  🐛 **수정**: 동적 사이트 스크롤 복원 강화 - 지연 재시도 + 검증 시스템
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

// MARK: - 🧵 **제스처 컨텍스트 (보존)**
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

// MARK: - 📸 **개선된 BFCache 페이지 스냅샷 (DOM 앵커 + lazy-load 패턴)**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    let scrollPositionPercent: CGPoint
    let contentSize: CGSize
    let viewportSize: CGSize
    let actualScrollableSize: CGSize
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 🆕 **DOM 앵커 및 동적 패턴 정보**
    var domAnchors: [DOManchor]?
    var lazyLoadPatterns: [LazyLoadPattern]?
    var dynamicStability: DynamicStability?
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공 (동적 페이지에서 허용)
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
    }
    
    // 🆕 **DOM 앵커 구조체**
    struct DOManchor: Codable {
        let selector: String
        let text: String
        let position: CGPoint
        let elementRect: CGRect
        let isVisible: Bool
        let zIndex: Int
        let isSticky: Bool
    }
    
    // 🆕 **Lazy Load 패턴 구조체**
    struct LazyLoadPattern: Codable {
        let selector: String
        let type: String // "image", "iframe", "content", "infinite-scroll"
        let triggerDistance: CGFloat
        let isLoaded: Bool
        let loadingState: String
    }
    
    // 🆕 **동적 안정성 정보**
    struct DynamicStability: Codable {
        let stabilityScore: Int // 0-100
        let mutationCount: Int
        let waitTimeMs: Int
        let isStable: Bool
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, scrollPositionPercent
        case contentSize, viewportSize, actualScrollableSize, jsState
        case timestamp, webViewSnapshotPath, captureStatus, version
        case domAnchors, lazyLoadPatterns, dynamicStability
    }
    
    // Custom encoding/decoding for [String: Any]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        scrollPositionPercent = try container.decodeIfPresent(CGPoint.self, forKey: .scrollPositionPercent) ?? CGPoint.zero
        contentSize = try container.decodeIfPresent(CGSize.self, forKey: .contentSize) ?? CGSize.zero
        viewportSize = try container.decodeIfPresent(CGSize.self, forKey: .viewportSize) ?? CGSize.zero
        actualScrollableSize = try container.decodeIfPresent(CGSize.self, forKey: .actualScrollableSize) ?? CGSize.zero
        
        // JSON decode for [String: Any]
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
        
        // 🆕 **신규 필드들**
        domAnchors = try container.decodeIfPresent([DOManchor].self, forKey: .domAnchors)
        lazyLoadPatterns = try container.decodeIfPresent([LazyLoadPattern].self, forKey: .lazyLoadPatterns)
        dynamicStability = try container.decodeIfPresent(DynamicStability.self, forKey: .dynamicStability)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        try container.encode(scrollPositionPercent, forKey: .scrollPositionPercent)
        try container.encode(contentSize, forKey: .contentSize)
        try container.encode(viewportSize, forKey: .viewportSize)
        try container.encode(actualScrollableSize, forKey: .actualScrollableSize)
        
        // JSON encode for [String: Any]
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
        
        // 🆕 **신규 필드들**
        try container.encodeIfPresent(domAnchors, forKey: .domAnchors)
        try container.encodeIfPresent(lazyLoadPatterns, forKey: .lazyLoadPatterns)
        try container.encodeIfPresent(dynamicStability, forKey: .dynamicStability)
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, 
         domSnapshot: String? = nil, 
         scrollPosition: CGPoint, 
         scrollPositionPercent: CGPoint = CGPoint.zero,
         contentSize: CGSize = CGSize.zero,
         viewportSize: CGSize = CGSize.zero,
         actualScrollableSize: CGSize = CGSize.zero,
         jsState: [String: Any]? = nil, 
         timestamp: Date, 
         webViewSnapshotPath: String? = nil, 
         captureStatus: CaptureStatus = .partial, 
         version: Int = 1,
         domAnchors: [DOManchor]? = nil,
         lazyLoadPatterns: [LazyLoadPattern]? = nil,
         dynamicStability: DynamicStability? = nil) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.scrollPositionPercent = scrollPositionPercent
        self.contentSize = contentSize
        self.viewportSize = viewportSize
        self.actualScrollableSize = actualScrollableSize
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.domAnchors = domAnchors
        self.lazyLoadPatterns = lazyLoadPatterns
        self.dynamicStability = dynamicStability
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🔄 **개선된 복원 메서드 (동적 사이트 스크롤 복원 강화)**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🔄 설계서 기반 복원 시작 - 상태: \(captureStatus.rawValue)")
        
        // 🔧 **상태별 복원 전략**
        switch captureStatus {
        case .failed:
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패 상태 - 기본 스크롤만 복원")
            performBasicScrollRestoreWithRetry(to: webView, completion: completion)
            return
            
        case .visualOnly:
            TabPersistenceManager.debugMessages.append("🖼️ 비주얼 전용 - 강화된 스크롤 복원")
            performEnhancedScrollRestore(to: webView, completion: completion)
            
        case .partial, .complete:
            TabPersistenceManager.debugMessages.append("🎯 고급 복원 - DOM 앵커 + 진행형 로딩 보정")
            performAdvancedRestore(to: webView, completion: completion)
        }
    }
    
    // 🐛 **신규: 기본 스크롤 복원 + 재시도 시스템**
    private func performBasicScrollRestoreWithRetry(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let targetPos = self.scrollPosition
        
        // 동적 사이트를 위한 다단계 복원 시스템
        performScrollRestoreWithVerification(to: webView, targetPosition: targetPos, attempts: 0, maxAttempts: 5) { success in
            completion(success)
        }
    }
    
    // 🐛 **신규: 강화된 스크롤 복원 (비주얼 전용)**
    private func performEnhancedScrollRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let targetPos = self.scrollPosition
        
        // 즉시 첫 번째 시도
        performImmediateScrollRestore(to: webView)
        
        // DOM 준비 상태 확인 후 정밀 복원
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.performScrollRestoreWithVerification(to: webView, targetPosition: targetPos, attempts: 0, maxAttempts: 6) { success in
                completion(success)
            }
        }
    }
    
    // 🐛 **신규: 스크롤 복원 + 검증 시스템**
    private func performScrollRestoreWithVerification(to webView: WKWebView, targetPosition: CGPoint, attempts: Int, maxAttempts: Int, completion: @escaping (Bool) -> Void) {
        
        guard attempts < maxAttempts else {
            TabPersistenceManager.debugMessages.append("⚠️ 스크롤 복원 최대 시도 횟수 도달: \(maxAttempts)")
            completion(false)
            return
        }
        
        // 네이티브 스크롤 설정 (강제)
        webView.scrollView.setContentOffset(targetPosition, animated: false)
        webView.scrollView.contentOffset = targetPosition
        
        // JavaScript 스크롤 복원 (동적 대기 포함)
        let enhancedScrollJS = """
        (function() {
            return new Promise((resolve) => {
                const targetX = \(targetPosition.x);
                const targetY = \(targetPosition.y);
                const tolerance = 30; // 허용 오차 확대
                let attempts = 0;
                const maxAttempts = 3;
                
                console.log('🔄 동적 스크롤 복원 시도 \(attempts + 1)/\(maxAttempts): 목표 (' + targetX + ', ' + targetY + ')');
                
                function tryScrollRestore() {
                    // 1. 기본 스크롤 복원
                    window.scrollTo(targetX, targetY);
                    document.documentElement.scrollTop = targetY;
                    document.documentElement.scrollLeft = targetX;
                    document.body.scrollTop = targetY;
                    document.body.scrollLeft = targetX;
                    
                    // 2. 스크롤 가능한 컨테이너도 확인
                    const scrollableElements = document.querySelectorAll('[style*="overflow"], .scroll-container, .scrollable');
                    scrollableElements.forEach(el => {
                        if (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth) {
                            el.scrollTop = targetY;
                            el.scrollLeft = targetX;
                        }
                    });
                    
                    // 3. 즉시 검증
                    setTimeout(() => {
                        const currentX = window.scrollX || window.pageXOffset || 0;
                        const currentY = window.scrollY || window.pageYOffset || 0;
                        const deltaX = Math.abs(currentX - targetX);
                        const deltaY = Math.abs(currentY - targetY);
                        
                        console.log('🔍 스크롤 검증: 현재 (' + currentX + ', ' + currentY + '), 차이 (' + deltaX + ', ' + deltaY + ')');
                        
                        if (deltaX <= tolerance && deltaY <= tolerance) {
                            console.log('✅ 스크롤 복원 성공');
                            resolve({ success: true, currentX: currentX, currentY: currentY });
                        } else {
                            attempts++;
                            if (attempts < maxAttempts) {
                                console.log('⏳ 스크롤 재시도 (' + (attempts + 1) + '/' + maxAttempts + ')');
                                setTimeout(tryScrollRestore, 200 * attempts); // 점진적 지연
                            } else {
                                console.log('⚠️ 스크롤 복원 실패 - 최대 시도 횟수 도달');
                                resolve({ success: false, currentX: currentX, currentY: currentY });
                            }
                        }
                    }, 100);
                }
                
                // DOM 준비 상태 확인 후 시작
                if (document.readyState === 'complete') {
                    tryScrollRestore();
                } else {
                    document.addEventListener('DOMContentLoaded', tryScrollRestore);
                }
            });
        })()
        """
        
        webView.evaluateJavaScript(enhancedScrollJS) { [weak self] result, error in
            guard let self = self else { 
                completion(false)
                return 
            }
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("❌ JavaScript 스크롤 복원 실패: \(error.localizedDescription)")
                
                // 재시도
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.performScrollRestoreWithVerification(to: webView, targetPosition: targetPosition, attempts: attempts + 1, maxAttempts: maxAttempts, completion: completion)
                }
                return
            }
            
            if let resultDict = result as? [String: Any],
               let success = resultDict["success"] as? Bool,
               let currentX = resultDict["currentX"] as? Double,
               let currentY = resultDict["currentY"] as? Double {
                
                TabPersistenceManager.debugMessages.append("🔍 스크롤 복원 결과: \(success ? "성공" : "실패") - 목표(\(targetPosition.x), \(targetPosition.y)) → 현재(\(currentX), \(currentY))")
                
                if success {
                    completion(true)
                } else {
                    // 실패 시 재시도
                    let delay = TimeInterval(0.4 + Double(attempts) * 0.2) // 점진적 지연 증가
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.performScrollRestoreWithVerification(to: webView, targetPosition: targetPosition, attempts: attempts + 1, maxAttempts: maxAttempts, completion: completion)
                    }
                }
            } else {
                TabPersistenceManager.debugMessages.append("⚠️ JavaScript 스크롤 결과 파싱 실패")
                // 재시도
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.performScrollRestoreWithVerification(to: webView, targetPosition: targetPosition, attempts: attempts + 1, maxAttempts: maxAttempts, completion: completion)
                }
            }
        }
    }
    
    // ⚡ **개선된 즉시 네이티브 스크롤 복원**
    private func performImmediateScrollRestore(to webView: WKWebView) {
        let targetPos = self.scrollPosition
        
        // 1. 네이티브 스크롤뷰 설정 (강제)
        webView.scrollView.setContentOffset(targetPos, animated: false)
        webView.scrollView.contentOffset = targetPos
        
        // 2. 추가 네이티브 설정 (iOS 버전별 대응)
        if #available(iOS 14.0, *) {
            webView.scrollView.contentOffset = targetPos
        }
        
        // 3. 기본 JavaScript 스크롤 (즉시)
        let basicScrollJS = """
        try {
            window.scrollTo(\(targetPos.x), \(targetPos.y));
            document.documentElement.scrollTop = \(targetPos.y);
            document.body.scrollTop = \(targetPos.y);
            document.documentElement.scrollLeft = \(targetPos.x);
            document.body.scrollLeft = \(targetPos.x);
            console.log('⚡ 즉시 스크롤 복원 실행: (\(targetPos.x), \(targetPos.y))');
        } catch(e) {
            console.error('⚡ 즉시 스크롤 복원 실패:', e);
        }
        """
        
        webView.evaluateJavaScript(basicScrollJS) { _, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("❌ 즉시 스크롤 JavaScript 실패: \(error.localizedDescription)")
            } else {
                TabPersistenceManager.debugMessages.append("⚡ 즉시 스크롤 복원: (\(targetPos.x), \(targetPos.y))")
            }
        }
    }
    
    // 🖼️ **기본 복원 (비주얼 전용) - 수정됨**
    private func performBasicRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        performEnhancedScrollRestore(to: webView, completion: completion)
    }
    
    // 🎯 **고급 복원 (DOM 앵커 + 진행형 로딩) - 스크롤 복원 강화**
    private func performAdvancedRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        let restoreSteps: [(name: String, action: (@escaping (Bool) -> Void) -> Void)] = [
            ("즉시 스크롤 복원", { stepCompletion in
                self.performEnhancedScrollRestore(to: webView, completion: stepCompletion)
            }),
            ("DOM 앵커 복원", { stepCompletion in
                self.performDOManchorRestore(to: webView, completion: stepCompletion)
            }),
            ("진행형 로딩 보정", { stepCompletion in
                self.performProgressiveLoadingCorrection(to: webView, completion: stepCompletion)
            }),
            ("iframe 복원", { stepCompletion in
                self.performIframeRestore(to: webView, completion: stepCompletion)
            }),
            ("최종 스크롤 검증", { stepCompletion in
                self.performFinalScrollVerification(to: webView, completion: stepCompletion)
            })
        ]
        
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let step = restoreSteps[currentStep]
                currentStep += 1
                
                TabPersistenceManager.debugMessages.append("🔄 \(step.name) 시작 (\(currentStep)/\(restoreSteps.count))")
                
                step.action { success in
                    stepResults.append(success)
                    TabPersistenceManager.debugMessages.append("✅ \(step.name) 완료: \(success ? "성공" : "실패")")
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let overallSuccess = successCount > restoreSteps.count / 2
                
                TabPersistenceManager.debugMessages.append("🎯 고급 복원 완료: \(successCount)/\(restoreSteps.count) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                completion(overallSuccess)
            }
        }
        
        executeNextStep()
    }
    
    // 🔗 **DOM 앵커 복원**
    private func performDOManchorRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let anchors = self.domAnchors, !anchors.isEmpty else {
            completion(false)
            return
        }
        
        let anchorsJSON = convertToJSONString(anchors.map { [
            "selector": $0.selector,
            "text": $0.text,
            "position": ["x": $0.position.x, "y": $0.position.y],
            "isSticky": $0.isSticky
        ]}) ?? "[]"
        
        let domAnchorJS = """
        (function() {
            try {
                const anchors = \(anchorsJSON);
                const TARGET_Y = \(scrollPosition.y);
                let bestAnchor = null;
                let minDistance = Infinity;
                
                console.log('🔗 DOM 앵커 복원 시작:', anchors.length, '개 앵커');
                
                // 각 앵커의 현재 위치 확인
                for (const anchor of anchors) {
                    const elements = document.querySelectorAll(anchor.selector);
                    for (const el of elements) {
                        if (el.textContent.includes(anchor.text.substring(0, 20))) {
                            const rect = el.getBoundingClientRect();
                            const currentY = window.scrollY + rect.top;
                            const distance = Math.abs(currentY - TARGET_Y);
                            
                            if (distance < minDistance) {
                                minDistance = distance;
                                bestAnchor = { element: el, anchor: anchor, currentY: currentY };
                            }
                        }
                    }
                }
                
                if (bestAnchor && minDistance < 500) {
                    // 스티키 헤더 보정
                    let stickyOffset = 0;
                    const stickyElements = document.querySelectorAll('[style*="sticky"], [style*="fixed"]');
                    for (const sticky of stickyElements) {
                        const stickyRect = sticky.getBoundingClientRect();
                        if (stickyRect.top < 100) {
                            stickyOffset = Math.max(stickyOffset, stickyRect.height);
                        }
                    }
                    
                    const targetScrollY = Math.max(0, bestAnchor.currentY - stickyOffset);
                    window.scrollTo(window.scrollX, targetScrollY);
                    
                    console.log('🔗 DOM 앵커 복원 성공:', {
                        selector: bestAnchor.anchor.selector,
                        targetY: TARGET_Y,
                        currentY: bestAnchor.currentY,
                        finalY: targetScrollY,
                        stickyOffset: stickyOffset
                    });
                    
                    return true;
                } else {
                    console.log('🔗 DOM 앵커 복원 실패: 적절한 앵커 없음');
                    return false;
                }
            } catch(e) {
                console.error('🔗 DOM 앵커 복원 에러:', e);
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(domAnchorJS) { result, _ in
            let success = (result as? Bool) ?? false
            completion(success)
        }
    }
    
    // 📈 **진행형 로딩 보정**
    private func performProgressiveLoadingCorrection(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let patterns = self.lazyLoadPatterns, !patterns.isEmpty else {
            completion(false)
            return
        }
        
        let patternsJSON = convertToJSONString(patterns.map { [
            "selector": $0.selector,
            "type": $0.type,
            "triggerDistance": $0.triggerDistance,
            "isLoaded": $0.isLoaded
        ]}) ?? "[]"
        
        let progressiveLoadingJS = """
        (function() {
            return new Promise((resolve) => {
                try {
                    const patterns = \(patternsJSON);
                    const TARGET_Y = \(scrollPosition.y);
                    const MAX_ATTEMPTS = 10;
                    const MAX_WAIT_TIME = 3000; // 3초
                    let attempts = 0;
                    let startTime = Date.now();
                    
                    console.log('📈 진행형 로딩 보정 시작:', patterns.length, '개 패턴');
                    
                    function triggerLazyLoading() {
                        let triggered = 0;
                        
                        for (const pattern of patterns) {
                            const elements = document.querySelectorAll(pattern.selector);
                            elements.forEach(el => {
                                if (pattern.type === 'image' && !el.src && el.dataset.src) {
                                    el.src = el.dataset.src;
                                    triggered++;
                                } else if (pattern.type === 'iframe' && !el.src && el.dataset.src) {
                                    el.src = el.dataset.src;
                                    triggered++;
                                } else if (pattern.type === 'infinite-scroll') {
                                    // 무한 스크롤 트리거
                                    el.scrollIntoView({ behavior: 'auto', block: 'end' });
                                    triggered++;
                                }
                            });
                        }
                        
                        return triggered;
                    }
                    
                    function checkContentStability() {
                        const currentContentHeight = document.documentElement.scrollHeight;
                        const currentScrollY = window.scrollY;
                        
                        // 목표 위치에 도달했는지 확인
                        const targetDistance = Math.abs(currentScrollY - TARGET_Y);
                        if (targetDistance < 50) {
                            console.log('📈 목표 위치 도달 - 보정 완료:', currentScrollY, '/', TARGET_Y);
                            resolve(true);
                            return;
                        }
                        
                        // 최대 시도 횟수나 시간 초과 확인
                        attempts++;
                        const elapsed = Date.now() - startTime;
                        if (attempts >= MAX_ATTEMPTS || elapsed >= MAX_WAIT_TIME) {
                            console.log('📈 진행형 로딩 보정 시간 초과:', { attempts, elapsed });
                            resolve(false);
                            return;
                        }
                        
                        // lazy 요소 트리거
                        const triggered = triggerLazyLoading();
                        if (triggered > 0) {
                            console.log('📈 lazy 요소 트리거:', triggered, '개');
                        }
                        
                        // 다음 확인을 위해 대기
                        setTimeout(checkContentStability, 300);
                    }
                    
                    // 첫 번째 확인 시작
                    checkContentStability();
                    
                } catch(e) {
                    console.error('📈 진행형 로딩 보정 에러:', e);
                    resolve(false);
                }
            });
        })()
        """
        
        webView.evaluateJavaScript(progressiveLoadingJS) { result, _ in
            let success = (result as? Bool) ?? false
            completion(success)
        }
    }
    
    // 🖼️ **iframe 복원**
    private func performIframeRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let jsState = self.jsState,
              let iframeData = jsState["iframes"] as? [[String: Any]], !iframeData.isEmpty else {
            completion(false)
            return
        }
        
        let iframeJSON = convertToJSONString(iframeData) ?? "[]"
        let iframeRestoreJS = """
        (function() {
            try {
                const iframes = \(iframeJSON);
                let restored = 0;
                
                console.log('🖼️ iframe 복원 시작:', iframes.length, '개 iframe');
                
                for (const iframeInfo of iframes) {
                    const iframe = document.querySelector(iframeInfo.selector);
                    if (iframe && iframe.contentWindow) {
                        try {
                            const targetX = parseFloat(iframeInfo.scrollX || 0);
                            const targetY = parseFloat(iframeInfo.scrollY || 0);
                            
                            iframe.contentWindow.scrollTo(targetX, targetY);
                            restored++;
                            console.log('🖼️ iframe 복원 성공:', iframeInfo.selector, [targetX, targetY]);
                        } catch(e) {
                            // Cross-origin iframe 처리
                            try {
                                iframe.contentWindow.postMessage({
                                    type: 'restoreScroll',
                                    scrollX: parseFloat(iframeInfo.scrollX || 0),
                                    scrollY: parseFloat(iframeInfo.scrollY || 0)
                                }, '*');
                                restored++;
                                console.log('🖼️ Cross-origin iframe 메시지 전송:', iframeInfo.selector);
                            } catch(crossOriginError) {
                                console.log('🖼️ Cross-origin iframe 접근 불가:', iframeInfo.selector);
                            }
                        }
                    }
                }
                
                console.log('🖼️ iframe 복원 완료:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('🖼️ iframe 복원 에러:', e);
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(iframeRestoreJS) { result, _ in
            let success = (result as? Bool) ?? false
            completion(success)
        }
    }
    
    // ✅ **최종 스크롤 검증 - 강화됨**
    private func performFinalScrollVerification(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let finalVerifyJS = """
        (function() {
            return new Promise((resolve) => {
                try {
                    const targetX = \(scrollPosition.x);
                    const targetY = \(scrollPosition.y);
                    let attempts = 0;
                    const maxAttempts = 3;
                    const tolerance = 25; // 허용 오차
                    
                    function verifyAndCorrect() {
                        const currentX = window.scrollX || window.pageXOffset || 0;
                        const currentY = window.scrollY || window.pageYOffset || 0;
                        const deltaX = Math.abs(currentX - targetX);
                        const deltaY = Math.abs(currentY - targetY);
                        
                        console.log('✅ 최종 검증 시도 ' + (attempts + 1) + '/' + maxAttempts + ':', {
                            target: [targetX, targetY],
                            current: [currentX, currentY],
                            delta: [deltaX, deltaY],
                            tolerance: tolerance
                        });
                        
                        const isWithinTolerance = deltaX <= tolerance && deltaY <= tolerance;
                        
                        if (isWithinTolerance) {
                            console.log('✅ 최종 검증 성공');
                            resolve(true);
                        } else {
                            attempts++;
                            if (attempts < maxAttempts) {
                                // 재보정 시도
                                window.scrollTo(targetX, targetY);
                                document.documentElement.scrollTop = targetY;
                                document.body.scrollTop = targetY;
                                console.log('🔧 최종 보정 시도 ' + attempts);
                                
                                setTimeout(verifyAndCorrect, 300);
                            } else {
                                console.log('⚠️ 최종 검증 실패 - 허용 오차 초과');
                                resolve(false);
                            }
                        }
                    }
                    
                    // 초기 대기 후 검증 시작
                    setTimeout(verifyAndCorrect, 200);
                    
                } catch(e) {
                    console.error('✅ 최종 검증 에러:', e);
                    resolve(false);
                }
            });
        })()
        """
        
        webView.evaluateJavaScript(finalVerifyJS) { result, _ in
            let success = (result as? Bool) ?? false
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

// MARK: - 📸 **네비게이션 이벤트 감지 시스템 (보존)**
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

// MARK: - 🎯 **BFCache 전환 시스템 (설계서 기반)**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 **직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // MARK: - 💾 스레드 안전 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
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
    
    // MARK: - 📁 **설계서 기반 파일 시스템 경로 (Library/Caches/BFCache)**
    private var bfCacheDirectory: URL {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesPath.appendingPathComponent("BFCache", isDirectory: true)
    }
    
    private func tabDirectory(for tabID: UUID) -> URL {
        return bfCacheDirectory.appendingPathComponent("Tab_\(tabID.uuidString)", isDirectory: true)
    }
    
    private func pageDirectory(for pageID: UUID, tabID: UUID, version: Int) -> URL {
        return tabDirectory(for: tabID).appendingPathComponent("Page_\(pageID.uuidString)_v\(version)", isDirectory: true)
    }
    
    // MARK: - 🧵 **제스처 전환 상태 (보존된 스레드 안전 관리)**
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
    
    // 🧵 **제스처 컨텍스트 관리 (보존)**
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
    
    // 전환 컨텍스트 (보존)
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
    
    // MARK: - 🔧 **개선된 캡처 작업 (DOM 앵커 + MutationObserver)**
    
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
        
        dbg("🎯 설계서 기반 캡처 시작: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAdvancedCapture(task)
        }
    }
    
    private func performAdvancedCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 중복 캡처 방지
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
        dbg("🎯 설계서 기반 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            let actualScrollableWidth = max(webView.scrollView.contentSize.width, webView.scrollView.bounds.width)
            let actualScrollableHeight = max(webView.scrollView.contentSize.height, webView.scrollView.bounds.height)
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                contentSize: webView.scrollView.contentSize,
                viewportSize: webView.bounds.size,
                actualScrollableSize: CGSize(width: actualScrollableWidth, height: actualScrollableHeight),
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🔧 **설계서 기반 강화된 캡처 로직**
        let captureResult = performEnhancedCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        // 진행 중 해제
        pendingCaptures.remove(pageID)
        dbg("✅ 설계서 기반 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize
        let viewportSize: CGSize
        let actualScrollableSize: CGSize
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔧 **설계서 기반 강화된 캡처 메서드**
    private func performEnhancedCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptEnhancedCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            dbg("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptEnhancedCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var domAnchors: [BFCacheSnapshot.DOManchor]? = nil
        var lazyLoadPatterns: [BFCacheSnapshot.LazyLoadPattern]? = nil
        var dynamicStability: BFCacheSnapshot.DynamicStability? = nil
        
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
        
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. 🆕 **설계서 기반 강화된 JS 상태 캡처 (DOM 앵커 + MutationObserver)**
        let enhancedJSSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let enhancedScript = generateEnhancedCaptureScript()
            
            webView.evaluateJavaScript(enhancedScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                    
                    // DOM 앵커 추출
                    if let anchorsData = data["domAnchors"] as? [[String: Any]] {
                        domAnchors = anchorsData.compactMap { anchorDict in
                            guard let selector = anchorDict["selector"] as? String,
                                  let text = anchorDict["text"] as? String,
                                  let posDict = anchorDict["position"] as? [String: CGFloat],
                                  let rectDict = anchorDict["elementRect"] as? [String: CGFloat] else { return nil }
                            
                            return BFCacheSnapshot.DOManchor(
                                selector: selector,
                                text: text,
                                position: CGPoint(x: posDict["x"] ?? 0, y: posDict["y"] ?? 0),
                                elementRect: CGRect(x: rectDict["x"] ?? 0, y: rectDict["y"] ?? 0,
                                                  width: rectDict["width"] ?? 0, height: rectDict["height"] ?? 0),
                                isVisible: anchorDict["isVisible"] as? Bool ?? false,
                                zIndex: anchorDict["zIndex"] as? Int ?? 0,
                                isSticky: anchorDict["isSticky"] as? Bool ?? false
                            )
                        }
                    }
                    
                    // Lazy Load 패턴 추출
                    if let patternsData = data["lazyLoadPatterns"] as? [[String: Any]] {
                        lazyLoadPatterns = patternsData.compactMap { patternDict in
                            guard let selector = patternDict["selector"] as? String,
                                  let type = patternDict["type"] as? String else { return nil }
                            
                            return BFCacheSnapshot.LazyLoadPattern(
                                selector: selector,
                                type: type,
                                triggerDistance: CGFloat(patternDict["triggerDistance"] as? Double ?? 0),
                                isLoaded: patternDict["isLoaded"] as? Bool ?? false,
                                loadingState: patternDict["loadingState"] as? String ?? "unknown"
                            )
                        }
                    }
                    
                    // 동적 안정성 정보 추출
                    if let stabilityData = data["dynamicStability"] as? [String: Any] {
                        dynamicStability = BFCacheSnapshot.DynamicStability(
                            stabilityScore: stabilityData["stabilityScore"] as? Int ?? 0,
                            mutationCount: stabilityData["mutationCount"] as? Int ?? 0,
                            waitTimeMs: stabilityData["waitTimeMs"] as? Int ?? 0,
                            isStable: stabilityData["isStable"] as? Bool ?? false
                        )
                    }
                }
                enhancedJSSemaphore.signal()
            }
        }
        _ = enhancedJSSemaphore.wait(timeout: .now() + 4.0) // 설계서: MutationObserver 대기 시간 고려
        
        // 3. DOM 캡처 (기존 유지)
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    const html = document.documentElement.outerHTML;
                    return html.length > 50000 ? html.substring(0, 50000) : html; // 설계서: DOM 크기 제한
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                domSnapshot = result as? String
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 1.0)
        
        // 캡처 상태 결정 (설계서: 동적 페이지에서 partial 승격)
        let captureStatus: BFCacheSnapshot.CaptureStatus
        let isDynamic = (dynamicStability?.mutationCount ?? 0) > 10 // 동적 페이지 판정
        
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil && domAnchors != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil && (jsState != nil || isDynamic) {
            captureStatus = .partial // 동적 페이지는 partial로 승격
        } else if visualSnapshot != nil {
            captureStatus = .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 버전 증가
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        // 상대적 위치 계산
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.width > captureData.viewportSize.width && captureData.actualScrollableSize.height > captureData.viewportSize.height {
            let maxScrollX = captureData.actualScrollableSize.width - captureData.viewportSize.width
            let maxScrollY = captureData.actualScrollableSize.height - captureData.viewportSize.height
            
            scrollPercent = CGPoint(
                x: maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            scrollPositionPercent: scrollPercent,
            contentSize: captureData.contentSize,
            viewportSize: captureData.viewportSize,
            actualScrollableSize: captureData.actualScrollableSize,
            jsState: jsState,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version,
            domAnchors: domAnchors,
            lazyLoadPatterns: lazyLoadPatterns,
            dynamicStability: dynamicStability
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🆕 **설계서 기반 강화된 캡처 JavaScript (DOM 앵커 + MutationObserver)**
    private func generateEnhancedCaptureScript() -> String {
        return """
        (function() {
            return new Promise(resolve => {
                // 🔄 **설계서: MutationObserver 기반 동적 렌더링 대기**
                function waitForDynamicStability(callback) {
                    let stabilityCount = 0;
                    let mutationCount = 0;
                    const requiredStability = 3; // 3번 연속 안정되면 완료
                    const startTime = Date.now();
                    let timeout;
                    
                    const observer = new MutationObserver((mutations) => {
                        mutationCount += mutations.length;
                        stabilityCount = 0; // 변화가 있으면 카운트 리셋
                        clearTimeout(timeout);
                        timeout = setTimeout(() => {
                            stabilityCount++;
                            if (stabilityCount >= requiredStability) {
                                observer.disconnect();
                                const waitTime = Date.now() - startTime;
                                callback({
                                    stabilityScore: Math.min(100, Math.max(0, 100 - Math.floor(mutationCount / 10))),
                                    mutationCount: mutationCount,
                                    waitTimeMs: waitTime,
                                    isStable: true
                                });
                            }
                        }, 400); // 설계서: 안정성 감지 간격
                    });
                    
                    observer.observe(document.body, { 
                        childList: true, 
                        subtree: true, 
                        attributes: true,
                        attributeFilter: ['class', 'style'] // 동적 변화 감지
                    });
                    
                    // 최대 대기 시간
                    setTimeout(() => {
                        observer.disconnect();
                        const waitTime = Date.now() - startTime;
                        callback({
                            stabilityScore: Math.min(100, Math.max(0, 100 - Math.floor(mutationCount / 10))),
                            mutationCount: mutationCount,
                            waitTimeMs: waitTime,
                            isStable: false
                        });
                    }, 3000); // 설계서: 최대 3초 대기
                }

                function captureEnhancedData(dynamicStability) {
                    try {
                        // 🔗 **설계서: DOM 앵커 탐지**
                        function findDOManchors() {
                            const anchors = [];
                            const maxAnchors = 20; // 설계서: 앵커 수 제한
                            
                            // 주요 텍스트 요소들 스캔
                            const textSelectors = [
                                'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
                                'p', 'article', 'section', '.title', '.heading',
                                '[data-testid*="heading"]', '[role="heading"]',
                                '.content > p:first-child', '.article-title'
                            ];
                            
                            for (const selector of textSelectors) {
                                if (anchors.length >= maxAnchors) break;
                                
                                const elements = document.querySelectorAll(selector);
                                for (const el of elements) {
                                    if (anchors.length >= maxAnchors) break;
                                    
                                    const text = el.textContent.trim();
                                    if (text.length < 10 || text.length > 100) continue; // 적절한 길이만
                                    
                                    const rect = el.getBoundingClientRect();
                                    const style = window.getComputedStyle(el);
                                    const isSticky = style.position === 'sticky' || style.position === 'fixed';
                                    
                                    // 화면에 보이거나 스크롤 가능 영역에 있는 것만
                                    if (rect.height > 0 && (rect.top < window.innerHeight * 2)) {
                                        anchors.push({
                                            selector: generateUniqueSelector(el),
                                            text: text.substring(0, 50), // 텍스트 길이 제한
                                            position: {
                                                x: window.scrollX + rect.left,
                                                y: window.scrollY + rect.top
                                            },
                                            elementRect: {
                                                x: rect.left,
                                                y: rect.top,
                                                width: rect.width,
                                                height: rect.height
                                            },
                                            isVisible: rect.top >= 0 && rect.top <= window.innerHeight,
                                            zIndex: parseInt(style.zIndex) || 0,
                                            isSticky: isSticky
                                        });
                                    }
                                }
                            }
                            
                            return anchors;
                        }
                        
                        // 📈 **설계서: Lazy Load 패턴 감지**
                        function findLazyLoadPatterns() {
                            const patterns = [];
                            const maxPatterns = 30; // 설계서: 패턴 수 제한
                            
                            // 1. 이미지 lazy loading
                            const lazyImages = document.querySelectorAll('img[data-src], img[loading="lazy"]');
                            for (const img of lazyImages) {
                                if (patterns.length >= maxPatterns) break;
                                patterns.push({
                                    selector: generateUniqueSelector(img),
                                    type: 'image',
                                    triggerDistance: 200, // 기본 트리거 거리
                                    isLoaded: !!img.src && img.src !== img.dataset.src,
                                    loadingState: img.complete ? 'loaded' : 'pending'
                                });
                            }
                            
                            // 2. 무한 스크롤 감지
                            const infiniteScrolls = document.querySelectorAll('[data-infinite], .infinite-scroll, .lazy-load');
                            for (const el of infiniteScrolls) {
                                if (patterns.length >= maxPatterns) break;
                                patterns.push({
                                    selector: generateUniqueSelector(el),
                                    type: 'infinite-scroll',
                                    triggerDistance: 100,
                                    isLoaded: false,
                                    loadingState: 'unknown'
                                });
                            }
                            
                            // 3. iframe lazy loading
                            const lazyIframes = document.querySelectorAll('iframe[data-src]');
                            for (const iframe of lazyIframes) {
                                if (patterns.length >= maxPatterns) break;
                                patterns.push({
                                    selector: generateUniqueSelector(iframe),
                                    type: 'iframe',
                                    triggerDistance: 300,
                                    isLoaded: !!iframe.src && iframe.src !== iframe.dataset.src,
                                    loadingState: 'pending'
                                });
                            }
                            
                            return patterns;
                        }
                        
                        // 🎯 **설계서: 고유 셀렉터 생성**
                        function generateUniqueSelector(element) {
                            if (!element || element.nodeType !== 1) return null;
                            
                            // ID 우선
                            if (element.id) {
                                return `#${element.id}`;
                            }
                            
                            // 데이터 속성 기반
                            const dataAttrs = Array.from(element.attributes)
                                .filter(attr => attr.name.startsWith('data-'))
                                .slice(0, 2) // 최대 2개까지만
                                .map(attr => `[${attr.name}="${attr.value}"]`);
                            if (dataAttrs.length > 0) {
                                const attrSelector = element.tagName.toLowerCase() + dataAttrs.join('');
                                if (document.querySelectorAll(attrSelector).length === 1) {
                                    return attrSelector;
                                }
                            }
                            
                            // 클래스 기반
                            if (element.className && typeof element.className === 'string') {
                                const classes = element.className.trim().split(/\\s+/).slice(0, 3); // 최대 3개 클래스
                                if (classes.length > 0) {
                                    const classSelector = `.${classes.join('.')}`;
                                    const matches = document.querySelectorAll(classSelector);
                                    if (matches.length === 1) {
                                        return classSelector;
                                    } else if (matches.length <= 10) { // 너무 많지 않으면 nth-child 추가
                                        const index = Array.from(matches).indexOf(element) + 1;
                                        return `${classSelector}:nth-child(${index})`;
                                    }
                                }
                            }
                            
                            // 경로 기반 (간단화)
                            let path = [];
                            let current = element;
                            let depth = 0;
                            while (current && current !== document.documentElement && depth < 4) {
                                let selector = current.tagName.toLowerCase();
                                if (current.id) {
                                    path.unshift(`#${current.id}`);
                                    break;
                                }
                                path.unshift(selector);
                                current = current.parentElement;
                                depth++;
                            }
                            return path.join(' > ');
                        }
                        
                        // 기존 스크롤 정보 + 컨테이너 감지
                        function findScrollableElements() {
                            const scrollables = [];
                            const maxElements = 50; // 설계서: 스캔 상한
                            
                            const elements = document.querySelectorAll('*');
                            let count = 0;
                            
                            for (const el of elements) {
                                if (count >= maxElements) break;
                                
                                const style = window.getComputedStyle(el);
                                const overflowY = style.overflowY;
                                const overflowX = style.overflowX;
                                
                                if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                                    (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) {
                                    
                                    const scrollTop = parseFloat(el.scrollTop) || 0;
                                    const scrollLeft = parseFloat(el.scrollLeft) || 0;
                                    
                                    if (scrollTop > 0.1 || scrollLeft > 0.1) {
                                        scrollables.push({
                                            selector: generateUniqueSelector(el) || 'unknown',
                                            top: scrollTop,
                                            left: scrollLeft,
                                            maxTop: el.scrollHeight - el.clientHeight,
                                            maxLeft: el.scrollWidth - el.clientWidth
                                        });
                                        count++;
                                    }
                                }
                            }
                            
                            return scrollables;
                        }
                        
                        // iframe 감지
                        function detectIframeScrolls() {
                            const iframes = [];
                            const iframeElements = document.querySelectorAll('iframe');
                            
                            for (const iframe of iframeElements) {
                                try {
                                    const contentWindow = iframe.contentWindow;
                                    if (contentWindow) {
                                        const scrollX = parseFloat(contentWindow.scrollX) || 0;
                                        const scrollY = parseFloat(contentWindow.scrollY) || 0;
                                        
                                        iframes.push({
                                            selector: generateUniqueSelector(iframe),
                                            scrollX: scrollX,
                                            scrollY: scrollY,
                                            src: iframe.src || ''
                                        });
                                    }
                                } catch(e) {
                                    // Cross-origin iframe
                                    iframes.push({
                                        selector: generateUniqueSelector(iframe),
                                        scrollX: 0,
                                        scrollY: 0,
                                        src: iframe.src || '',
                                        crossOrigin: true
                                    });
                                }
                            }
                            
                            return iframes;
                        }
                        
                        // 메인 실행
                        const domAnchors = findDOManchors();
                        const lazyLoadPatterns = findLazyLoadPatterns();
                        const scrollableElements = findScrollableElements();
                        const iframeScrolls = detectIframeScrolls();
                        
                        const mainScrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                        const mainScrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                        
                        console.log(`🎯 설계서 기반 캡처 완료: 앵커 ${domAnchors.length}개, lazy ${lazyLoadPatterns.length}개`);
                        
                        resolve({
                            domAnchors: domAnchors,
                            lazyLoadPatterns: lazyLoadPatterns,
                            dynamicStability: dynamicStability,
                            scroll: { 
                                x: mainScrollX, 
                                y: mainScrollY,
                                elements: scrollableElements
                            },
                            iframes: iframeScrolls,
                            href: window.location.href,
                            title: document.title,
                            timestamp: Date.now(),
                            viewport: {
                                width: window.innerWidth,
                                height: window.innerHeight
                            },
                            content: {
                                width: document.documentElement.scrollWidth,
                                height: document.documentElement.scrollHeight
                            }
                        });
                    } catch(e) { 
                        console.error('🎯 설계서 캡처 실패:', e);
                        resolve({
                            domAnchors: [],
                            lazyLoadPatterns: [],
                            dynamicStability: { stabilityScore: 0, mutationCount: 0, waitTimeMs: 0, isStable: false },
                            scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0, elements: [] },
                            iframes: []
                        });
                    }
                }

                // 동적 안정성 대기 후 캡처
                if (document.readyState === 'complete') {
                    waitForDynamicStability(captureEnhancedData);
                } else {
                    document.addEventListener('DOMContentLoaded', () => waitForDynamicStability(captureEnhancedData));
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
    
    // MARK: - 💾 **디스크 저장 시스템 (Library/Caches/BFCache)**
    
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
            
            // 4. 인덱스 업데이트
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
            // 5. 설계서: 최신 3개 버전만 유지
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
                    let v1 = Int(url1.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    let v2 = Int(url2.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    return v1 > v2
                }
            
            // 설계서: 최신 3개 제외하고 삭제
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
    
    // MARK: - 💾 **디스크 캐시 로딩**
    
    private func loadDiskCacheIndex() {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.createDirectoryIfNeeded(at: self.bfCacheDirectory)
            
            var loadedCount = 0
            
            do {
                let tabDirs = try FileManager.default.contentsOfDirectory(at: self.bfCacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                
                for tabDir in tabDirs {
                    if tabDir.lastPathComponent.hasPrefix("Tab_") {
                        let pageDirs = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        
                        for pageDir in pageDirs {
                            if pageDir.lastPathComponent.hasPrefix("Page_") {
                                let metadataPath = pageDir.appendingPathComponent("metadata.json")
                                if let data = try? Data(contentsOf: metadataPath),
                                   let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) {
                                    
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
    
    // MARK: - 🔍 **스냅샷 조회 시스템**
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        // 1. 메모리 캐시 확인
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title)")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
    func hasCache(for pageID: UUID) -> Bool {
        if cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) != nil {
            return true
        }
        
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
    
    // MARK: - 🧹 **캐시 정리**
    
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        removeGestureContext(for: tabID)
        removeActiveTransition(for: tabID)
        
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
                self._cacheVersion.removeValue(forKey: pageID)
            }
        }
        
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
            
            let sorted = self._memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            self.dbg("⚠️ 메모리 경고 - 메모리 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🧵 **제스처 시스템 (보존)**
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        webView.allowsBackForwardNavigationGestures = false
        
        guard let tabID = stateModel.tabID else {
            dbg("🧵 탭 ID 없음 - 제스처 설정 스킵")
            return
        }
        
        cleanupExistingGestures(for: webView, tabID: tabID)
        
        let gestureContext = GestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
        setGestureContext(gestureContext, for: tabID)
        
        DispatchQueue.main.async { [weak self] in
            self?.createAndAttachGestures(webView: webView, tabID: tabID)
        }
        
        Self.registerNavigationObserver(for: webView, stateModel: stateModel)
        
        dbg("🎯 설계서 기반 BFCache 제스처 설정 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    private func cleanupExistingGestures(for webView: WKWebView, tabID: UUID) {
        removeGestureContext(for: tabID)
        
        webView.gestureRecognizers?.forEach { gesture in
            if let edgeGesture = gesture as? UIScreenEdgePanGestureRecognizer,
               edgeGesture.edges == .left || edgeGesture.edges == .right {
                webView.removeGestureRecognizer(gesture)
                dbg("🧵 기존 제스처 제거: \(edgeGesture.edges)")
            }
        }
    }
    
    private func createAndAttachGestures(webView: WKWebView, tabID: UUID) {
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        
        objc_setAssociatedObject(leftEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(rightEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        webView.addGestureRecognizer(leftEdge)
        webView.addGestureRecognizer(rightEdge)
        
        dbg("🧵 제스처 연결 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 🧵 **제스처 핸들러 (보존)**
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleGesture(gesture)
            }
            return
        }
        
        guard let tabIDString = objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String,
              let tabID = UUID(uuidString: tabIDString) else {
            dbg("🧵 제스처에서 탭 ID 조회 실패")
            gesture.state = .cancelled
            return
        }
        
        guard let context = getGestureContext(for: tabID) else {
            dbg("🧵 제스처 컨텍스트 없음 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
            gesture.state = .cancelled
            return
        }
        
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
    
    // 🧵 **제스처 상태 처리 (보존)**
    private func processGestureState(gesture: UIScreenEdgePanGestureRecognizer, tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        let width = gesture.view?.bounds.width ?? 1
        
        let absX = abs(translation.x), absY = abs(translation.y)
        let horizontalEnough = absX > 8 && absX > absY
        let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
        
        switch gesture.state {
        case .began:
            guard getActiveTransition(for: tabID) == nil else { 
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                if let existing = getActiveTransition(for: tabID) {
                    existing.previewContainer?.removeFromSuperview()
                    removeActiveTransition(for: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                // 📸 **현재 페이지 즉시 캡처 (높은 우선순위)**
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                }
                
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
    
    // MARK: - 🎯 **전환 애니메이션 (보존)**
    
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
    
    // 🖼️ **미리보기 컨테이너 생성 (보존)**
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
    
    // ℹ️ **정보 카드 생성 (보존)**
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
    
    // 🎬 **전환 완료 (보존)**
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
                self?.performNavigationWithEnhancedRestore(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🎯 **설계서 기반 네비게이션 수행**
    private func performNavigationWithEnhancedRestore(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            removeActiveTransition(for: context.tabID)
            return
        }
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // 🎯 **설계서 기반 BFCache 복원**
        tryEnhancedBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.removeActiveTransition(for: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - 설계서 기반 BFCache \(success ? "성공" : "실패")")
            }
        }
    }
    
    // 🎯 **설계서 기반 BFCache 복원** 
    private func tryEnhancedBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 설계서 기반 복원
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ 설계서 기반 BFCache 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ 설계서 기반 BFCache 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 기본 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            
            let waitTime: TimeInterval = 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                completion(false)
            }
        }
    }

    // 🎬 **전환 취소 (보존)**
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
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryEnhancedBFCacheRestore(stateModel: stateModel, direction: .back) { _ in
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
        tryEnhancedBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    // MARK: - 🔒 **스와이프 제스처 감지 처리 (보존 - 항상 새 페이지 추가)**
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        // 복원 중이면 무시
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        // 🔒 **절대 원칙: 항상 새 페이지로 추가 (히스토리 점프 방지)**
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가 (과거 점프 방지): \(url.absoluteString)")
    }
    
    // MARK: - 🌐 JavaScript 스크립트 (보존)
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🎯 설계서 기반 BFCache 페이지 복원');
                
                // 동적 콘텐츠 새로고침 (필요시)
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
                console.log('📸 설계서 기반 BFCache 페이지 저장');
            }
        });
        
        // Cross-origin iframe 복원 리스너
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                try {
                    const targetX = parseFloat(event.data.scrollX) || 0;
                    const targetY = parseFloat(event.data.scrollY) || 0;
                    
                    console.log('🖼️ Cross-origin iframe 스크롤 복원:', targetX, targetY);
                    
                    window.scrollTo(targetX, targetY);
                    document.documentElement.scrollTop = targetY;
                    document.documentElement.scrollLeft = targetX;
                    document.body.scrollTop = targetY;
                    document.body.scrollLeft = targetX;
                    
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
        TabPersistenceManager.debugMessages.append("[BFCache🎯] \(msg)")
    }
}

// MARK: - UIGestureRecognizerDelegate (보존)
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - CustomWebView 통합 인터페이스 (보존)
extension BFCacheTransitionSystem {
    
    // CustomWebView의 makeUIView에서 호출
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        // BFCache 스크립트 설치
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        
        // 제스처 설치 + 네비게이션 감지
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ 🎯 설계서 기반 BFCache 시스템 설치 완료 (DOM 앵커 + MutationObserver)")
    }
    
    // CustomWebView의 dismantleUIView에서 호출
    static func uninstall(from webView: WKWebView) {
        if let tabIDString = webView.gestureRecognizers?.compactMap({ gesture in
            objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String
        }).first, let tabID = UUID(uuidString: tabIDString) {
            shared.removeGestureContext(for: tabID)
            shared.removeActiveTransition(for: tabID)
        }
        
        unregisterNavigationObserver(for: webView)
        
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        TabPersistenceManager.debugMessages.append("🎯 설계서 기반 BFCache 시스템 제거 완료")
    }
    
    // 버튼 네비게이션 래퍼 (보존)
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
}

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출 (보존)
extension BFCacheTransitionSystem {

    /// 사용자가 링크/폼으로 **떠나기 직전** 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 즉시 캡처 (최고 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📸 떠나기 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화 - 도착 스냅샷**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 캡처 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
        // 이전 페이지들도 순차적으로 캐시 확인 및 캡처
        if stateModel.dataModel.currentPageIndex > 0 {
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                // 캐시가 없는 경우만 메타데이터 저장
                if !hasCache(for: previousRecord.id) {
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollPosition: .zero,
                        timestamp: Date(),
                        captureStatus: .failed,
                        version: 1
                    )
                    
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
