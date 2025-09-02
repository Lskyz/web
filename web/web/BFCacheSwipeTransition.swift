//
//  BFCacheSwipeTransition.swift
//  🎯 **강화된 BFCache 전환 시스템 - 스크롤 위치 검증 특화**
//  ✅ 직렬화 큐로 레이스 컨디션 완전 제거
//  🔄 원자적 연산으로 데이터 일관성 보장
//  📸 실패 복구 메커니즘 추가
//  ♾️ 무제한 영구 캐싱 (탭별 관리)
//  💾 스마트 메모리 관리 
//  🔧 **StateModel과 완벽 동기화**
//  🔧 **스냅샷 미스 수정 - 자동 캐시 강화**
//  🎬 **미리보기 컨테이너 0.8초 고정 타이밍** - 깜빡임 방지
//  ⚡ **균형 잡힌 전환 속도 최적화**
//  🛡️ **빠른 연속 제스처 먹통 방지** - 전환 중 차단 + 강제 정리
//  🚫 **폼데이터/눌린상태 저장 제거** - 부작용 해결
//  🔍 **범용 스크롤 감지 강화** - iframe, 커스텀 컨테이너 지원
//  🔄 **다단계 복원 시스템** - 0.8초 고정 대기
//  📍 **범용 스크롤 위치 검증** - 동적 사이트 완벽 대응
//  ⏳ **콘텐츠 안정성 감지** - DOM 변화 모니터링
//  🎯 **다중 앵커 포인트** - 절대+상대 위치 조합
//  🔄 **점진적 검증 복원** - 단계별 위치 확인
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

// MARK: - 📍 스크롤 앵커 포인트 (범용 위치 검증)
struct ScrollAnchor: Codable {
    let absolutePosition: CGPoint     // 절대 스크롤 위치
    let relativePosition: Double      // 전체 콘텐츠 대비 상대 위치 (0.0 ~ 1.0)
    let visibleElementHashes: [String] // 현재 보이는 요소들의 해시
    let contentHeight: Double         // 캡처 시점 콘텐츠 높이
    let viewportHeight: Double        // 뷰포트 높이
    let timestamp: Date              // 캡처 시각
    
    // 검증용 추가 정보
    let topElementInfo: ElementInfo?  // 최상단 보이는 요소 정보
    let centerElementInfo: ElementInfo? // 중앙 보이는 요소 정보
    let domStabilityScore: Double     // DOM 안정성 점수 (0.0 ~ 1.0)
}

struct ElementInfo: Codable {
    let tagName: String
    let textContent: String      // 처음 50자
    let className: String
    let id: String
    let offsetTop: Double       // 요소의 절대 위치
    let boundingTop: Double     // 뷰포트 기준 위치
}

