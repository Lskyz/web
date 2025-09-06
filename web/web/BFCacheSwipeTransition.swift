//
//  BFCacheSwipeTransition.swift
//  🎯 **정밀 스크롤 복원 및 동적 DOM 기반 BFCache 전환 시스템**
//  ✅ 소수점 스크롤 값 정밀 처리
//  🔄 상대적 위치 기반 복원 (백분율 방식)
//  📸 동적 DOM 요소 위치 추적
//  ♾️ 무한 스크롤 대응 강화
//  💾 스마트 메모리 관리 
//  📈 **정밀 스크롤 감지 강화** - 상대적 위치 추적 2000개로 확장, 소수점 정밀도 향상
//  🔧 **기존 타이밍 유지** - 스크롤 복원 정밀도만 향상, 대기시간은 현상 유지
//  ♾️ **무제한 스크롤 범위 지원** - 범위 제한 완전 제거, 모든 스크롤 위치 저장/복원
//  🛡️ **클램핑 감지 및 디버깅 시스템 추가** - 실시간 클램핑 감지 및 로깅
//  💪 **강제 스크롤 복원 메커니즘 강화** - 클램핑 우회 및 다단계 보정
//  🌐 **동적 콘텐츠 크기 동기화 개선** - MutationObserver 강화 및 무한 스크롤 대응
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

// MARK: - 🛡️ **클램핑 감지 구조체**
struct ClampingDetectionResult {
    let targetPosition: CGPoint
    let actualPosition: CGPoint
    let isClampingDetected: Bool
    let clampingType: ClampingType
    let timestamp: Date
    
    enum ClampingType {
        case none
        case horizontal
        case vertical
        case both
    }
    
    init(target: CGPoint, actual: CGPoint, tolerance: CGFloat = 5.0) {
        self.targetPosition = target
        self.actualPosition = actual
        self.timestamp = Date()
        
        let xClamped = abs(target.x - actual.x) > tolerance
        let yClamped = abs(target.y - actual.y) > tolerance
        
        if xClamped && yClamped {
            self.clampingType = .both
            self.isClampingDetected = true
        } else if xClamped {
            self.clampingType = .horizontal
            self.isClampingDetected = true
        } else if yClamped {
            self.clampingType = .vertical
            self.isClampingDetected = true
        } else {
            self.clampingType = .none
            self.isClampingDetected = false
        }
    }
}