// MARK: - 📸 강화된 BFCache 페이지 스냅샷 (스크롤 검증 특화)
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 📍 **핵심 개선: 스크롤 검증 정보**
    var scrollAnchor: ScrollAnchor?        // 다중 검증 앵커
    var verificationPassed: Bool = false   // 검증 통과 여부
    var captureAttempts: Int = 1          // 캡처 시도 횟수
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
        case verified       // 검증 완료된 고품질 캡처
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
        case scrollAnchor
        case verificationPassed
        case captureAttempts
    }
    
    // Custom encoding/decoding for [String: Any]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        
        // JSON decode for [String: Any]
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
        
        // 새 필드들 (옵셔널)
        scrollAnchor = try container.decodeIfPresent(ScrollAnchor.self, forKey: .scrollAnchor)
        verificationPassed = try container.decodeIfPresent(Bool.self, forKey: .verificationPassed) ?? false
        captureAttempts = try container.decodeIfPresent(Int.self, forKey: .captureAttempts) ?? 1
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        
        // JSON encode for [String: Any]
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(scrollAnchor, forKey: .scrollAnchor)
        try container.encode(verificationPassed, forKey: .verificationPassed)
        try container.encode(captureAttempts, forKey: .captureAttempts)
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1, scrollAnchor: ScrollAnchor? = nil) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.scrollAnchor = scrollAnchor
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // ⚡ **검증된 점진적 복원 메서드**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 캡처 상태에 따른 복원 전략
        switch captureStatus {
        case .failed:
            completion(false)
            return
            
        case .visualOnly:
            // 스크롤만 즉시 복원
            DispatchQueue.main.async {
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                TabPersistenceManager.debugMessages.append("BFCache 스크롤만 즉시 복원")
                completion(true)
            }
            return
            
        case .verified:
            // 검증된 캐시 - 고품질 복원
            TabPersistenceManager.debugMessages.append("BFCache 검증된 고품질 복원 시작")
            performVerifiedRestore(to: webView, completion: completion)
            return
            
        case .partial, .complete:
            break
        }
        
        TabPersistenceManager.debugMessages.append("BFCache 점진적 검증 복원 시작")
        
        // 점진적 검증 복원 실행
        DispatchQueue.main.async {
            self.performProgressiveVerifiedRestore(to: webView, completion: completion)
        }
    }
    
    // 🔄 **핵심: 점진적 검증 복원 시스템**
    private func performProgressiveVerifiedRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        // **1단계: 즉시 스크롤 + 초기 검증 (0ms)**
        restoreSteps.append((1, { stepCompletion in
            let targetPos = self.scrollPosition
            TabPersistenceManager.debugMessages.append("🔄 1단계: 즉시 스크롤 + 초기 검증")
            
            // 네이티브 스크롤뷰 즉시 설정
            webView.scrollView.setContentOffset(targetPos, animated: false)
            
            // JavaScript 메인 스크롤 + 즉시 검증
            let scrollAndVerifyJS = """
            (function() {
                try {
                    // 즉시 스크롤
                    window.scrollTo(\(targetPos.x), \(targetPos.y));
                    document.documentElement.scrollTop = \(targetPos.y);
                    document.body.scrollTop = \(targetPos.y);
                    
                    // 즉시 위치 검증
                    const actualY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
                    const targetY = \(targetPos.y);
                    const tolerance = 50; // 50px 오차 허용
                    
                    const isAccurate = Math.abs(actualY - targetY) <= tolerance;
                    
                    return {
                        success: true,
                        accurate: isAccurate,
                        actualY: actualY,
                        targetY: targetY,
                        diff: Math.abs(actualY - targetY)
                    };
                } catch(e) { 
                    return { success: false, error: e.toString() }; 
                }
            })()
            """
            
            webView.evaluateJavaScript(scrollAndVerifyJS) { result, _ in
                if let data = result as? [String: Any],
                   let success = data["success"] as? Bool,
                   success {
                    let accurate = data["accurate"] as? Bool ?? false
                    let diff = data["diff"] as? Double ?? 999
                    TabPersistenceManager.debugMessages.append("🔄 1단계 완료: 정확도=\(accurate ? "OK" : "NG") 오차=\(Int(diff))px")
                    stepCompletion(accurate)
                } else {
                    TabPersistenceManager.debugMessages.append("🔄 1단계 실패")
                    stepCompletion(false)
                }
            }
        }))
        
        // **2단계: 콘텐츠 안정성 대기 + 재검증 (0.3초 후)**
        restoreSteps.append((2, { stepCompletion in
            TabPersistenceManager.debugMessages.append("🔄 2단계: 콘텐츠 안정성 대기 + 재검증")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let stabilityCheckJS = """
                (function() {
                    try {
                        // 콘텐츠 안정성 확인
                        const currentHeight = Math.max(
                            document.body.scrollHeight,
                            document.documentElement.scrollHeight,
                            document.body.offsetHeight,
                            document.documentElement.offsetHeight
                        );
                        
                        const isLoading = document.readyState !== 'complete';
                        const hasActiveRequests = typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype.readyState;
                        
                        // 재검증
                        const actualY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
                        const targetY = \(self.scrollPosition.y);
                        const tolerance = 30; // 더 엄격한 검증
                        
                        const isStable = !isLoading && currentHeight > 0;
                        const isAccurate = Math.abs(actualY - targetY) <= tolerance;
                        
                        // 부정확하면 재시도
                        if (!isAccurate && isStable) {
                            window.scrollTo(\(self.scrollPosition.x), targetY);
                            // 재검증
                            setTimeout(() => {
                                const retryY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
                                const retryAccurate = Math.abs(retryY - targetY) <= tolerance;
                                return retryAccurate;
                            }, 100);
                        }
                        
                        return {
                            stable: isStable,
                            accurate: isAccurate,
                            contentHeight: currentHeight,
                            actualY: actualY,
                            targetY: targetY,
                            loading: isLoading
                        };
                    } catch(e) {
                        return { stable: false, accurate: false, error: e.toString() };
                    }
                })()
                """
                
                webView.evaluateJavaScript(stabilityCheckJS) { result, _ in
                    if let data = result as? [String: Any] {
                        let stable = data["stable"] as? Bool ?? false
                        let accurate = data["accurate"] as? Bool ?? false
                        let loading = data["loading"] as? Bool ?? true
                        
                        TabPersistenceManager.debugMessages.append("🔄 2단계 완료: 안정성=\(stable ? "OK" : "NG") 정확도=\(accurate ? "OK" : "NG") 로딩=\(loading ? "YES" : "NO")")
                        stepCompletion(stable && accurate)
                    } else {
                        TabPersistenceManager.debugMessages.append("🔄 2단계 실패")
                        stepCompletion(false)
                    }
                }
            }
        }))
        
        // **3단계: 컨테이너 스크롤 복원 (0.5초 후)**
        if let jsState = self.jsState,
           let scrollData = jsState["scroll"] as? [String: Any],
           let elements = scrollData["elements"] as? [[String: Any]], !elements.isEmpty {
            
            restoreSteps.append((3, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🔄 3단계: 컨테이너 스크롤 복원")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let containerScrollJS = self.generateVerifiedContainerScrollScript(elements)
                    webView.evaluateJavaScript(containerScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **4단계: 최종 검증 및 앵커 기반 보정 (0.7초 후)**
        if let anchor = self.scrollAnchor {
            restoreSteps.append((4, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🔄 4단계: 최종 앵커 기반 검증")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    let anchorVerifyJS = self.generateAnchorVerificationScript(anchor)
                    webView.evaluateJavaScript(anchorVerifyJS) { result, _ in
                        if let data = result as? [String: Any],
                           let verified = data["verified"] as? Bool,
                           verified {
                            TabPersistenceManager.debugMessages.append("🔄 4단계 완료: 앵커 검증 성공")
                            stepCompletion(true)
                        } else {
                            // 앵커 검증 실패시 폴백 복원
                            let fallbackY = data?["fallbackY"] as? Double ?? self.scrollPosition.y
                            TabPersistenceManager.debugMessages.append("🔄 4단계: 앵커 실패, 폴백 복원 (Y=\(Int(fallbackY)))")
                            
                            let fallbackJS = "window.scrollTo(\(self.scrollPosition.x), \(fallbackY)); true;"
                            webView.evaluateJavaScript(fallbackJS) { _, _ in
                                stepCompletion(false) // 폴백이므로 실패로 간주
                            }
                        }
                    }
                }
            }))
        }
        
        // 단계별 실행
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                stepInfo.action { success in
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > totalSteps / 2
                
                TabPersistenceManager.debugMessages.append("🔄 점진적 검증 복원 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                completion(overallSuccess)
            }
        }
        
        executeNextStep()
    }
    
    // 🎯 **검증된 고품질 복원**
    private func performVerifiedRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let anchor = scrollAnchor else {
            // 앵커 없으면 일반 복원
            performProgressiveVerifiedRestore(to: webView, completion: completion)
            return
        }
        
        // 앵커 기반 직접 복원
        let anchorRestoreJS = generateAnchorBasedRestoreScript(anchor)
        
        webView.evaluateJavaScript(anchorRestoreJS) { result, error in
            if let data = result as? [String: Any],
               let success = data["success"] as? Bool,
               success {
                
                let finalY = data["finalY"] as? Double ?? self.scrollPosition.y
                TabPersistenceManager.debugMessages.append("✅ 검증된 앵커 복원 성공: Y=\(Int(finalY))")
                completion(true)
            } else {
                TabPersistenceManager.debugMessages.append("❌ 검증된 앵커 복원 실패, 폴백")
                self.performProgressiveVerifiedRestore(to: webView, completion: completion)
            }
        }
    }
    
    // JavaScript 스크립트 생성 메서드들
    
    private func generateVerifiedContainerScrollScript(_ elements: [[String: Any]]) -> String {
        let elementsJSON = convertToJSONString(elements) ?? "[]"
        return """
        (function() {
            try {
                const elements = \(elementsJSON);
                let restored = 0;
                let verified = 0;
                
                for (const item of elements) {
                    if (!item.selector) continue;
                    
                    const selectors = [
                        item.selector,
                        item.selector.replace(/\\[\\d+\\]/g, ''),
                        item.className ? '.' + item.className : null,
                        item.id ? '#' + item.id : null
                    ].filter(s => s);
                    
                    for (const sel of selectors) {
                        try {
                            const elements = document.querySelectorAll(sel);
                            if (elements.length > 0) {
                                elements.forEach(el => {
                                    if (el && typeof el.scrollTop === 'number') {
                                        const oldTop = el.scrollTop;
                                        el.scrollTop = item.top || 0;
                                        el.scrollLeft = item.left || 0;
                                        restored++;
                                        
                                        // 검증: 실제로 설정되었는지 확인
                                        setTimeout(() => {
                                            const newTop = el.scrollTop;
                                            if (Math.abs(newTop - (item.top || 0)) <= 10) {
                                                verified++;
                                            }
                                        }, 50);
                                    }
                                });
                                break;
                            }
                        } catch(selectorError) {
                            continue;
                        }
                    }
                }
                
                console.log('컨테이너 스크롤 복원:', restored, '개, 검증 대기중');
                
                // 검증 완료 대기
                setTimeout(() => {
                    console.log('컨테이너 스크롤 검증:', verified, '/', restored);
                }, 100);
                
                return restored > 0;
            } catch(e) {
                console.error('컨테이너 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    private func generateAnchorVerificationScript(_ anchor: ScrollAnchor) -> String {
        return """
        (function() {
            try {
                const targetY = \(anchor.absolutePosition.y);
                const relativePos = \(anchor.relativePosition);
                const expectedHeight = \(anchor.contentHeight);
                
                // 현재 콘텐츠 상태 확인
                const currentHeight = Math.max(
                    document.body.scrollHeight,
                    document.documentElement.scrollHeight
                );
                
                const currentY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
                
                // 앵커 검증 1: 절대 위치
                const absoluteAccurate = Math.abs(currentY - targetY) <= 50;
                
                // 앵커 검증 2: 상대 위치 (콘텐츠 높이가 변경된 경우)
                let relativeY = targetY;
                if (Math.abs(currentHeight - expectedHeight) > 100) {
                    // 콘텐츠 높이 변경됨 - 상대 위치로 계산
                    relativeY = currentHeight * relativePos;
                    console.log('콘텐츠 높이 변경 감지:', expectedHeight, '->', currentHeight, '상대 위치 적용:', relativeY);
                }
                
                const relativeAccurate = Math.abs(currentY - relativeY) <= 50;
                
                // 최적 위치 결정
                let bestY = targetY;
                if (!absoluteAccurate && relativeAccurate) {
                    bestY = relativeY;
                } else if (!absoluteAccurate && !relativeAccurate) {
                    // 둘 다 부정확 - 상대 위치 선택 (더 안전)
                    bestY = relativeY;
                }
                
                // 앵커 검증 3: 보이는 요소 확인
                let elementMatched = false;
                try {
                    const topElementInfo = \(convertToJSONString(anchor.topElementInfo?.asDict ?? [:]) ?? "{}");
                    if (topElementInfo.tagName) {
                        const elements = document.getElementsByTagName(topElementInfo.tagName);
                        for (const el of elements) {
                            const rect = el.getBoundingClientRect();
                            if (Math.abs(rect.top - topElementInfo.boundingTop) <= 100) {
                                elementMatched = true;
                                break;
                            }
                        }
                    }
                } catch(e) {
                    console.warn('요소 매칭 실패:', e);
                }
                
                // 최종 검증 및 보정
                const verified = absoluteAccurate || relativeAccurate || elementMatched;
                
                if (!verified) {
                    // 검증 실패 - 최적 위치로 보정
                    window.scrollTo(\(anchor.absolutePosition.x), bestY);
                    console.log('앵커 검증 실패 - 보정 적용:', bestY);
                }
                
                return {
                    verified: verified,
                    absoluteAccurate: absoluteAccurate,
                    relativeAccurate: relativeAccurate,
                    elementMatched: elementMatched,
                    currentY: currentY,
                    targetY: targetY,
                    relativeY: relativeY,
                    bestY: bestY,
                    fallbackY: bestY,
                    heightChanged: Math.abs(currentHeight - expectedHeight) > 100
                };
            } catch(e) {
                console.error('앵커 검증 실패:', e);
                return { 
                    verified: false, 
                    error: e.toString(),
                    fallbackY: \(anchor.absolutePosition.y)
                };
            }
        })()
        """
    }
    
    private func generateAnchorBasedRestoreScript(_ anchor: ScrollAnchor) -> String {
        return """
        (function() {
            try {
                const targetY = \(anchor.absolutePosition.y);
                const relativePos = \(anchor.relativePosition);
                const expectedHeight = \(anchor.contentHeight);
                
                // 현재 콘텐츠 높이 확인
                const currentHeight = Math.max(
                    document.body.scrollHeight,
                    document.documentElement.scrollHeight
                );
                
                let finalY = targetY;
                
                // 콘텐츠 높이 변경 시 상대 위치 사용
                if (Math.abs(currentHeight - expectedHeight) > 50) {
                    finalY = Math.min(currentHeight * relativePos, currentHeight - window.innerHeight);
                    console.log('상대 위치 복원:', finalY, '(', relativePos * 100, '%)');
                } else {
                    console.log('절대 위치 복원:', finalY);
                }
                
                // 안전 범위 확인
                finalY = Math.max(0, Math.min(finalY, currentHeight - window.innerHeight + 100));
                
                // 복원 실행
                window.scrollTo(\(anchor.absolutePosition.x), finalY);
                document.documentElement.scrollTop = finalY;
                document.body.scrollTop = finalY;
                
                // 검증
                setTimeout(() => {
                    const actualY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
                    const accurate = Math.abs(actualY - finalY) <= 30;
                    console.log('앵커 복원 검증:', accurate ? '성공' : '실패', 'target:', finalY, 'actual:', actualY);
                }, 100);
                
                return {
                    success: true,
                    finalY: finalY,
                    method: Math.abs(currentHeight - expectedHeight) > 50 ? 'relative' : 'absolute'
                };
            } catch(e) {
                console.error('앵커 복원 실패:', e);
                return { success: false, error: e.toString() };
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

// ElementInfo 딕셔너리 변환 헬퍼
extension ElementInfo {
    var asDict: [String: Any] {
        return [
            "tagName": tagName,
            "textContent": textContent,
            "className": className,
            "id": id,
            "offsetTop": offsetTop,
            "boundingTop": boundingTop
        ]
    }
}

// MARK: - 🎯 **강화된 BFCache 전환 시스템 (스크롤 검증 특화)**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 **핵심 개선: 스크롤 검증 캡처 시스템**
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
        case verified   // 검증된 캡처 (최고 품질)
    }
    
    // MARK: - 🔍 **핵심 개선: 콘텐츠 안정성 감지**
    private func assessContentStability(webView: WKWebView, completion: @escaping (Bool, Double) -> Void) {
        let stabilityScript = """
        (function() {
            try {
                // 로딩 상태 확인
                const isLoading = document.readyState !== 'complete';
                const hasActiveXHR = typeof XMLHttpRequest !== 'undefined';
                
                // DOM 변화 감지를 위한 기준점 설정
                const contentHeight = Math.max(
                    document.body.scrollHeight,
                    document.documentElement.scrollHeight,
                    document.body.offsetHeight,
                    document.documentElement.offsetHeight
                );
                
                const visibleElements = document.querySelectorAll('*').length;
                const images = document.querySelectorAll('img');
                let loadingImages = 0;
                
                images.forEach(img => {
                    if (!img.complete) loadingImages++;
                });
                
                // 스크롤 위치 안정성
                const scrollY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
                
                // 안정성 점수 계산 (0.0 ~ 1.0)
                let stabilityScore = 1.0;
                
                if (isLoading) stabilityScore -= 0.3;
                if (loadingImages > 3) stabilityScore -= 0.2;
                if (contentHeight < 100) stabilityScore -= 0.2;
                if (visibleElements < 10) stabilityScore -= 0.1;
                
                stabilityScore = Math.max(0, Math.min(1, stabilityScore));
                
                const isStable = stabilityScore >= 0.7;
                
                return {
                    stable: isStable,
                    score: stabilityScore,
                    loading: isLoading,
                    contentHeight: contentHeight,
                    visibleElements: visibleElements,
                    loadingImages: loadingImages,
                    scrollY: scrollY
                };
            } catch(e) {
                return {
                    stable: false,
                    score: 0.0,
                    error: e.toString()
                };
            }
        })()
        """
        
        webView.evaluateJavaScript(stabilityScript) { result, error in
            if let data = result as? [String: Any],
               let stable = data["stable"] as? Bool,
               let score = data["score"] as? Double {
                completion(stable, score)
            } else {
                completion(false, 0.0)
            }
        }
    }
    
    // MARK: - 🔧 **핵심 개선: 검증된 캡처 작업**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
        var maxAttempts: Int {
            switch type {
            case .verified: return 3
            case .immediate: return 2
            case .background: return 1
            }
        }
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
            self?.performVerifiedCapture(task)
        }
    }
    
    private func performVerifiedCapture(_ task: CaptureTask) {
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
        
        dbg("🎯 검증된 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 콘텐츠 안정성 평가 후 캡처
        DispatchQueue.main.async { [weak self] in
            self?.assessContentStability(webView: webView) { isStable, score in
                let delay = isStable ? 0.1 : 0.5 // 불안정하면 더 대기
                
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.performActualVerifiedCapture(task, stabilityScore: score)
                }
            }
        }
    }
    
    private func performActualVerifiedCapture(_ task: CaptureTask, stabilityScore: Double) {
        guard let webView = task.webView else {
            pendingCaptures.remove(task.pageRecord.id)
            return
        }
        
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
                isLoading: webView.isLoading,
                stabilityScore: stabilityScore
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(task.pageRecord.id)
            return
        }
        
        // 🔧 **검증된 캡처 로직 - 다단계 검증**
        performMultiStageVerifiedCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            maxAttempts: task.maxAttempts
        ) { [weak self] result in
            // 캡처 완료 후 저장
            if let tabID = task.tabID {
                self?.saveToDisk(snapshot: result, tabID: tabID)
            } else {
                self?.storeInMemory(result.snapshot, for: task.pageRecord.id)
            }
            
            // 진행 중 해제
            self?.pendingCaptures.remove(task.pageRecord.id)
            self?.dbg("✅ 검증된 캡처 완료: \(task.pageRecord.title) (품질: \(result.snapshot.captureStatus.rawValue))")
        }
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
        let stabilityScore: Double
    }
    
    // 🔧 **다단계 검증 캡처**
    private func performMultiStageVerifiedCapture(
        pageRecord: PageRecord,
        webView: WKWebView,
        captureData: CaptureData,
        maxAttempts: Int,
        completion: @escaping ((snapshot: BFCacheSnapshot, image: UIImage?)) -> Void
    ) {
        
        var attempts = 0
        var bestResult: (snapshot: BFCacheSnapshot, image: UIImage?)? = nil
        
        func attemptCapture() {
            attempts += 1
            
            let result = performSingleVerifiedCapture(
                pageRecord: pageRecord,
                webView: webView,
                captureData: captureData,
                attemptNumber: attempts
            )
            
            // 결과 평가
            let quality = evaluateCaptureQuality(result.snapshot)
            
            if quality >= 0.8 || attempts >= maxAttempts {
                // 고품질이거나 최대 시도 횟수 도달
                var finalSnapshot = result.snapshot
                finalSnapshot.verificationPassed = quality >= 0.8
                finalSnapshot.captureAttempts = attempts
                
                if quality >= 0.9 {
                    finalSnapshot.captureStatus = .verified
                }
                
                completion((finalSnapshot, result.image))
            } else {
                // 품질 불만족 - 재시도
                if bestResult == nil || quality > evaluateCaptureQuality(bestResult!.snapshot) {
                    bestResult = result
                }
                
                dbg("🔄 캡처 품질 불만족 (\(String(format: "%.2f", quality))) - 재시도 (\(attempts)/\(maxAttempts))")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    attemptCapture()
                }
            }
        }
        
        attemptCapture()
    }
    
    private func performSingleVerifiedCapture(
        pageRecord: PageRecord,
        webView: WKWebView,
        captureData: CaptureData,
        attemptNumber: Int
    ) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var scrollAnchor: ScrollAnchor? = nil
        
        let semaphore = DispatchSemaphore(value: 0)
        var captureResults: [String: Bool] = [:]
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = attemptNumber > 1 // 재시도시만 DOM 업데이트 대기
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    visualSnapshot = self.renderWebViewToImage(webView)
                    captureResults["visual"] = false
                } else {
                    visualSnapshot = image
                    captureResults["visual"] = true
                }
                semaphore.signal()
            }
        }
        
        let visualResult = semaphore.wait(timeout: .now() + 3.0) // 더 긴 타임아웃
        if visualResult == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
            captureResults["visual"] = false
        }
        
        // 2. DOM 캡처 + 스크롤 앵커 생성
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let enhancedCaptureScript = generateEnhancedCaptureScript()
            
            webView.evaluateJavaScript(enhancedCaptureScript) { result, error in
                if let data = result as? [String: Any] {
                    domSnapshot = data["dom"] as? String
                    jsState = data["jsState"] as? [String: Any]
                    
                    // 스크롤 앵커 생성
                    if let anchorData = data["scrollAnchor"] as? [String: Any] {
                        scrollAnchor = self.parseScrollAnchor(from: anchorData)
                    }
                    
                    captureResults["dom"] = domSnapshot != nil
                    captureResults["js"] = jsState != nil
                    captureResults["anchor"] = scrollAnchor != nil
                } else {
                    captureResults["dom"] = false
                    captureResults["js"] = false
                    captureResults["anchor"] = false
                }
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 2.0)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        let visualOK = captureResults["visual"] ?? false
        let domOK = captureResults["dom"] ?? false
        let jsOK = captureResults["js"] ?? false
        let anchorOK = captureResults["anchor"] ?? false
        
        if visualOK && domOK && jsOK && anchorOK {
            captureStatus = .verified
        } else if visualOK && domOK && jsOK {
            captureStatus = .complete
        } else if visualOK {
            captureStatus = jsOK ? .partial : .visualOnly
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
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version,
            scrollAnchor: scrollAnchor
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🎯 **강화된 캡처 스크립트 생성**
    private func generateEnhancedCaptureScript() -> String {
        return """
        (function() {
            try {
                // 1. DOM 스냅샷 (눌린 상태 제거)
                document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(el => {
                    el.classList.remove(...Array.from(el.classList).filter(c => 
                        c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus')
                    ));
                });
                
                document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(el => {
                    el.blur();
                });
                
                const html = document.documentElement.outerHTML;
                const domSnapshot = html.length > 100000 ? html.substring(0, 100000) : html;
                
                // 2. 스크롤 상태 캡처
                const scrollData = captureScrollState();
                
                // 3. 스크롤 앵커 생성
                const scrollAnchor = generateScrollAnchor();
                
                return {
                    dom: domSnapshot,
                    jsState: {
                        scroll: scrollData.scroll,
                        iframes: scrollData.iframes,
                        href: window.location.href,
                        title: document.title,
                        timestamp: Date.now(),
                        viewport: {
                            width: window.innerWidth,
                            height: window.innerHeight
                        }
                    },
                    scrollAnchor: scrollAnchor
                };
                
            } catch(e) { 
                console.error('강화된 캡처 실패:', e);
                return {
                    dom: null,
                    jsState: {
                        scroll: { x: window.scrollX, y: window.scrollY, elements: [] },
                        iframes: [],
                        href: window.location.href,
                        title: document.title
                    },
                    scrollAnchor: null
                };
            }
            
            // 스크롤 상태 캡처 함수
            function captureScrollState() {
                const scrollables = [];
                const maxElements = 30;
                let count = 0;
                
                const explicitScrollables = document.querySelectorAll('*');
                
                for (const el of explicitScrollables) {
                    if (count >= maxElements) break;
                    
                    try {
                        const style = window.getComputedStyle(el);
                        const overflowY = style.overflowY;
                        const overflowX = style.overflowX;
                        
                        if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                            (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) {
                            
                            if (el.scrollTop > 0 || el.scrollLeft > 0) {
                                const selector = generateBestSelector(el);
                                if (selector) {
                                    scrollables.push({
                                        selector: selector,
                                        top: el.scrollTop,
                                        left: el.scrollLeft,
                                        maxTop: el.scrollHeight - el.clientHeight,
                                        maxLeft: el.scrollWidth - el.clientWidth,
                                        id: el.id || '',
                                        className: el.className || '',
                                        tagName: el.tagName.toLowerCase()
                                    });
                                    count++;
                                }
                            }
                        }
                    } catch(e) {
                        continue;
                    }
                }
                
                // iframe 처리
                const iframes = [];
                const iframeElements = document.querySelectorAll('iframe');
                
                for (const iframe of iframeElements) {
                    try {
                        const contentWindow = iframe.contentWindow;
                        if (contentWindow && contentWindow.location) {
                            const scrollX = contentWindow.scrollX || 0;
                            const scrollY = contentWindow.scrollY || 0;
                            
                            if (scrollX > 0 || scrollY > 0) {
                                iframes.push({
                                    selector: generateBestSelector(iframe) || `iframe[src*="${iframe.src.split('/').pop()}"]`,
                                    scrollX: scrollX,
                                    scrollY: scrollY,
                                    src: iframe.src || '',
                                    id: iframe.id || '',
                                    className: iframe.className || ''
                                });
                            }
                        }
                    } catch(e) {
                        // Cross-origin iframe 무시
                    }
                }
                
                return {
                    scroll: { 
                        x: window.scrollX, 
                        y: window.scrollY,
                        elements: scrollables
                    },
                    iframes: iframes
                };
            }
            
            // 🎯 **핵심: 스크롤 앵커 생성**
            function generateScrollAnchor() {
                try {
                    const scrollY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
                    const scrollX = window.scrollX || document.documentElement.scrollLeft || document.body.scrollLeft || 0;
                    
                    const contentHeight = Math.max(
                        document.body.scrollHeight,
                        document.documentElement.scrollHeight,
                        document.body.offsetHeight,
                        document.documentElement.offsetHeight
                    );
                    
                    const viewportHeight = window.innerHeight;
                    
                    // 상대 위치 계산 (0.0 ~ 1.0)
                    const maxScroll = Math.max(1, contentHeight - viewportHeight);
                    const relativePosition = Math.min(1.0, Math.max(0.0, scrollY / maxScroll));
                    
                    // 보이는 요소들 해시 생성
                    const visibleElements = getVisibleElementHashes();
                    
                    // 최상단 및 중앙 보이는 요소 정보
                    const topElement = getElementAtPosition(0, 50); // 상단에서 50px
                    const centerElement = getElementAtPosition(0, viewportHeight / 2); // 중앙
                    
                    // DOM 안정성 점수 계산
                    const stabilityScore = calculateDOMStability();
                    
                    return {
                        absolutePosition: { x: scrollX, y: scrollY },
                        relativePosition: relativePosition,
                        visibleElementHashes: visibleElements,
                        contentHeight: contentHeight,
                        viewportHeight: viewportHeight,
                        timestamp: Date.now(),
                        topElementInfo: topElement,
                        centerElementInfo: centerElement,
                        domStabilityScore: stabilityScore
                    };
                } catch(e) {
                    console.error('스크롤 앵커 생성 실패:', e);
                    return null;
                }
            }
            
            // 보이는 요소 해시 생성
            function getVisibleElementHashes() {
                const hashes = [];
                const rect = { top: 0, left: 0, right: window.innerWidth, bottom: window.innerHeight };
                
                const elements = document.querySelectorAll('h1, h2, h3, h4, h5, h6, p, div[id], div[class], article, section');
                
                for (const el of elements) {
                    try {
                        const elRect = el.getBoundingClientRect();
                        if (elRect.bottom >= rect.top && elRect.top <= rect.bottom &&
                            elRect.right >= rect.left && elRect.left <= rect.right) {
                            
                            const text = el.textContent.trim().substring(0, 50);
                            const hash = simpleHash(el.tagName + el.className + text);
                            hashes.push(hash);
                        }
                    } catch(e) {
                        continue;
                    }
                }
                
                return hashes.slice(0, 10); // 최대 10개
            }
            
            // 특정 위치의 요소 정보 가져오기
            function getElementAtPosition(x, y) {
                try {
                    const element = document.elementFromPoint(x + 10, y);
                    if (!element || element === document.body || element === document.documentElement) {
                        return null;
                    }
                    
                    const rect = element.getBoundingClientRect();
                    
                    return {
                        tagName: element.tagName.toLowerCase(),
                        textContent: element.textContent.trim().substring(0, 50),
                        className: element.className || '',
                        id: element.id || '',
                        offsetTop: element.offsetTop || 0,
                        boundingTop: rect.top
                    };
                } catch(e) {
                    return null;
                }
            }
            
            // DOM 안정성 계산
            function calculateDOMStability() {
                try {
                    let score = 1.0;
                    
                    // 로딩 상태
                    if (document.readyState !== 'complete') score -= 0.3;
                    
                    // 로딩 중인 이미지
                    const images = document.querySelectorAll('img');
                    let loadingImages = 0;
                    images.forEach(img => {
                        if (!img.complete) loadingImages++;
                    });
                    if (loadingImages > 5) score -= 0.2;
                    else if (loadingImages > 0) score -= 0.1;
                    
                    // 콘텐츠 양
                    const contentHeight = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
                    if (contentHeight < 500) score -= 0.1;
                    
                    // 보이는 요소 수
                    const visibleElements = document.querySelectorAll('*').length;
                    if (visibleElements < 20) score -= 0.1;
                    
                    return Math.max(0, Math.min(1, score));
                } catch(e) {
                    return 0.5;
                }
            }
            
            // 간단한 해시 함수
            function simpleHash(str) {
                let hash = 0;
                for (let i = 0; i < str.length; i++) {
                    const char = str.charCodeAt(i);
                    hash = ((hash << 5) - hash) + char;
                    hash = hash & hash; // 32bit int로 변환
                }
                return hash.toString(36);
            }
            
            // 최적의 selector 생성
            function generateBestSelector(element) {
                if (!element || element.nodeType !== 1) return null;
                
                // ID 우선
                if (element.id) {
                    return `#${element.id}`;
                }
                
                // 고유한 클래스
                if (element.className) {
                    const classes = element.className.trim().split(/\\s+/);
                    for (const cls of classes) {
                        try {
                            const elements = document.querySelectorAll(`.${cls}`);
                            if (elements.length === 1 && elements[0] === element) {
                                return `.${cls}`;
                            }
                        } catch(e) {
                            continue;
                        }
                    }
                }
                
                // 태그명 + nth-child
                let parent = element.parentElement;
                if (parent) {
                    const siblings = Array.from(parent.children);
                    const index = siblings.indexOf(element);
                    if (index !== -1) {
                        return `${parent.tagName.toLowerCase()} > ${element.tagName.toLowerCase()}:nth-child(${index + 1})`;
                    }
                }
                
                return element.tagName.toLowerCase();
            }
        })()
        """
    }
    
    // ScrollAnchor 파싱
    private func parseScrollAnchor(from data: [String: Any]) -> ScrollAnchor? {
        guard let absPos = data["absolutePosition"] as? [String: Double],
              let x = absPos["x"], let y = absPos["y"],
              let relativePos = data["relativePosition"] as? Double,
              let visibleHashes = data["visibleElementHashes"] as? [String],
              let contentHeight = data["contentHeight"] as? Double,
              let viewportHeight = data["viewportHeight"] as? Double,
              let domScore = data["domStabilityScore"] as? Double else {
            return nil
        }
        
        let topElementInfo = parseElementInfo(from: data["topElementInfo"] as? [String: Any])
        let centerElementInfo = parseElementInfo(from: data["centerElementInfo"] as? [String: Any])
        
        return ScrollAnchor(
            absolutePosition: CGPoint(x: x, y: y),
            relativePosition: relativePos,
            visibleElementHashes: visibleHashes,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            timestamp: Date(),
            topElementInfo: topElementInfo,
            centerElementInfo: centerElementInfo,
            domStabilityScore: domScore
        )
    }
    
    private func parseElementInfo(from data: [String: Any]?) -> ElementInfo? {
        guard let data = data,
              let tagName = data["tagName"] as? String,
              let textContent = data["textContent"] as? String,
              let className = data["className"] as? String,
              let id = data["id"] as? String,
              let offsetTop = data["offsetTop"] as? Double,
              let boundingTop = data["boundingTop"] as? Double else {
            return nil
        }
        
        return ElementInfo(
            tagName: tagName,
            textContent: textContent,
            className: className,
            id: id,
            offsetTop: offsetTop,
            boundingTop: boundingTop
        )
    }
    
    // 캡처 품질 평가
    private func evaluateCaptureQuality(_ snapshot: BFCacheSnapshot) -> Double {
        var quality = 0.0
        
        // 기본 캡처 상태
        switch snapshot.captureStatus {
        case .verified: quality += 0.4
        case .complete: quality += 0.3
        case .partial: quality += 0.2
        case .visualOnly: quality += 0.1
        case .failed: quality += 0.0
        }
        
        // DOM 스냅샷 품질
        if let dom = snapshot.domSnapshot {
            quality += dom.count > 10000 ? 0.2 : 0.1
        }
        
        // JS 상태 품질
        if let js = snapshot.jsState {
            quality += js.keys.count > 3 ? 0.2 : 0.1
        }
        
        // 스크롤 앵커 품질
        if let anchor = snapshot.scrollAnchor {
            quality += 0.1
            quality += anchor.domStabilityScore * 0.1
            if !anchor.visibleElementHashes.isEmpty {
                quality += 0.1
            }
        }
        
        return min(1.0, quality)
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 **디스크 저장 시스템**
    
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
                title: snapshot.snapshot.pageRecord.title,
                verificationPassed: finalSnapshot.verificationPassed,
                captureQuality: self.evaluateCaptureQuality(finalSnapshot)
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
            
            self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)] (검증: \(finalSnapshot.verificationPassed ? "✅" : "❌"))")
            
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
        let verificationPassed: Bool
        let captureQuality: Double
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
        // 1. 먼저 메모리 캐시 확인
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title) (검증: \(snapshot.verificationPassed ? "✅" : "❌"))")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장 (최적화)
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title) (검증: \(snapshot.verificationPassed ? "✅" : "❌"))")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
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
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)] (검증: \(snapshot.verificationPassed ? "✅" : "❌"))")
    }
    
    // MARK: - 🧹 **캐시 정리**
    
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        // 메모리에서 제거
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
    
    // 메모리 경고 처리
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
            
            // 메모리 캐시의 절반 정리 (검증되지 않은 것부터 우선 제거)
            let sorted = self._memoryCache.sorted { item1, item2 in
                if item1.value.verificationPassed != item2.value.verificationPassed {
                    return !item1.value.verificationPassed // 검증되지 않은 것 우선
                }
                return item1.value.timestamp < item2.value.timestamp // 오래된 것 우선
            }
            
            let removeCount = sorted.count / 2
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            self.dbg("⚠️ 메모리 경고 - 메모리 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🎯 **제스처 시스템**
    
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
        
        // 약한 참조 컨텍스트 생성 및 연결
        if let tabID = stateModel.tabID {
            let ctx = WeakGestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
            objc_setAssociatedObject(leftEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(rightEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        dbg("BFCache 검증 제스처 설정 완료")
    }
    
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
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
            // 전환 중이면 새 제스처 무시
            guard activeTransitions[tabID] == nil else { 
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 기존 전환 강제 정리
                if let existing = activeTransitions[tabID] {
                    existing.previewContainer?.removeFromSuperview()
                    activeTransitions.removeValue(forKey: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                // 현재 페이지 검증된 캡처 (최고 품질)
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .verified, tabID: tabID)
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
        
        dbg("🎬 검증된 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
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
                
                // 검증된 캐시 표시 (시각적 피드백)
                if snapshot.verificationPassed {
                    addVerificationBadge(to: imageView)
                }
                
                targetView = imageView
                dbg("📸 타겟 페이지 BFCache 스냅샷 사용: \(targetRecord.title) (검증: \(snapshot.verificationPassed ? "✅" : "❌"))")
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
    
    private func addVerificationBadge(to view: UIView) {
        let badge = UIView()
        badge.backgroundColor = .systemGreen
        badge.layer.cornerRadius = 8
        badge.translatesAutoresizingMaskIntoConstraints = false
        
        let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        checkmark.tintColor = .white
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        
        badge.addSubview(checkmark)
        view.addSubview(badge)
        
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            badge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            badge.widthAnchor.constraint(equalToConstant: 32),
            badge.heightAnchor.constraint(equalToConstant: 32),
            
            checkmark.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            checkmark.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 20),
            checkmark.heightAnchor.constraint(equalToConstant: 20)
        ])
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
    
    // 🎬 **미리보기 컨테이너 0.8초 고정 타이밍**
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
                self?.performNavigationWithFixedTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🔄 **0.8초 고정 타이밍을 적용한 네비게이션 수행**
    private func performNavigationWithFixedTiming(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 검증된 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 검증된 앞으로가기 완료")
        }
        
        // BFCache 복원
        tryBFCacheRestore(stateModel: stateModel, direction: context.direction)
        
        // 🎬 **핵심: 0.8초 후 미리보기 제거 (깜빡임 방지)**
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            previewContainer.removeFromSuperview()
            self?.activeTransitions.removeValue(forKey: context.tabID)
            self?.dbg("🎬 0.8초 고정 타이밍 미리보기 제거 완료")
        }
    }
    
    // 🔄 **BFCache 복원 (검증된 품질 우선)** 
    private func tryBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트
            let qualityText = snapshot.verificationPassed ? "검증된 고품질" : "일반 품질"
            dbg("✅ BFCache 복원 시작: \(currentRecord.title) (\(qualityText))")
            
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ BFCache 복원 성공: \(currentRecord.title) (\(qualityText))")
                } else {
                    self?.dbg("⚠️ BFCache 복원 실패: \(currentRecord.title)")
                }
            }
        } else {
            // BFCache 미스
            dbg("❌ BFCache 미스: \(currentRecord.title)")
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
    
    // MARK: - 버튼 네비게이션
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 검증된 캡처 (최고 품질)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .verified, tabID: tabID)
        }
        
        stateModel.goBack()
        tryBFCacheRestore(stateModel: stateModel, direction: .back)
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 검증된 캡처 (최고 품질)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .verified, tabID: tabID)
        }
        
        stateModel.goForward()
        tryBFCacheRestore(stateModel: stateModel, direction: .forward)
    }
    
    // MARK: - 스와이프 제스처 감지 처리
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        // 복원 중이면 무시
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        // 절대 원칙: 히스토리에서 찾더라도 무조건 새 페이지로 추가
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가: \(url.absoluteString)")
    }
    
    // MARK: - JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔄 BFCache 페이지 복원');
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
        TabPersistenceManager.debugMessages.append("[BFCache-검증] \(msg)")
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
        
        TabPersistenceManager.debugMessages.append("✅ 검증된 BFCache 시스템 설치 완료")
    }
    
    // CustomWebView의 dismantleUIView에서 호출
    static func uninstall(from webView: WKWebView) {
        // 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        TabPersistenceManager.debugMessages.append("🧹 BFCache 시스템 제거 완료")
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
        
        // 검증된 캐처 (최고 품질)
        captureSnapshot(pageRecord: rec, webView: webView, type: .verified, tabID: tabID)
        dbg("📸 떠나기 검증된 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 검증된 캡처 (최고 품질)
        captureSnapshot(pageRecord: rec, webView: webView, type: .verified, tabID: tabID)
        dbg("📸 도착 검증된 스냅샷 캡처 시작: \(rec.title)")
        
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