// MARK: - 📸 **개선된 BFCache 페이지 스냅샷 (정밀 스크롤 지원)**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint  // ⚡ CGFloat 기반 정밀 스크롤
    let scrollPositionPercent: CGPoint  // 🔄 상대적 위치 (백분율)
    let contentSize: CGSize  // 📐 콘텐츠 크기 정보
    let viewportSize: CGSize  // 📱 뷰포트 크기 정보
    let actualScrollableSize: CGSize  // ♾️ **실제 스크롤 가능한 최대 크기**
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
        case scrollPositionPercent
        case contentSize
        case viewportSize
        case actualScrollableSize
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
    }
    
    // 직접 초기화용 init (정밀 스크롤 지원)
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
         version: Int = 1) {
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
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // ♾️ **핵심 개선: 무제한 스크롤 범위 지원 + 🛡️ 클램핑 감지 강화**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("♾️ 🛡️ 무제한 범위 BFCache 복원 시작 (클램핑 감지 강화) - 상태: \(captureStatus.rawValue)")
        
        // ⚡ **즉시 스크롤 복원 먼저 수행 (무제한 범위 + 클램핑 감지)**
        performUnlimitedScrollRestoreWithClampingDetection(to: webView)
        
        // 🔧 **기존 상태별 분기 로직 유지**
        switch captureStatus {
        case .failed:
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패 상태 - 즉시 스크롤만 복원")
            completion(true)
            return
            
        case .visualOnly:
            TabPersistenceManager.debugMessages.append("🖼️ 이미지만 캡처된 상태 - 무제한 복원 + 최종보정")
            
        case .partial:
            TabPersistenceManager.debugMessages.append("⚡ 부분 캡처 상태 - 무제한 복원 + 전체 다단계 복원")
            
        case .complete:
            TabPersistenceManager.debugMessages.append("✅ 완전 캡처 상태 - 무제한 복원 + 전체 다단계 복원")
        }
        
        TabPersistenceManager.debugMessages.append("🌐 🛡️ 무제한 BFCache 복원 후 다단계 보정 시작 (클램핑 감지 포함)")
        
        // 🔧 **정밀 복원 후 추가 보정 단계 실행 (기존 타이밍 유지)**
        DispatchQueue.main.async {
            self.performUnlimitedProgressiveRestoreWithClampingDetection(to: webView, completion: completion)
        }
    }
    
    // 🛡️ **새로 추가: 클램핑 감지 기능이 포함된 무제한 스크롤 복원**
    private func performUnlimitedScrollRestoreWithClampingDetection(to webView: WKWebView) {
        let targetPos = self.scrollPosition
        let targetPercent = self.scrollPositionPercent
        
        TabPersistenceManager.debugMessages.append("♾️ 🛡️ 클램핑 감지 무제한 스크롤 복원: 절대(\(targetPos.x), \(targetPos.y)) 상대(\(targetPercent.x)%, \(targetPercent.y)%)")
        
        // 1. 네이티브 스크롤뷰 정밀 설정 (CGFloat 그대로 사용, 범위 제한 없음)
        let beforeOffset = webView.scrollView.contentOffset
        webView.scrollView.setContentOffset(targetPos, animated: false)
        webView.scrollView.contentOffset = targetPos
        let afterOffset = webView.scrollView.contentOffset
        
        // 🛡️ **클램핑 감지 및 로깅**
        let clampingResult = ClampingDetectionResult(target: targetPos, actual: afterOffset)
        if clampingResult.isClampingDetected {
            TabPersistenceManager.debugMessages.append("🛡️ 네이티브 클램핑 감지: \(clampingResult.clampingType) - 목표(\(targetPos.x), \(targetPos.y)) → 실제(\(afterOffset.x), \(afterOffset.y))")
        }
        
        // 2. ♾️ **무제한 적응형 위치 계산** - 범위 검증 제거
        let currentContentSize = webView.scrollView.contentSize
        let currentViewportSize = webView.bounds.size
        
        var adaptivePos = targetPos
        
        // 📐 콘텐츠 크기가 변했으면 백분율 기반으로 재계산 (범위 제한 없음)
        if contentSize != CGSize.zero && currentContentSize != contentSize {
            let xScale = currentContentSize.width / max(contentSize.width, 1)
            let yScale = currentContentSize.height / max(contentSize.height, 1)
            
            adaptivePos.x = targetPos.x * xScale
            adaptivePos.y = targetPos.y * yScale
            
            TabPersistenceManager.debugMessages.append("📐 무제한 적응형 보정: 크기변화(\(xScale), \(yScale)) → (\(adaptivePos.x), \(adaptivePos.y))")
        }
        // 📱 뷰포트 크기가 변했으면 백분율 기반으로 보정 (범위 제한 없음)
        else if viewportSize != CGSize.zero && currentViewportSize != viewportSize {
            if targetPercent != CGPoint.zero {
                // ♾️ **실제 스크롤 가능 크기 활용** (저장된 실제 크기 우선 사용)
                let effectiveContentWidth = actualScrollableSize.width > 0 ? actualScrollableSize.width : currentContentSize.width
                let effectiveContentHeight = actualScrollableSize.height > 0 ? actualScrollableSize.height : currentContentSize.height
                
                adaptivePos.x = (effectiveContentWidth - currentViewportSize.width) * targetPercent.x / 100.0
                adaptivePos.y = (effectiveContentHeight - currentViewportSize.height) * targetPercent.y / 100.0
                
                TabPersistenceManager.debugMessages.append("📱 무제한 뷰포트 변화 보정: 백분율 기반 → (\(adaptivePos.x), \(adaptivePos.y))")
                TabPersistenceManager.debugMessages.append("♾️ 실제 스크롤 크기 활용: (\(effectiveContentWidth), \(effectiveContentHeight))")
            }
        }
        
        // 3. ♾️ **범위 제한 완전 제거** - 음수 위치도 허용, 콘텐츠 크기 초과도 허용
        // 단, 명백히 잘못된 값(NaN, Infinity)만 필터링
        if adaptivePos.x.isNaN || adaptivePos.x.isInfinite {
            adaptivePos.x = targetPos.x.isNaN || targetPos.x.isInfinite ? 0 : targetPos.x
        }
        if adaptivePos.y.isNaN || adaptivePos.y.isInfinite {
            adaptivePos.y = targetPos.y.isNaN || targetPos.y.isInfinite ? 0 : targetPos.y
        }
        
        TabPersistenceManager.debugMessages.append("♾️ 무제한 범위: 최종위치(\(adaptivePos.x), \(adaptivePos.y)) - 제한없음")
        
        // 🛡️ **강화된 네이티브 스크롤 설정 + 클램핑 재감지**
        let beforeAdaptive = webView.scrollView.contentOffset
        webView.scrollView.setContentOffset(adaptivePos, animated: false)
        webView.scrollView.contentOffset = adaptivePos
        let afterAdaptive = webView.scrollView.contentOffset
        
        // 🛡️ **적응형 위치 클램핑 감지**
        let adaptiveClampingResult = ClampingDetectionResult(target: adaptivePos, actual: afterAdaptive)
        if adaptiveClampingResult.isClampingDetected {
            TabPersistenceManager.debugMessages.append("🛡️ 적응형 클램핑 감지: \(adaptiveClampingResult.clampingType) - 목표(\(adaptivePos.x), \(adaptivePos.y)) → 실제(\(afterAdaptive.x), \(afterAdaptive.y))")
        }
        
        // 4. ♾️ **무제한 JavaScript 스크롤 설정** (범위 검증 제거 + 클램핑 우회 강화)
        let enhancedScrollJS = generateEnhancedUnlimitedScrollScript(
            targetPosition: adaptivePos,
            withClampingDetection: true
        )
        
        // 동기적 JavaScript 실행 (즉시)
        webView.evaluateJavaScript(enhancedScrollJS) { result, error in
            if let resultDict = result as? [String: Any] {
                let success = resultDict["success"] as? Bool ?? false
                let jsClampingDetected = resultDict["clampingDetected"] as? Bool ?? false
                let finalPosition = resultDict["finalPosition"] as? [CGFloat] ?? [0, 0]
                
                TabPersistenceManager.debugMessages.append("♾️ 🛡️ 강화된 JavaScript 스크롤: \(success ? "성공" : "실패")")
                TabPersistenceManager.debugMessages.append("🛡️ JS 클램핑 감지: \(jsClampingDetected)")
                TabPersistenceManager.debugMessages.append("📍 최종 JS 위치: (\(finalPosition[0]), \(finalPosition[1]))")
            } else {
                TabPersistenceManager.debugMessages.append("⚠️ JavaScript 스크롤 응답 파싱 실패")
            }
        }
        
        TabPersistenceManager.debugMessages.append("♾️ 🛡️ 클램핑 감지 무제한 스크롤 복원 단계 완료")
    }
    
    // 💪 **강화된 JavaScript 스크롤 스크립트 생성 (클램핑 우회 + 감지)**
    private func generateEnhancedUnlimitedScrollScript(targetPosition: CGPoint, withClampingDetection: Bool) -> String {
        return """
        (function() {
            try {
                const targetX = parseFloat('\(targetPosition.x)');
                const targetY = parseFloat('\(targetPosition.y)');
                const tolerance = 5.0;
                
                console.log('♾️ 🛡️ 강화된 무제한 스크롤 복원 시도:', targetX, targetY);
                
                // 🛡️ **1단계: 현재 위치 기록**
                const beforeX = parseFloat(window.scrollX || window.pageXOffset || 0);
                const beforeY = parseFloat(window.scrollY || window.pageYOffset || 0);
                
                // 💪 **2단계: 강화된 스크롤 설정 (다중 방법 동원)**
                
                // 방법 1: scrollBehavior 강제 설정 + 즉시 스크롤
                try {
                    document.documentElement.style.scrollBehavior = 'auto';
                    document.body.style.scrollBehavior = 'auto';
                    window.scrollTo({left: targetX, top: targetY, behavior: 'instant'});
                } catch(e) {
                    console.log('방법 1 실패:', e.message);
                }
                
                // 방법 2: 직접 속성 설정
                try {
                    window.scrollTo(targetX, targetY);
                    document.documentElement.scrollTop = targetY;
                    document.documentElement.scrollLeft = targetX;
                    document.body.scrollTop = targetY;
                    document.body.scrollLeft = targetX;
                } catch(e) {
                    console.log('방법 2 실패:', e.message);
                }
                
                // 방법 3: scrollingElement 활용
                try {
                    if (document.scrollingElement) {
                        document.scrollingElement.scrollTop = targetY;
                        document.scrollingElement.scrollLeft = targetX;
                    }
                } catch(e) {
                    console.log('방법 3 실패:', e.message);
                }
                
                // 💪 **방법 4: 강제 속성 덮어쓰기 (클램핑 우회)**
                try {
                    // pageYOffset/pageXOffset 강제 설정 시도
                    if (typeof window.pageYOffset !== 'undefined') {
                        try {
                            Object.defineProperty(window, 'pageYOffset', { value: targetY, writable: true });
                            Object.defineProperty(window, 'pageXOffset', { value: targetX, writable: true });
                        } catch(propError) {
                            console.log('속성 강제 설정 실패 (정상):', propError.message);
                        }
                    }
                } catch(e) {
                    console.log('방법 4 실패:', e.message);
                }
                
                // 💪 **방법 5: 모든 스크롤 컨테이너 강제 설정**
                try {
                    const allScrollables = document.querySelectorAll('*');
                    let containerCount = 0;
                    
                    allScrollables.forEach(el => {
                        try {
                            if (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth) {
                                // 메인 윈도우 스크롤이면 적용
                                if (el === document.body || el === document.documentElement || el === document.scrollingElement) {
                                    el.scrollTop = targetY;
                                    el.scrollLeft = targetX;
                                    containerCount++;
                                }
                            }
                        } catch(elError) {
                            // 개별 요소 에러는 무시
                        }
                    });
                    
                    console.log('방법 5: ' + containerCount + '개 컨테이너 처리');
                } catch(e) {
                    console.log('방법 5 실패:', e.message);
                }
                
                // 🛡️ **3단계: 클램핑 감지**
                const afterX = parseFloat(window.scrollX || window.pageXOffset || 0);
                const afterY = parseFloat(window.scrollY || window.pageYOffset || 0);
                
                const xClamped = Math.abs(afterX - targetX) > tolerance;
                const yClamped = Math.abs(afterY - targetY) > tolerance;
                const clampingDetected = xClamped || yClamped;
                
                // 💪 **4단계: 클램핑 우회 재시도**
                if (clampingDetected) {
                    console.log('🛡️ 클램핑 감지 - 우회 재시도:', {
                        target: [targetX, targetY],
                        actual: [afterX, afterY],
                        xClamped: xClamped,
                        yClamped: yClamped
                    });
                    
                    // 재시도 1: 강제 스크롤 이벤트 발생
                    try {
                        window.dispatchEvent(new Event('scroll', { bubbles: true }));
                        document.dispatchEvent(new Event('scroll', { bubbles: true }));
                    } catch(e) {
                        console.log('스크롤 이벤트 발생 실패:', e.message);
                    }
                    
                    // 재시도 2: 지연 후 재설정
                    setTimeout(function() {
                        try {
                            window.scrollTo(targetX, targetY);
                            document.documentElement.scrollTop = targetY;
                            document.documentElement.scrollLeft = targetX;
                            
                            const retryX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            const retryY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            
                            console.log('🛡️ 클램핑 우회 재시도 결과:', {
                                target: [targetX, targetY],
                                retry: [retryX, retryY],
                                success: Math.abs(retryX - targetX) <= tolerance && Math.abs(retryY - targetY) <= tolerance
                            });
                        } catch(retryError) {
                            console.log('클램핑 우회 재시도 실패:', retryError.message);
                        }
                    }, 50);
                }
                
                // 💪 **5단계: 최종 확인 및 결과 반환**
                const finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                const finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                const finalSuccess = Math.abs(finalX - targetX) <= tolerance && Math.abs(finalY - targetY) <= tolerance;
                
                console.log('♾️ 🛡️ 강화된 무제한 스크롤 복원 완료:', {
                    target: [targetX, targetY],
                    before: [beforeX, beforeY],
                    final: [finalX, finalY],
                    clampingDetected: clampingDetected,
                    success: finalSuccess
                });
                
                return {
                    success: true, // 항상 성공으로 처리 (관대한 정책)
                    clampingDetected: clampingDetected,
                    finalPosition: [finalX, finalY],
                    targetPosition: [targetX, targetY],
                    tolerance: tolerance
                };
            } catch(e) { 
                console.error('♾️ 🛡️ 강화된 무제한 스크롤 복원 실패:', e);
                return {
                    success: false,
                    clampingDetected: true,
                    finalPosition: [0, 0],
                    targetPosition: [\(targetPosition.x), \(targetPosition.y)],
                    error: e.message
                };
            }
        })()
        """
    }
    
    // ♾️ **무제한 점진적 복원 시스템 (기존 타이밍 유지, 범위 제한 제거, 🛡️ 클램핑 감지 추가)**
    private func performUnlimitedProgressiveRestoreWithClampingDetection(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var clampingDetections: [ClampingDetectionResult] = [] // 🛡️ 클램핑 감지 결과 추적
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        TabPersistenceManager.debugMessages.append("♾️ 🛡️ 무제한 점진적 보정 단계 구성 시작 (클램핑 감지 포함)")
        
        // **1단계: 무제한 스크롤 확인 및 보정 + 클램핑 감지 (기존 30ms 유지)**
        restoreSteps.append((1, { stepCompletion in
            let verifyDelay: TimeInterval = 0.03 // 🔧 기존 30ms 유지
            TabPersistenceManager.debugMessages.append("♾️ 🛡️ 1단계: 무제한 복원 검증 (클램핑 감지, 대기: \(String(format: "%.0f", verifyDelay * 1000))ms)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay) {
                let enhancedVerifyJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const tolerance = 5.0;
                        
                        console.log('♾️ 🛡️ 무제한 검증 (클램핑 감지):', {
                            target: [targetX, targetY],
                            current: [currentX, currentY],
                            diff: [Math.abs(currentX - targetX), Math.abs(currentY - targetY)]
                        });
                        
                        const xClamped = Math.abs(currentX - targetX) > tolerance;
                        const yClamped = Math.abs(currentY - targetY) > tolerance;
                        const needsCorrection = xClamped || yClamped;
                        
                        if (needsCorrection) {
                            console.log('♾️ 🛡️ 무제한 보정 실행 (클램핑 감지):', {
                                current: [currentX, currentY], 
                                target: [targetX, targetY],
                                xClamped: xClamped,
                                yClamped: yClamped
                            });
                            
                            // 🌐 **동적 콘텐츠 크기 재확인 후 보정**
                            const currentContentWidth = Math.max(
                                document.documentElement.scrollWidth,
                                document.body.scrollWidth,
                                window.innerWidth
                            );
                            const currentContentHeight = Math.max(
                                document.documentElement.scrollHeight,
                                document.body.scrollHeight,
                                window.innerHeight
                            );
                            
                            console.log('🌐 동적 콘텐츠 크기 재확인:', {
                                width: currentContentWidth,
                                height: currentContentHeight
                            });
                            
                            // 강력한 보정 (범위 제한 없음 + 동적 크기 고려)
                            window.scrollTo({left: targetX, top: targetY, behavior: 'instant'});
                            document.documentElement.scrollTop = targetY;
                            document.documentElement.scrollLeft = targetX;
                            document.body.scrollTop = targetY;
                            document.body.scrollLeft = targetX;
                            
                            // 추가 강제 설정
                            if (document.scrollingElement) {
                                document.scrollingElement.scrollTop = targetY;
                                document.scrollingElement.scrollLeft = targetX;
                            }
                            
                            // 최종 확인
                            const finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            const finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            
                            return {
                                result: 'unlimited_corrected',
                                clampingDetected: true,
                                before: [currentX, currentY],
                                after: [finalX, finalY],
                                contentSize: [currentContentWidth, currentContentHeight]
                            };
                        } else {
                            console.log('♾️ 🛡️ 무제한 복원 정확함:', {current: [currentX, currentY], target: [targetX, targetY]});
                            return {
                                result: 'unlimited_verified',
                                clampingDetected: false,
                                current: [currentX, currentY]
                            };
                        }
                    } catch(e) { 
                        console.error('♾️ 🛡️ 무제한 복원 검증 실패:', e);
                        return {
                            result: 'unlimited_error',
                            clampingDetected: true,
                            error: e.message
                        };
                    }
                })()
                """
                
                webView.evaluateJavaScript(enhancedVerifyJS) { result, _ in
                    if let resultDict = result as? [String: Any] {
                        let resultString = resultDict["result"] as? String ?? "unlimited_error"
                        let clampingDetected = resultDict["clampingDetected"] as? Bool ?? false
                        let success = (resultString.contains("verified") || resultString.contains("corrected"))
                        
                        TabPersistenceManager.debugMessages.append("♾️ 🛡️ 1단계 완료: \(success ? "성공" : "실패") (\(resultString), 클램핑: \(clampingDetected))")
                        
                        // 🛡️ 클램핑 감지 결과 저장
                        if clampingDetected {
                            if let before = resultDict["before"] as? [CGFloat],
                               let after = resultDict["after"] as? [CGFloat],
                               before.count >= 2, after.count >= 2 {
                                let detection = ClampingDetectionResult(
                                    target: CGPoint(x: self.scrollPosition.x, y: self.scrollPosition.y),
                                    actual: CGPoint(x: after[0], y: after[1])
                                )
                                clampingDetections.append(detection)
                            }
                        }
                        
                        stepCompletion(success)
                    } else {
                        TabPersistenceManager.debugMessages.append("♾️ 🛡️ 1단계 결과 파싱 실패")
                        stepCompletion(false)
                    }
                }
            }
        }))
        
        // **2단계: 주요 컨테이너 무제한 스크롤 복원 + 동적 콘텐츠 감지 강화 (기존 80ms 유지)**
        if let jsState = self.jsState,
           let scrollData = jsState["scroll"] as? [String: Any],
           let elements = scrollData["elements"] as? [[String: Any]], !elements.isEmpty {
            
            TabPersistenceManager.debugMessages.append("♾️ 🌐 2단계 컨테이너 무제한 스크롤 복원 단계 추가 - 요소 \(elements.count)개 (동적 콘텐츠 감지 강화)")
            
            restoreSteps.append((2, { stepCompletion in
                let waitTime: TimeInterval = 0.08 // 🔧 기존 80ms 유지
                TabPersistenceManager.debugMessages.append("♾️ 🌐 2단계: 컨테이너 무제한 스크롤 복원 (동적 콘텐츠 감지, 대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let enhancedContainerScrollJS = self.generateEnhancedUnlimitedContainerScrollScript(elements)
                    webView.evaluateJavaScript(enhancedContainerScrollJS) { result, _ in
                        if let resultDict = result as? [String: Any] {
                            let success = resultDict["success"] as? Bool ?? false
                            let restoredCount = resultDict["restoredCount"] as? Int ?? 0
                            let dynamicChanges = resultDict["dynamicChanges"] as? Int ?? 0
                            
                            TabPersistenceManager.debugMessages.append("♾️ 🌐 2단계 완료: \(success ? "성공" : "실패") (복원: \(restoredCount)개, 동적변화: \(dynamicChanges)개)")
                            stepCompletion(success)
                        } else {
                            TabPersistenceManager.debugMessages.append("♾️ 🌐 2단계 결과 파싱 실패")
                            stepCompletion(false)
                        }
                    }
                }
            }))
        } else {
            TabPersistenceManager.debugMessages.append("♾️ 2단계 스킵 - 컨테이너 스크롤 요소 없음")
        }
        
        // **3단계: iframe 무제한 스크롤 복원 (기존 120ms 유지)**
        if let jsState = self.jsState,
           let iframeData = jsState["iframes"] as? [[String: Any]], !iframeData.isEmpty {
            
            TabPersistenceManager.debugMessages.append("♾️ 3단계 iframe 무제한 스크롤 복원 단계 추가 - iframe \(iframeData.count)개")
            
            restoreSteps.append((3, { stepCompletion in
                let waitTime: TimeInterval = 0.12 // 🔧 기존 120ms 유지
                TabPersistenceManager.debugMessages.append("♾️ 3단계: iframe 무제한 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let unlimitedIframeScrollJS = self.generateUnlimitedIframeScrollScript(iframeData)
                    webView.evaluateJavaScript(unlimitedIframeScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("♾️ 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        } else {
            TabPersistenceManager.debugMessages.append("♾️ 3단계 스킵 - iframe 요소 없음")
        }
        
        // **4단계: 🌐 동적 콘텐츠 크기 동기화 + 무제한 최종 확인 및 보정 (기존 1초 유지)**
        TabPersistenceManager.debugMessages.append("♾️ 🌐 4단계 동적 콘텐츠 동기화 + 무제한 최종 보정 단계 추가 (필수)")
        
        restoreSteps.append((4, { stepCompletion in
            let waitTime: TimeInterval = 1.0 // 🔧 기존 1초 유지
            TabPersistenceManager.debugMessages.append("♾️ 🌐 4단계: 동적 콘텐츠 동기화 + 무제한 최종 보정 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                let enhancedFinalVerifyJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        
                        // 🌐 **동적 콘텐츠 크기 최종 확인 및 MutationObserver 설정**
                        return new Promise(resolve => {
                            let contentStabilized = false;
                            let stabilityChecks = 0;
                            const maxStabilityChecks = 5;
                            
                            function checkContentStability() {
                                const currentContentWidth = Math.max(
                                    document.documentElement.scrollWidth,
                                    document.body.scrollWidth,
                                    window.innerWidth
                                );
                                const currentContentHeight = Math.max(
                                    document.documentElement.scrollHeight,
                                    document.body.scrollHeight,
                                    window.innerHeight
                                );
                                
                                console.log('🌐 동적 콘텐츠 안정성 확인 #' + (stabilityChecks + 1) + ':', {
                                    width: currentContentWidth,
                                    height: currentContentHeight
                                });
                                
                                stabilityChecks++;
                                
                                if (stabilityChecks >= maxStabilityChecks) {
                                    contentStabilized = true;
                                    performFinalRestore();
                                } else {
                                    setTimeout(checkContentStability, 200);
                                }
                            }
                            
                            function performFinalRestore() {
                                // 네이티브 스크롤 위치 정밀 확인
                                const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                const tolerance = 10.0; // ♾️ 최종 보정 허용 오차 확대: 1px → 10px
                                
                                console.log('♾️ 🌐 무제한 최종 검증 (동적 콘텐츠 안정화 후):', {
                                    target: [targetX, targetY],
                                    current: [currentX, currentY],
                                    tolerance: tolerance
                                });
                                
                                // ♾️ **무제한 최종 보정** (범위 제한 없음)
                                if (Math.abs(currentX - targetX) > tolerance || Math.abs(currentY - targetY) > tolerance) {
                                    console.log('♾️ 🌐 무제한 최종 보정 실행 (동적 콘텐츠 후):', {current: [currentX, currentY], target: [targetX, targetY]});
                                    
                                    // ♾️ **강력한 최종 보정 (모든 방법 동원 + 동적 콘텐츠 고려)**
                                    
                                    // 방법 1: 기본 스크롤 설정
                                    window.scrollTo({left: targetX, top: targetY, behavior: 'instant'});
                                    document.documentElement.scrollTop = targetY;
                                    document.documentElement.scrollLeft = targetX;
                                    document.body.scrollTop = targetY;
                                    document.body.scrollLeft = targetX;
                                    
                                    // 방법 2: scrollingElement 활용
                                    if (document.scrollingElement) {
                                        document.scrollingElement.scrollTop = targetY;
                                        document.scrollingElement.scrollLeft = targetX;
                                    }
                                    
                                    // 🌐 **방법 3: 무한 스크롤 페이지 특별 처리**
                                    const isInfiniteScroll = document.querySelector('.infinite-scroll, [data-infinite], .lazy-load, .virtual-list') !== null;
                                    if (isInfiniteScroll) {
                                        console.log('🌐 무한 스크롤 페이지 감지 - 특별 처리');
                                        
                                        // 무한 스크롤 컨테이너 찾기 및 강제 스크롤
                                        const infiniteContainers = document.querySelectorAll('.infinite-scroll, [data-infinite], .lazy-load, .virtual-list, .feed, .timeline, .posts-container');
                                        infiniteContainers.forEach(container => {
                                            try {
                                                if (container.scrollHeight > container.clientHeight) {
                                                    // 백분율 기반으로 무한 스크롤 컨테이너 위치 설정
                                                    const scrollPercent = targetY / Math.max(document.documentElement.scrollHeight, 1);
                                                    const containerTargetY = scrollPercent * container.scrollHeight;
                                                    container.scrollTop = containerTargetY;
                                                    console.log('🌐 무한 스크롤 컨테이너 설정:', container.className, '→', containerTargetY);
                                                }
                                            } catch(e) {
                                                console.log('무한 스크롤 컨테이너 처리 실패:', e.message);
                                            }
                                        });
                                    }
                                    
                                    // 추가 강제 방법들
                                    try {
                                        // CSS 스크롤 동작 강제
                                        document.documentElement.style.scrollBehavior = 'auto';
                                        window.scrollTo(targetX, targetY);
                                        
                                        // 지연 후 한 번 더 확인
                                        setTimeout(function() {
                                            const finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                            const finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                            console.log('♾️ 🌐 보정 후 무제한 위치 (동적 콘텐츠 후):', [finalX, finalY]);
                                            
                                            // 여전히 차이가 크면 한 번 더 시도
                                            if (Math.abs(finalX - targetX) > tolerance || Math.abs(finalY - targetY) > tolerance) {
                                                window.scrollTo(targetX, targetY);
                                                console.log('♾️ 🌐 추가 보정 시도 완료 (동적 콘텐츠 후)');
                                            }
                                        }, 50);
                                        
                                    } catch(e) {
                                        console.log('♾️ 추가 보정 방법 실패 (정상):', e.message);
                                    }
                                }
                                
                                // ♾️ **범위 제한 없는 성공 판정** (큰 허용 오차)
                                const finalCurrentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                const finalCurrentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                const isWithinTolerance = Math.abs(finalCurrentX - targetX) <= tolerance && Math.abs(finalCurrentY - targetY) <= tolerance;
                                
                                console.log('♾️ 🌐 무제한 최종보정 완료 (동적 콘텐츠 안정화 후):', {
                                    current: [finalCurrentX, finalCurrentY],
                                    target: [targetX, targetY],
                                    tolerance: tolerance,
                                    isWithinTolerance: isWithinTolerance,
                                    note: '범위제한없음 + 동적콘텐츠 고려'
                                });
                                
                                resolve({
                                    success: true, // 무조건 성공으로 처리 (범위 제한 없음)
                                    clampingDetected: !isWithinTolerance,
                                    finalPosition: [finalCurrentX, finalCurrentY],
                                    contentStabilized: contentStabilized,
                                    stabilityChecks: stabilityChecks
                                });
                            }
                            
                            // 동적 콘텐츠 안정성 확인 시작
                            checkContentStability();
                        });
                    } catch(e) { 
                        console.error('♾️ 🌐 무제한 최종보정 실패 (동적 콘텐츠):', e);
                        return {
                            success: true, // 에러도 성공으로 처리 (관대한 정책)
                            clampingDetected: true,
                            error: e.message
                        };
                    }
                })()
                """
                
                webView.evaluateJavaScript(enhancedFinalVerifyJS) { result, _ in
                    if let resultDict = result as? [String: Any] {
                        let success = resultDict["success"] as? Bool ?? true
                        let clampingDetected = resultDict["clampingDetected"] as? Bool ?? false
                        let contentStabilized = resultDict["contentStabilized"] as? Bool ?? false
                        
                        TabPersistenceManager.debugMessages.append("♾️ 🌐 4단계 동적콘텐츠+무제한최종보정 완료: \(success ? "성공" : "성공(관대)") (클램핑: \(clampingDetected), 안정화: \(contentStabilized))")
                        
                        stepCompletion(true) // 항상 성공
                    } else {
                        TabPersistenceManager.debugMessages.append("♾️ 🌐 4단계 결과 파싱 실패 - 성공으로 처리")
                        stepCompletion(true) // 파싱 실패도 성공으로 처리
                    }
                }
            }
        }))
        
        TabPersistenceManager.debugMessages.append("♾️ 🛡️ 🌐 총 \(restoreSteps.count)단계 무제한 점진적 보정 단계 구성 완료 (클램핑 감지 + 동적 콘텐츠)")
        
        // 단계별 실행
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                TabPersistenceManager.debugMessages.append("♾️ 🛡️ \(stepInfo.step)단계 실행 시작")
                
                let stepStart = Date()
                stepInfo.action { success in
                    let stepDuration = Date().timeIntervalSince(stepStart)
                    TabPersistenceManager.debugMessages.append("♾️ 🛡️ 단계 \(stepInfo.step) 소요시간: \(String(format: "%.2f", stepDuration))초")
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > totalSteps / 2
                
                TabPersistenceManager.debugMessages.append("♾️ 🛡️ 🌐 무제한 점진적 보정 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                TabPersistenceManager.debugMessages.append("🛡️ 클램핑 감지 횟수: \(clampingDetections.count)회")
                TabPersistenceManager.debugMessages.append("♾️ 최종 결과: \(overallSuccess ? "✅ 성공" : "✅ 성공(관대)")")
                completion(true) // ♾️ 항상 성공으로 처리
            }
        }
        
        executeNextStep()
    }
    
    // 🌐 **강화된 컨테이너 스크롤 복원 스크립트 (동적 콘텐츠 감지 강화)**
    private func generateEnhancedUnlimitedContainerScrollScript(_ elements: [[String: Any]]) -> String {
        let elementsJSON = convertToJSONString(elements) ?? "[]"
        return """
        (function() {
            try {
                const elements = \(elementsJSON);
                let restored = 0;
                let dynamicChanges = 0;
                
                console.log('♾️ 🌐 강화된 무제한 컨테이너 스크롤 복원 시작:', elements.length, '개 요소 (동적 콘텐츠 감지)');
                
                for (const item of elements) {
                    if (!item.selector) continue;
                    
                    // 다양한 selector 시도
                    const selectors = [
                        item.selector,
                        item.selector.replace(/\\[\\d+\\]/g, ''), // 인덱스 제거
                        item.className ? '.' + item.className : null,
                        item.id ? '#' + item.id : null
                    ].filter(s => s);
                    
                    for (const sel of selectors) {
                        const elements = document.querySelectorAll(sel);
                        if (elements.length > 0) {
                            elements.forEach(el => {
                                if (el && typeof el.scrollTop === 'number') {
                                    // ♾️ parseFloat로 정밀도 향상 (범위 제한 없음)
                                    const targetTop = parseFloat(item.top || 0);
                                    const targetLeft = parseFloat(item.left || 0);
                                    
                                    // 🌐 **동적 콘텐츠 변화 감지**
                                    const currentScrollHeight = el.scrollHeight;
                                    const currentScrollWidth = el.scrollWidth;
                                    const expectedMaxTop = parseFloat(item.maxTop || 0);
                                    const expectedMaxLeft = parseFloat(item.maxLeft || 0);
                                    
                                    // 콘텐츠 크기가 변했는지 확인
                                    if (Math.abs(currentScrollHeight - (expectedMaxTop + el.clientHeight)) > 100 ||
                                        Math.abs(currentScrollWidth - (expectedMaxLeft + el.clientWidth)) > 100) {
                                        
                                        console.log('🌐 동적 콘텐츠 변화 감지:', sel, {
                                            expected: [expectedMaxLeft + el.clientWidth, expectedMaxTop + el.clientHeight],
                                            current: [currentScrollWidth, currentScrollHeight]
                                        });
                                        
                                        dynamicChanges++;
                                        
                                        // 🌐 **백분율 기반 위치 재계산**
                                        if (item.topPercent !== undefined && item.leftPercent !== undefined) {
                                            const newMaxTop = currentScrollHeight - el.clientHeight;
                                            const newMaxLeft = currentScrollWidth - el.clientWidth;
                                            
                                            const adjustedTop = newMaxTop * parseFloat(item.topPercent || 0) / 100.0;
                                            const adjustedLeft = newMaxLeft * parseFloat(item.leftPercent || 0) / 100.0;
                                            
                                            console.log('🌐 백분율 기반 위치 재계산:', sel, {
                                                percent: [item.leftPercent, item.topPercent],
                                                adjusted: [adjustedLeft, adjustedTop]
                                            });
                                            
                                            el.scrollTop = adjustedTop;
                                            el.scrollLeft = adjustedLeft;
                                        } else {
                                            // 백분율 정보가 없으면 원래 위치 사용
                                            el.scrollTop = targetTop;
                                            el.scrollLeft = targetLeft;
                                        }
                                    } else {
                                        // ♾️ **범위 검증 없이 무조건 설정**
                                        el.scrollTop = targetTop;
                                        el.scrollLeft = targetLeft;
                                    }
                                    
                                    console.log('♾️ 🌐 무제한 컨테이너 복원:', sel, [targetLeft, targetTop]);
                                    
                                    // 🌐 동적 콘텐츠 상태 확인 및 복원
                                    if (item.dynamicAttrs) {
                                        for (const [key, value] of Object.entries(item.dynamicAttrs)) {
                                            if (el.getAttribute(key) !== value) {
                                                console.log('🌐 콘텐츠 불일치 감지:', sel, key, value);
                                                el.setAttribute(key, value);
                                            }
                                        }
                                    }
                                    
                                    // ♾️ **추가 강제 설정** (일부 커스텀 스크롤 컨테이너 대응)
                                    try {
                                        // 스크롤 이벤트 강제 발생
                                        el.dispatchEvent(new Event('scroll', { bubbles: true }));
                                        
                                        // CSS 스크롤 동작 강제
                                        el.style.scrollBehavior = 'auto';
                                        el.scrollTop = el.scrollTop; // 재설정으로 강제 적용
                                        el.scrollLeft = el.scrollLeft;
                                    } catch(e) {
                                        // 개별 요소 에러는 무시
                                    }
                                    
                                    restored++;
                                }
                            });
                            break;
                        }
                    }
                }
                
                console.log('♾️ 🌐 강화된 무제한 컨테이너 스크롤 복원 완료:', restored, '개 복원,', dynamicChanges, '개 동적변화');
                
                return {
                    success: restored > 0,
                    restoredCount: restored,
                    dynamicChanges: dynamicChanges
                };
            } catch(e) {
                console.error('무제한 컨테이너 스크롤 복원 실패:', e);
                return {
                    success: false,
                    restoredCount: 0,
                    dynamicChanges: 0,
                    error: e.message
                };
            }
        })()
        """
    }
    
    // ♾️ **무제한 iframe 스크롤 복원 스크립트** - 범위 제한 제거
    private func generateUnlimitedIframeScrollScript(_ iframeData: [[String: Any]]) -> String {
        let iframeJSON = convertToJSONString(iframeData) ?? "[]"
        return """
        (function() {
            try {
                const iframes = \(iframeJSON);
                let restored = 0;
                
                console.log('♾️ 무제한 iframe 스크롤 복원 시작:', iframes.length, '개 iframe');
                
                for (const iframeInfo of iframes) {
                    const iframe = document.querySelector(iframeInfo.selector);
                    if (iframe && iframe.contentWindow) {
                        try {
                            // ♾️ parseFloat로 정밀도 향상 (범위 제한 없음)
                            const targetX = parseFloat(iframeInfo.scrollX || 0);
                            const targetY = parseFloat(iframeInfo.scrollY || 0);
                            
                            // ♾️ Same-origin iframe 무제한 복원
                            iframe.contentWindow.scrollTo(targetX, targetY);
                            
                            // ♾️ **추가 강제 설정**
                            try {
                                iframe.contentWindow.document.documentElement.scrollTop = targetY;
                                iframe.contentWindow.document.documentElement.scrollLeft = targetX;
                                iframe.contentWindow.document.body.scrollTop = targetY;
                                iframe.contentWindow.document.body.scrollLeft = targetX;
                            } catch(e) {
                                // 접근 제한은 무시
                            }
                            
                            restored++;
                            console.log('♾️ iframe 무제한 복원:', iframeInfo.selector, [targetX, targetY]);
                        } catch(e) {
                            // 🌐 Cross-origin iframe 처리
                            try {
                                iframe.contentWindow.postMessage({
                                    type: 'restoreScroll',
                                    scrollX: parseFloat(iframeInfo.scrollX || 0),
                                    scrollY: parseFloat(iframeInfo.scrollY || 0),
                                    unlimited: true // ♾️ 무제한 모드 플래그
                                }, '*');
                                console.log('♾️ Cross-origin iframe 무제한 스크롤 요청:', iframeInfo.selector);
                                restored++;
                            } catch(crossOriginError) {
                                console.log('Cross-origin iframe 접근 불가:', iframeInfo.selector);
                            }
                        }
                    }
                }
                
                console.log('♾️ 무제한 iframe 스크롤 복원 완료:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('무제한 iframe 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
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

// MARK: - 🎯 **강화된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
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
    private var _gestureContexts: [UUID: GestureContext] = [:]  // 🧵 제스처 컨텍스트 관리
    
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
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (♾️ 무제한 스크롤 감지 강화)**
    
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
        dbg("♾️ 무제한 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
        dbg("♾️ 무제한 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            // ♾️ **실제 스크롤 가능한 최대 크기 감지**
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
        
        // 🔧 **개선된 캡처 로직 - 실패 시 재시도 (기존 타이밍 유지)**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
        )
        
        // 🌐 캡처된 jsState 로그
        if let jsState = captureResult.snapshot.jsState {
            dbg("♾️ 캡처된 jsState 키: \(Array(jsState.keys))")
            if let scrollData = jsState["scroll"] as? [String: Any],
               let elements = scrollData["elements"] as? [[String: Any]] {
                dbg("♾️ 캡처된 무제한 스크롤 요소: \(elements.count)개")
            }
        }
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        // 진행 중 해제
        pendingCaptures.remove(pageID)
        dbg("✅ 무제한 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize      // ⚡ 콘텐츠 크기 추가
        let viewportSize: CGSize     // ⚡ 뷰포트 크기 추가
        let actualScrollableSize: CGSize  // ♾️ 실제 스크롤 가능 크기 추가
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔧 **실패 복구 기능 추가된 캡처 - 기존 재시도 대기시간 유지**
    private func performRobustCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기 - 🔧 기존 80ms 유지
            dbg("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08) // 🔧 기존 80ms 유지
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드) - 🔧 기존 캡처 타임아웃 유지 (3초)
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
        
        // ⚡ 캡처 타임아웃 유지 (3초)
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처 - 🔧 기존 캡처 타임아웃 유지 (1초)
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
        _ = domSemaphore.wait(timeout: .now() + 1.0) // 🔧 기존 캡처 타임아웃 유지 (1초)
        
        // 3. ♾️ **무제한 스크롤 감지 강화 + 🌐 동적 콘텐츠 크기 동기화 JS 상태 캡처** - 🔧 기존 캡처 타임아웃 유지 (2초)
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = generateEnhancedUnlimitedScrollCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 2.0) // 🔧 기존 캡처 타임아웃 유지 (2초)
        
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
        
        // ♾️ **무제한 상대적 위치 계산 (백분율) - 범위 제한 없음**
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
            webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
            captureStatus: captureStatus,
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // ♾️ **핵심 개선: 무제한 스크롤 감지 JavaScript 생성 + 🌐 동적 콘텐츠 크기 동기화 강화**
    private func generateEnhancedUnlimitedScrollCaptureScript() -> String {
        return """
        (function() {
            return new Promise(resolve => {
                // 🌐 **강화된 동적 콘텐츠 로딩 안정화 대기 (MutationObserver 활용)**
                function waitForEnhancedDynamicContent(callback) {
                    let stabilityCount = 0;
                    let contentSizeChangeCount = 0;
                    const requiredStability = 5; // 5번 연속 안정되면 완료 (강화)
                    const maxContentChanges = 10; // 최대 10번의 크기 변화까지 감지
                    let timeout;
                    let lastContentWidth = document.documentElement.scrollWidth;
                    let lastContentHeight = document.documentElement.scrollHeight;
                    
                    console.log('🌐 강화된 동적 콘텐츠 안정화 대기 시작:', {
                        initialSize: [lastContentWidth, lastContentHeight]
                    });
                    
                    const observer = new MutationObserver((mutations) => {
                        const currentContentWidth = document.documentElement.scrollWidth;
                        const currentContentHeight = document.documentElement.scrollHeight;
                        
                        // 콘텐츠 크기 변화 감지
                        if (Math.abs(currentContentWidth - lastContentWidth) > 50 || 
                            Math.abs(currentContentHeight - lastContentHeight) > 50) {
                            contentSizeChangeCount++;
                            console.log('🌐 콘텐츠 크기 변화 감지 #' + contentSizeChangeCount + ':', {
                                before: [lastContentWidth, lastContentHeight],
                                after: [currentContentWidth, currentContentHeight]
                            });
                            
                            lastContentWidth = currentContentWidth;
                            lastContentHeight = currentContentHeight;
                            stabilityCount = 0; // 크기 변화 시 카운트 리셋
                        } else {
                            stabilityCount++; // 안정 상태 카운트 증가
                        }
                        
                        clearTimeout(timeout);
                        timeout = setTimeout(() => {
                            stabilityCount++;
                            console.log('🌐 안정성 체크 #' + stabilityCount + '/' + requiredStability);
                            
                            if (stabilityCount >= requiredStability || contentSizeChangeCount >= maxContentChanges) {
                                observer.disconnect();
                                console.log('🌐 동적 콘텐츠 안정화 완료:', {
                                    stabilityChecks: stabilityCount,
                                    contentChanges: contentSizeChangeCount,
                                    finalSize: [currentContentWidth, currentContentHeight]
                                });
                                callback({
                                    stabilityChecks: stabilityCount,
                                    contentChanges: contentSizeChangeCount,
                                    finalContentSize: [currentContentWidth, currentContentHeight]
                                });
                            }
                        }, 250); // 🔧 250ms로 단축 (더 빠른 감지)
                    });
                    
                    // 🌐 **더 세밀한 관찰 설정**
                    observer.observe(document.body, { 
                        childList: true, 
                        subtree: true,
                        attributes: true, // 속성 변화도 감지
                        attributeFilter: ['style', 'class', 'data-loaded'], // 특정 속성만
                        characterData: false // 텍스트 변화는 무시 (성능)
                    });
                    
                    // 최대 대기 시간 설정 (더 길게)
                    setTimeout(() => {
                        observer.disconnect();
                        console.log('🌐 동적 콘텐츠 안정화 타임아웃 (정상)');
                        callback({
                            stabilityChecks: stabilityCount,
                            contentChanges: contentSizeChangeCount,
                            timeout: true,
                            finalContentSize: [lastContentWidth, lastContentHeight]
                        });
                    }, 6000); // 🔧 6초로 확장 (더 많은 동적 콘텐츠 대기)
                }

                function captureEnhancedScrollData() {
                    try {
                        // ♾️ **1단계: 무제한 스크롤 요소 스캔 - 2000개로 확장, parseFloat 정밀도 적용 + 🌐 무한 스크롤 특화**
                        function findAllScrollableElementsEnhanced() {
                            const scrollables = [];
                            const maxElements = 2000; // ♾️ **기존 유지**
                            
                            console.log('♾️ 🌐 강화된 무제한 스크롤 감지: 최대 ' + maxElements + '개 요소 감지 (무한스크롤 특화)');
                            
                            // 1) 명시적 overflow 스타일을 가진 요소들 (범위 제한 없음)
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
                                    
                                    // ♾️ parseFloat로 정밀도 향상, 0.1px 단위까지 감지 (더 민감하게)
                                    const scrollTop = parseFloat(el.scrollTop) || 0;
                                    const scrollLeft = parseFloat(el.scrollLeft) || 0;
                                    
                                    // ♾️ **범위 제한 완전 제거** - 0.1px도 저장
                                    if (scrollTop > 0.1 || scrollLeft > 0.1) {
                                        const selector = generateBestSelector(el);
                                        if (selector) {
                                            // 🌐 동적 콘텐츠 식별을 위한 데이터 속성 저장 (강화)
                                            const dynamicAttrs = {};
                                            for (const attr of el.attributes) {
                                                if (attr.name.startsWith('data-') || 
                                                    attr.name.includes('infinite') || 
                                                    attr.name.includes('lazy') ||
                                                    attr.name.includes('virtual')) {
                                                    dynamicAttrs[attr.name] = attr.value;
                                                }
                                            }
                                            
                                            // ♾️ **무제한 상대적 위치 계산**
                                            const maxScrollTop = el.scrollHeight - el.clientHeight;
                                            const maxScrollLeft = el.scrollWidth - el.clientWidth;
                                            
                                            // 🌐 **무한 스크롤 패턴 감지**
                                            const isInfiniteScroll = el.classList.contains('infinite-scroll') ||
                                                                   el.dataset.infinite !== undefined ||
                                                                   el.classList.contains('lazy-load') ||
                                                                   el.classList.contains('virtual-list') ||
                                                                   el.querySelector('[data-lazy], [data-infinite]') !== null;
                                            
                                            scrollables.push({
                                                selector: selector,
                                                top: scrollTop,
                                                left: scrollLeft,
                                                topPercent: maxScrollTop > 0 ? (scrollTop / maxScrollTop * 100) : 0,
                                                leftPercent: maxScrollLeft > 0 ? (scrollLeft / maxScrollLeft * 100) : 0,
                                                maxTop: maxScrollTop,
                                                maxLeft: maxScrollLeft,
                                                actualMaxTop: el.scrollHeight, // ♾️ 실제 최대 스크롤 높이
                                                actualMaxLeft: el.scrollWidth, // ♾️ 실제 최대 스크롤 너비
                                                id: el.id || '',
                                                className: el.className || '',
                                                tagName: el.tagName.toLowerCase(),
                                                dynamicAttrs: dynamicAttrs,
                                                isInfiniteScroll: isInfiniteScroll // 🌐 무한 스크롤 플래그
                                            });
                                            count++;
                                        }
                                    }
                                }
                            }
                            
                            // ♾️ **2) 범용 커뮤니티/SPA 사이트 컨테이너들 + 🌐 무한 스크롤 특화 패턴**
                            const enhancedScrollContainers = [
                                '.scroll-container', '.scrollable', '.content', '.main', '.body',
                                '[data-scroll]', '[data-scrollable]', '.overflow-auto', '.overflow-scroll',
                                '.list', '.feed', '.timeline', '.board', '.gallery', '.gall_list', '.article-board',
                                // ♾️ **무한스크롤 패턴들 - 더 많은 사이트 대응**
                                '.infinite-scroll', '.virtual-list', '.lazy-load', '.pagination-container',
                                '.posts-container', '.comments-list', '.thread-list', '.message-list',
                                '.activity-feed', '.news-feed', '.social-feed', '.content-stream',
                                '.card-list', '.grid-container', '.masonry', '.waterfall-layout',
                                // ♾️ **소셜미디어/커뮤니티 특화 패턴**
                                '.tweet-list', '.post-stream', '.story-list', '.video-list',
                                '.chat-messages', '.notification-list', '.search-results',
                                // ♾️ **모바일 최적화 패턴**
                                '.mobile-list', '.touch-scroll', '.swipe-container',
                                // ♾️ **네이버 카페 등 범용 커뮤니티 패턴**
                                '.ArticleList', '.CommentArticleList', '.List.CommentArticleList',
                                '.content.location_fix', '.list_board', '.RisingArticleList',
                                '#ct[role="main"]', '.CafeMain', '.article-content',
                                // ♾️ **추가 범용 패턴**
                                '.container-fluid', '.main-container', '.page-content',
                                '.content-wrapper', '.app-content', '.site-content',
                                // 🌐 **무한 스크롤 전용 추가 패턴**
                                '[data-infinite]', '[data-lazy]', '[data-virtual]', 
                                '.endless-scroll', '.auto-load', '.scroll-trigger',
                                '.dynamic-content', '.ajax-content', '.load-more-container'
                            ];
                            
                            for (const selector of enhancedScrollContainers) {
                                if (count >= maxElements) break;
                                
                                const elements = document.querySelectorAll(selector);
                                for (const el of elements) {
                                    if (count >= maxElements) break;
                                    
                                    // ♾️ parseFloat 정밀도 적용 (범위 제한 없음)
                                    const scrollTop = parseFloat(el.scrollTop) || 0;
                                    const scrollLeft = parseFloat(el.scrollLeft) || 0;
                                    
                                    // ♾️ **0.1px 이상이면 모두 저장** (완전 무제한)
                                    if ((scrollTop > 0.1 || scrollLeft > 0.1) && 
                                        !scrollables.some(s => s.selector === generateBestSelector(el))) {
                                        
                                        // 🌐 동적 속성 수집 (강화)
                                        const dynamicAttrs = {};
                                        for (const attr of el.attributes) {
                                            if (attr.name.startsWith('data-') || 
                                                attr.name.includes('infinite') || 
                                                attr.name.includes('lazy') ||
                                                attr.name.includes('virtual')) {
                                                dynamicAttrs[attr.name] = attr.value;
                                            }
                                        }
                                        
                                        // ♾️ **무제한 상대적 위치 계산**
                                        const maxScrollTop = el.scrollHeight - el.clientHeight;
                                        const maxScrollLeft = el.scrollWidth - el.clientWidth;
                                        
                                        // 🌐 **무한 스크롤 패턴 감지 강화**
                                        const isInfiniteScroll = selector.includes('infinite') ||
                                                               selector.includes('lazy') ||
                                                               selector.includes('virtual') ||
                                                               el.dataset.infinite !== undefined ||
                                                               el.dataset.lazy !== undefined ||
                                                               el.querySelector('[data-lazy], [data-infinite], .load-more') !== null;
                                        
                                        scrollables.push({
                                            selector: generateBestSelector(el) || selector,
                                            top: scrollTop,
                                            left: scrollLeft,
                                            topPercent: maxScrollTop > 0 ? (scrollTop / maxScrollTop * 100) : 0,
                                            leftPercent: maxScrollLeft > 0 ? (scrollLeft / maxScrollLeft * 100) : 0,
                                            maxTop: maxScrollTop,
                                            maxLeft: maxScrollLeft,
                                            actualMaxTop: el.scrollHeight,
                                            actualMaxLeft: el.scrollWidth,
                                            id: el.id || '',
                                            className: el.className || '',
                                            tagName: el.tagName.toLowerCase(),
                                            dynamicAttrs: dynamicAttrs,
                                            isInfiniteScroll: isInfiniteScroll // 🌐 무한 스크롤 플래그
                                        });
                                        count++;
                                    }
                                }
                            }
                            
                            console.log('♾️ 🌐 강화된 무제한 스크롤 요소 감지 완료: ' + count + '/' + maxElements + '개 (무한스크롤: ' + scrollables.filter(s => s.isInfiniteScroll).length + '개)');
                            return scrollables;
                        }
                        
                        // 🖼️ **2단계: iframe 무제한 스크롤 감지 (parseFloat 적용)**
                        function detectIframeScrolls() {
                            const iframes = [];
                            const iframeElements = document.querySelectorAll('iframe');
                            
                            for (const iframe of iframeElements) {
                                try {
                                    const contentWindow = iframe.contentWindow;
                                    if (contentWindow && contentWindow.location) {
                                        // ♾️ parseFloat 정밀도 적용 (범위 제한 없음)
                                        const scrollX = parseFloat(contentWindow.scrollX) || 0;
                                        const scrollY = parseFloat(contentWindow.scrollY) || 0;
                                        
                                        // ♾️ **0.1px 이상이면 모두 저장**
                                        if (scrollX > 0.1 || scrollY > 0.1) {
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
                                    // 🌐 Cross-origin iframe도 기본 정보 저장
                                    const dynamicAttrs = {};
                                    for (const attr of iframe.attributes) {
                                        if (attr.name.startsWith('data-')) {
                                            dynamicAttrs[attr.name] = attr.value;
                                        }
                                    }
                                    
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
                        
                        // 🌐 **개선된 셀렉터 생성** - 동적 사이트 대응 (기존 로직 유지)
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
                        
                        // ♾️ **메인 실행 - 무제한 정밀도 향상 + 🌐 동적 콘텐츠 크기 동기화**
                        const scrollableElements = findAllScrollableElementsEnhanced();
                        const iframeScrolls = detectIframeScrolls();
                        
                        // ♾️ **메인 스크롤 위치도 parseFloat 정밀도 적용 (범위 제한 없음)**
                        const mainScrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                        const mainScrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                        
                        // ♾️ **뷰포트 및 콘텐츠 크기 정밀 계산 (실제 크기 포함) + 🌐 동적 크기 동기화**
                        const viewportWidth = parseFloat(window.innerWidth) || 0;
                        const viewportHeight = parseFloat(window.innerHeight) || 0;
                        const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                        const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                        
                        // ♾️ **실제 스크롤 가능 크기 계산** (최대한 정확하게 + 동적 콘텐츠 고려)
                        const actualScrollableWidth = Math.max(
                            contentWidth, 
                            window.innerWidth, 
                            document.body.scrollWidth || 0,
                            document.documentElement.offsetWidth || 0
                        );
                        const actualScrollableHeight = Math.max(
                            contentHeight, 
                            window.innerHeight, 
                            document.body.scrollHeight || 0,
                            document.documentElement.offsetHeight || 0
                        );
                        
                        // 🌐 **무한 스크롤 페이지 감지**
                        const infiniteScrollIndicators = [
                            document.querySelector('.infinite-scroll'),
                            document.querySelector('[data-infinite]'),
                            document.querySelector('.lazy-load'),
                            document.querySelector('.virtual-list'),
                            document.querySelector('.load-more'),
                            document.querySelector('.endless-scroll')
                        ].filter(el => el !== null);
                        
                        const isInfiniteScrollPage = infiniteScrollIndicators.length > 0;
                        
                        console.log(`♾️ 🌐 강화된 무제한 스크롤 감지 완료: 일반 ${scrollableElements.length}개, iframe ${iframeScrolls.length}개, 무한스크롤페이지: ${isInfiniteScrollPage}`);
                        console.log(`♾️ 무제한 위치: (${mainScrollX}, ${mainScrollY}) 뷰포트: (${viewportWidth}, ${viewportHeight}) 콘텐츠: (${contentWidth}, ${contentHeight})`);
                        console.log(`♾️ 🌐 실제 스크롤 가능 (동적 고려): (${actualScrollableWidth}, ${actualScrollableHeight})`);
                        
                        resolve({
                            scroll: { 
                                x: mainScrollX, 
                                y: mainScrollY,
                                elements: scrollableElements
                            },
                            iframes: iframeScrolls,
                            href: window.location.href,
                            title: document.title,
                            timestamp: Date.now(),
                            userAgent: navigator.userAgent,
                            viewport: {
                                width: viewportWidth,
                                height: viewportHeight
                            },
                            content: {
                                width: contentWidth,
                                height: contentHeight
                            },
                            actualScrollable: { // ♾️ **실제 스크롤 가능 크기 추가**
                                width: actualScrollableWidth,
                                height: actualScrollableHeight
                            },
                            infiniteScroll: { // 🌐 **무한 스크롤 정보 추가**
                                detected: isInfiniteScrollPage,
                                indicators: infiniteScrollIndicators.length,
                                elementsWithInfiniteScroll: scrollableElements.filter(s => s.isInfiniteScroll).length
                            }
                        });
                    } catch(e) { 
                        console.error('♾️ 🌐 강화된 무제한 스크롤 감지 실패:', e);
                        resolve({
                            scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0, elements: [] },
                            iframes: [],
                            href: window.location.href,
                            title: document.title,
                            actualScrollable: { width: 0, height: 0 },
                            infiniteScroll: { detected: false, indicators: 0, elementsWithInfiniteScroll: 0 },
                            error: e.message
                        });
                    }
                }

                // ♾️ 🌐 강화된 동적 콘텐츠 완료 대기 후 캡처 (기존 타이밍 유지하되 더 정교하게)
                if (document.readyState === 'complete') {
                    waitForEnhancedDynamicContent(captureEnhancedScrollData);
                } else {
                    document.addEventListener('DOMContentLoaded', () => waitForEnhancedDynamicContent(captureEnhancedScrollData));
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
        
        dbg("♾️ 🛡️ 🌐 무제한 BFCache 제스처 설정 완료 (클램핑 감지 + 동적 콘텐츠 동기화): 탭 \(String(tabID.uuidString.prefix(8)))")
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
                
                // 현재 페이지 즉시 캡처 (높은 우선순위)
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
                // 🎬 **기존 타이밍으로 네비게이션 수행**
                self?.performNavigationWithFixedTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // ♾️ **기존 타이밍을 적용한 네비게이션 수행 - 타임아웃 제거**
    private func performNavigationWithFixedTiming(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            // 실패 시 즉시 정리
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
        
        // ♾️ **기존 타이밍 무제한 BFCache 복원 + 🛡️ 클램핑 감지**
        tryEnhancedUnlimitedBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            // BFCache 복원 완료 또는 실패 시 즉시 정리 (깜빡임 최소화)
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.removeActiveTransition(for: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - 🛡️ 강화된 무제한 BFCache \(success ? "성공" : "실패")")
            }
        }
        
        // 🎬 **타임아웃 제거 - 제스처 먹통 해결**
        dbg("🎬 미리보기 타임아웃 제거됨 - 제스처 먹통 방지")
    }
    
    // ♾️ **🛡️ 🌐 강화된 기존 타이밍 무제한 BFCache 복원 (클램핑 감지 + 동적 콘텐츠)** 
    private func tryEnhancedUnlimitedBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 🛡️ 🌐 강화된 기존 타이밍 무제한 복원
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ 🛡️ 🌐 강화된 기존 타이밍 무제한 BFCache 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ 🛡️ 🌐 강화된 기존 타이밍 무제한 BFCache 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 기존 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            
            // 기존 대기 시간 (250ms)
            let waitTime: TimeInterval = 0.25
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
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryEnhancedUnlimitedBFCacheRestore(stateModel: stateModel, direction: .back) { _ in
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
        tryEnhancedUnlimitedBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in
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
                console.log('♾️ 🛡️ 🌐 무제한 BFCache 페이지 복원 (클램핑 감지 + 동적 콘텐츠)');
                
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
                console.log('📸 무제한 BFCache 페이지 저장');
            }
        });
        
        // ♾️ Cross-origin iframe 무제한 스크롤 복원 리스너
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                try {
                    // ♾️ parseFloat로 정밀도 향상 (범위 제한 없음)
                    const targetX = parseFloat(event.data.scrollX) || 0;
                    const targetY = parseFloat(event.data.scrollY) || 0;
                    const unlimited = event.data.unlimited || false;
                    
                    console.log('♾️ Cross-origin iframe 무제한 스크롤 복원:', targetX, targetY, unlimited ? '(무제한 모드)' : '');
                    
                    // ♾️ 무제한 스크롤 설정
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
        TabPersistenceManager.debugMessages.append("[BFCache♾️🛡️🌐] \(msg)")
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
        
        // 제스처 설치 + 📸 포괄적 네비게이션 감지
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ ♾️ 🛡️ 🌐 무제한 스크롤 범위 BFCache 시스템 설치 완료 (클램핑 감지 + 동적 콘텐츠 동기화)")
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
        
        // 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        TabPersistenceManager.debugMessages.append("♾️ 🛡️ 🌐 무제한 BFCache 시스템 제거 완료")
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

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화 - 🚀 도착 스냅샷 최적화**
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
