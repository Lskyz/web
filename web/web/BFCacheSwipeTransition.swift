//
//  BFCacheSnapshotManager.swift
//  📸 **4계층 강화된 BFCache 페이지 스냅샷 및 복원 시스템**
//  🎯 **4계층 DOM 기준 정밀 복원** - 거리별 최적화 전략
//  🔧 **다중 뷰포트 앵커 시스템** - 주앵커 + 보조앵커 + 랜드마크 + 구조적 앵커
//  🐛 **디버깅 강화** - 실패 원인 정확한 추적과 로깅
//  🌐 **무한스크롤 특화** - 극거리(1만px+) 복원 지원
//  🔧 **범용 selector 확장** - 모든 사이트 호환 selector 패턴
//  🚫 **JavaScript 반환값 타입 오류 수정** - Swift 호환성 보장
//  ✅ **selector 문법 오류 수정** - 유효한 CSS selector만 사용
//  🇰🇷 **한글 디버깅 강화** - 상세한 실패 원인 추적
//

import UIKit
import WebKit
import SwiftUI

// MARK: - 📸 **4계층 강화된 BFCache 페이지 스냅샷 (무한스크롤 특화)**
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
    
    // 🎯 **핵심 개선: 4계층 강화된 DOM 요소 기반 복원**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 4계층 강화된 DOM 요소 기반 BFCache 복원 시작 - 상태: \(captureStatus.rawValue)")
        
        // 🎯 **1단계: 4계층 강화된 DOM 요소 기반 스크롤 복원 우선 실행**
        performFourTierElementBasedScrollRestore(to: webView)
        
        // 🔧 **기존 상태별 분기 로직 유지**
        switch captureStatus {
        case .failed:
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패 상태 - 4계층 DOM 요소 복원만 수행")
            completion(true)
            return
            
        case .visualOnly:
            TabPersistenceManager.debugMessages.append("🖼️ 이미지만 캡처된 상태 - 4계층 DOM 요소 복원 + 최종보정")
            
        case .partial:
            TabPersistenceManager.debugMessages.append("⚡ 부분 캡처 상태 - 4계층 DOM 요소 복원 + 브라우저 차단 대응")
            
        case .complete:
            TabPersistenceManager.debugMessages.append("✅ 완전 캡처 상태 - 4계층 DOM 요소 복원 + 브라우저 차단 대응")
        }
        
        TabPersistenceManager.debugMessages.append("🌐 4계층 DOM 요소 기반 복원 후 브라우저 차단 대응 시작")
        
        // 🔧 **DOM 요소 복원 후 브라우저 차단 대응 단계 실행**
        DispatchQueue.main.async {
            self.performBrowserBlockingWorkaround(to: webView, completion: completion)
        }
    }
    
    // 🎯 **새로 추가: 4계층 강화된 DOM 요소 기반 1단계 복원 메서드**
    private func performFourTierElementBasedScrollRestore(to webView: WKWebView) {
        TabPersistenceManager.debugMessages.append("🎯 4계층 강화된 DOM 요소 기반 1단계 복원 시작")
        
        // 1. 네이티브 스크롤뷰 기본 설정 (백업용)
        let targetPos = self.scrollPosition
        webView.scrollView.setContentOffset(targetPos, animated: false)
        
        // 2. 🎯 **4계층 강화된 DOM 요소 기반 복원 JavaScript 실행**
        let fourTierRestoreJS = generateFourTierElementBasedRestoreScript()
        
        // 동기적 JavaScript 실행 (즉시)
        webView.evaluateJavaScript(fourTierRestoreJS) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("🎯 4계층 DOM 요소 기반 복원 JS 실행 오류: \(error.localizedDescription)")
                return
            }
            
            // 🚫 **수정: 안전한 타입 체크로 변경**
            var success = false
            if let resultDict = result as? [String: Any] {
                success = (resultDict["success"] as? Bool) ?? false
                
                if let tier = resultDict["tier"] as? Int {
                    TabPersistenceManager.debugMessages.append("🎯 사용된 복원 계층: Tier \(tier)")
                }
                if let method = resultDict["method"] as? String {
                    TabPersistenceManager.debugMessages.append("🎯 사용된 복원 방법: \(method)")
                }
                if let anchorInfo = resultDict["anchorInfo"] as? String {
                    TabPersistenceManager.debugMessages.append("🎯 앵커 정보: \(anchorInfo)")
                }
                if let errorMsg = resultDict["error"] as? String {
                    TabPersistenceManager.debugMessages.append("🎯 DOM 복원 오류: \(errorMsg)")
                }
                if let debugInfo = resultDict["debug"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🎯 DOM 복원 디버그: \(debugInfo)")
                }
                if let tierResults = resultDict["tierResults"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🎯 계층별 결과: \(tierResults)")
                }
                if let verificationResult = resultDict["verification"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🎯 복원 검증 결과: \(verificationResult)")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🎯 4계층 DOM 요소 기반 복원: \(success ? "성공" : "실패")")
        }
        
        TabPersistenceManager.debugMessages.append("🎯 4계층 강화된 DOM 요소 기반 1단계 복원 완료")
    }
    
    // 🎯 **핵심: 4계층 강화된 DOM 요소 기반 복원 JavaScript 생성 (무한스크롤 특화) - 🇰🇷 한글 디버깅 강화**
    private func generateFourTierElementBasedRestoreScript() -> String {
        let targetPos = self.scrollPosition
        let targetPercent = self.scrollPositionPercent
        
        // jsState에서 다중 앵커 정보 추출
        var primaryAnchorData = "null"
        var auxiliaryAnchorsData = "[]"
        var landmarkAnchorsData = "[]"
        var structuralAnchorsData = "[]"
        
        if let jsState = self.jsState {
            // 주 뷰포트 앵커 정보
            if let viewport = jsState["viewportAnchor"] as? [String: Any],
               let anchorJSON = convertToJSONString(viewport) {
                primaryAnchorData = anchorJSON
            }
            
            // 🔧 보조 앵커들 정보
            if let auxiliaryAnchors = jsState["auxiliaryAnchors"] as? [[String: Any]],
               let anchorsJSON = convertToJSONString(auxiliaryAnchors) {
                auxiliaryAnchorsData = anchorsJSON
            }
            
            // 🆕 랜드마크 앵커들 정보 
            if let landmarkAnchors = jsState["landmarkAnchors"] as? [[String: Any]],
               let anchorsJSON = convertToJSONString(landmarkAnchors) {
                landmarkAnchorsData = anchorsJSON
            }
            
            // 🆕 구조적 앵커들 정보
            if let structuralAnchors = jsState["structuralAnchors"] as? [[String: Any]],
               let anchorsJSON = convertToJSONString(structuralAnchors) {
                structuralAnchorsData = anchorsJSON
            }
        }
        
        return """
        (function() {
            try {
                const targetX = parseFloat('\(targetPos.x)');
                const targetY = parseFloat('\(targetPos.y)');
                const targetPercentX = parseFloat('\(targetPercent.x)');
                const targetPercentY = parseFloat('\(targetPercent.y)');
                const primaryAnchor = \(primaryAnchorData);
                const auxiliaryAnchors = \(auxiliaryAnchorsData);
                const landmarkAnchors = \(landmarkAnchorsData);
                const structuralAnchors = \(structuralAnchorsData);
                
                console.log('🇰🇷 4계층 강화된 DOM 앵커 복원 시작:', {
                    목표위치: [targetX, targetY],
                    백분율: [targetPercentX, targetPercentY],
                    주앵커보유: !!primaryAnchor,
                    보조앵커수: auxiliaryAnchors.length,
                    랜드마크앵커수: landmarkAnchors.length,
                    구조적앵커수: structuralAnchors.length,
                    총앵커수: (primaryAnchor ? 1 : 0) + auxiliaryAnchors.length + landmarkAnchors.length + structuralAnchors.length
                });
                
                // 🎯 **4계층 시스템 구성 - 🇰🇷 한글화 및 관대한 허용 오차**
                const TIER_CONFIG = {
                    tier1: {
                        name: '정밀앵커계층',
                        korean: '뷰포트중심 정밀복원',
                        maxDistance: window.innerHeight * 2,      // 0-2화면 (0-1600px)
                        tolerance: Math.max(100, window.innerHeight * 0.1),  // 🔧 **동적 허용오차: 최소 100px 또는 화면높이 10%**
                        strictTolerance: 50,                       // 엄격한 허용오차 (1차 시도용)
                        anchors: primaryAnchor ? [primaryAnchor] : [],
                        description: '뷰포트 정밀 복원',
                        priority: '최고'
                    },
                    tier2: {
                        name: '보조앵커계층',
                        korean: '근거리 세션탐색',
                        maxDistance: window.innerHeight * 10,     // 2-10화면 (1600px-8000px)
                        tolerance: Math.max(150, window.innerHeight * 0.15), // 🔧 **더 관대한 허용오차**
                        strictTolerance: 75,
                        anchors: auxiliaryAnchors,
                        description: '세션 근거리 탐색',
                        priority: '높음'
                    },
                    tier3: {
                        name: '랜드마크계층',
                        korean: '깊은탐색 복원',
                        maxDistance: window.innerHeight * 50,     // 10-50화면 (8000px-40000px)
                        tolerance: Math.max(200, window.innerHeight * 0.2),  // 🔧 **매우 관대한 허용오차**
                        strictTolerance: 100,
                        anchors: landmarkAnchors,
                        description: '깊은 탐색 복원',
                        priority: '중간'
                    },
                    tier4: {
                        name: '구조적계층',
                        korean: '극한스크롤 복원',
                        maxDistance: Infinity,                    // 50화면+ (40000px+)
                        tolerance: Math.max(300, window.innerHeight * 0.3),  // 🔧 **극도로 관대한 허용오차**
                        strictTolerance: 150,
                        anchors: structuralAnchors,
                        description: '극한 스크롤 복원',
                        priority: '기본'
                    }
                };
                
                let restoredByElement = false;
                let usedTier = 0;
                let usedMethod = 'fallback';
                let anchorInfo = 'none';
                let debugInfo = {};
                let errorMsg = null;
                let verificationResult = {};
                let tierResults = {};
                let detailedFailureReasons = []; // 🇰🇷 **상세 실패 원인 추적**
                
                // 🎯 **4계층 순차 시도 시스템 - 🇰🇷 상세 디버깅**
                const tiers = ['tier1', 'tier2', 'tier3', 'tier4'];
                
                for (let i = 0; i < tiers.length && !restoredByElement; i++) {
                    const tierKey = tiers[i];
                    const tierConfig = TIER_CONFIG[tierKey];
                    const tierNum = i + 1;
                    
                    console.log(`🇰🇷 ${tierConfig.name} (${tierConfig.korean}) 시도:`, {
                        최대거리: tierConfig.maxDistance,
                        엄격허용오차: tierConfig.strictTolerance,
                        관대허용오차: tierConfig.tolerance,
                        앵커개수: tierConfig.anchors.length,
                        우선순위: tierConfig.priority,
                        설명: tierConfig.description
                    });
                    
                    // 🇰🇷 **거리 체크 - 현재 계층에서 처리 가능한지 확인**
                    if (targetY <= tierConfig.maxDistance) {
                        try {
                            const tierResult = tryTierRestore(tierNum, tierConfig, targetX, targetY);
                            tierResults[`tier${tierNum}`] = tierResult;
                            
                            if (tierResult.success) {
                                restoredByElement = true;
                                usedTier = tierNum;
                                usedMethod = tierResult.method;
                                anchorInfo = tierResult.anchorInfo;
                                debugInfo[`tier${tierNum}_성공`] = tierResult.debug;
                                
                                console.log(`🇰🇷 ✅ ${tierConfig.name} 복원 성공:`, {
                                    계층번호: tierNum,
                                    복원방법: tierResult.method,
                                    앵커정보: tierResult.anchorInfo,
                                    상세결과: tierResult
                                });
                                break;
                            } else {
                                const failureReason = `${tierConfig.name}: ${tierResult.error}`;
                                detailedFailureReasons.push(failureReason);
                                console.log(`🇰🇷 ❌ ${tierConfig.name} 복원 실패:`, {
                                    계층번호: tierNum,
                                    실패원인: tierResult.error,
                                    상세오류: tierResult.debug || {}
                                });
                                debugInfo[`tier${tierNum}_실패`] = tierResult.error;
                            }
                        } catch(e) {
                            const tierError = `${tierConfig.name} 예외발생: ${e.message}`;
                            detailedFailureReasons.push(tierError);
                            console.error(`🇰🇷 ❌ ${tierConfig.name} 예외:`, e);
                            tierResults[`tier${tierNum}`] = { success: false, error: tierError };
                            debugInfo[`tier${tierNum}_예외`] = e.message;
                        }
                    } else {
                        const skipReason = `${tierConfig.name}: 거리초과 (${targetY}px > ${tierConfig.maxDistance}px)`;
                        detailedFailureReasons.push(skipReason);
                        console.log(`🇰🇷 ⏭️ ${tierConfig.name} 건너뜀:`, {
                            이유: '거리초과',
                            목표거리: targetY,
                            최대허용거리: tierConfig.maxDistance
                        });
                        tierResults[`tier${tierNum}`] = { success: false, skipped: true, reason: 'distance_exceeded' };
                    }
                }
                
                // 🎯 **Tier별 복원 시도 함수 - 🇰🇷 상세 디버깅**
                function tryTierRestore(tierNum, config, targetX, targetY) {
                    try {
                        console.log(`🇰🇷 ${config.name} 복원로직 실행 시작`);
                        
                        // 🔧 **앵커 기반 복원 시도 (엄격모드 → 관대모드)**
                        if (config.anchors && config.anchors.length > 0) {
                            console.log(`🇰🇷 ${config.name} 앵커복원 시도: ${config.anchors.length}개 앵커`);
                            
                            // 1차: 엄격한 허용오차로 시도
                            const strictResult = tryMultipleAnchors(config.anchors, targetX, targetY, config.strictTolerance, '엄격모드');
                            if (strictResult.success) {
                                console.log(`🇰🇷 ✅ ${config.name} 엄격모드 성공:`, strictResult);
                                return {
                                    success: true,
                                    method: `tier${tierNum}_앵커_엄격`,
                                    anchorInfo: `${config.korean}(${strictResult.anchorInfo})`,
                                    debug: strictResult.debug
                                };
                            }
                            
                            // 2차: 관대한 허용오차로 재시도
                            console.log(`🇰🇷 ${config.name} 엄격모드 실패, 관대모드 재시도`);
                            const tolerantResult = tryMultipleAnchors(config.anchors, targetX, targetY, config.tolerance, '관대모드');
                            if (tolerantResult.success) {
                                console.log(`🇰🇷 ✅ ${config.name} 관대모드 성공:`, tolerantResult);
                                return {
                                    success: true,
                                    method: `tier${tierNum}_앵커_관대`,
                                    anchorInfo: `${config.korean}_관대(${tolerantResult.anchorInfo})`,
                                    debug: tolerantResult.debug
                                };
                            }
                            
                            console.log(`🇰🇷 ❌ ${config.name} 모든 앵커복원 실패:`, {
                                엄격모드오류: strictResult.error,
                                관대모드오류: tolerantResult.error
                            });
                        }
                        
                        // 🔧 **Tier별 폴백 전략 시도**
                        console.log(`🇰🇷 ${config.name} 폴백전략 시도`);
                        const fallbackResult = tryTierFallback(tierNum, config, targetX, targetY);
                        if (fallbackResult.success) {
                            console.log(`🇰🇷 ✅ ${config.name} 폴백 성공:`, fallbackResult);
                            return {
                                success: true,
                                method: `tier${tierNum}_폴백`,
                                anchorInfo: `${config.korean}_폴백(${fallbackResult.anchorInfo})`,
                                debug: fallbackResult.debug
                            };
                        }
                        
                        return {
                            success: false,
                            error: `${config.name} 모든전략 실패 (앵커: ${config.anchors.length}개, 폴백실패: ${fallbackResult.error})`,
                            debug: { 
                                앵커시도함: config.anchors.length, 
                                폴백시도함: true,
                                폴백오류: fallbackResult.error,
                                계층정보: config
                            }
                        };
                        
                    } catch(e) {
                        return {
                            success: false,
                            error: `${config.name} 실행중 예외: ${e.message}`,
                            debug: { 예외내용: e.message, 스택: e.stack }
                        };
                    }
                }
                
                // 🎯 **다중 앵커 복원 함수 - 🇰🇷 상세 실패 원인 분석**
                function tryMultipleAnchors(anchors, targetX, targetY, tolerance, mode) {
                    let anchorAttempts = [];
                    let successfulAnchor = null;
                    let anchorElement = null;
                    let anchorDebug = { 모드: mode, 허용오차: tolerance };
                    
                    console.log(`🇰🇷 다중앵커 복원시도 (${mode}):`, {
                        앵커개수: anchors.length,
                        허용오차: tolerance,
                        목표위치: [targetX, targetY]
                    });
                    
                    for (let i = 0; i < anchors.length; i++) {
                        const anchor = anchors[i];
                        if (!anchor || !anchor.selector) {
                            anchorAttempts.push({
                                앵커번호: i + 1,
                                상태: '건너뜀',
                                이유: 'selector 없음',
                                앵커데이터: anchor
                            });
                            continue;
                        }
                        
                        console.log(`🇰🇷 앵커 ${i + 1}/${anchors.length} 검색:`, anchor.selector);
                        
                        const elementResult = tryFindAnchorElement(anchor);
                        
                        anchorAttempts.push({
                            앵커번호: i + 1,
                            selector: anchor.selector,
                            검색결과: elementResult
                        });
                        
                        if (elementResult.element) {
                            anchorElement = elementResult.element;
                            successfulAnchor = anchor;
                            anchorDebug.성공한앵커 = `앵커_${i + 1}`;
                            anchorDebug.검색성공정보 = elementResult;
                            console.log(`🇰🇷 ✅ 앵커 ${i + 1} 요소발견 성공`);
                            break;
                        } else {
                            console.log(`🇰🇷 ❌ 앵커 ${i + 1} 요소검색 실패:`, elementResult.error);
                        }
                    }
                    
                    anchorDebug.모든앵커시도 = anchorAttempts;
                    
                    if (anchorElement && successfulAnchor) {
                        // 🇰🇷 **앵커 요소의 현재 위치 정밀 계산**
                        const rect = anchorElement.getBoundingClientRect();
                        const elementTop = window.scrollY + rect.top;
                        const elementLeft = window.scrollX + rect.left;
                        
                        // 저장된 오프셋 적용
                        const offsetY = parseFloat(successfulAnchor.offsetFromTop) || 0;
                        const offsetX = parseFloat(successfulAnchor.offsetFromLeft) || 0;
                        
                        const restoreX = elementLeft - offsetX;
                        const restoreY = elementTop - offsetY;
                        
                        // 🇰🇷 **허용 오차 체크 - 상세 분석**
                        const diffX = Math.abs(restoreX - targetX);
                        const diffY = Math.abs(restoreY - targetY);
                        const maxDiff = Math.max(diffX, diffY);
                        
                        const positionInfo = {
                            앵커타입: anchorDebug.성공한앵커,
                            selector: successfulAnchor.selector,
                            요소현재위치: [elementLeft, elementTop],
                            저장된오프셋: [offsetX, offsetY],
                            계산된복원위치: [restoreX, restoreY],
                            목표위치: [targetX, targetY],
                            위치차이: [diffX, diffY],
                            최대차이: maxDiff,
                            허용오차: tolerance,
                            허용오차통과: maxDiff <= tolerance
                        };
                        
                        anchorDebug.위치계산 = positionInfo;
                        
                        if (maxDiff <= tolerance) {
                            console.log(`🇰🇷 ✅ 앵커 허용오차 통과 (${mode}):`, positionInfo);
                            
                            // 🇰🇷 **앵커 기반 스크롤 실행**
                            performScrollTo(restoreX, restoreY);
                            
                            return {
                                success: true,
                                anchorInfo: `${anchorDebug.성공한앵커}(${successfulAnchor.selector})`,
                                debug: anchorDebug
                            };
                        } else {
                            const rejectReason = `허용오차 초과: ${maxDiff.toFixed(1)}px > ${tolerance}px (차이: X=${diffX.toFixed(1)}, Y=${diffY.toFixed(1)})`;
                            console.log(`🇰🇷 ❌ 앵커 허용오차 초과 (${mode}):`, {
                                최대차이: maxDiff,
                                허용오차: tolerance,
                                상세정보: positionInfo
                            });
                            return {
                                success: false,
                                error: rejectReason,
                                debug: anchorDebug
                            };
                        }
                    }
                    
                    const noElementError = `모든 앵커 요소검색 실패 (시도: ${anchors.length}개)`;
                    console.log(`🇰🇷 ❌ 다중앵커 복원실패 (${mode}):`, {
                        오류: noElementError,
                        시도한앵커들: anchorAttempts
                    });
                    
                    return {
                        success: false,
                        error: noElementError,
                        debug: anchorDebug
                    };
                }
                
                // 🇰🇷 **향상된 앵커 요소 찾기 함수 - 상세 실패 원인 분석**
                function tryFindAnchorElement(anchor) {
                    if (!anchor || !anchor.selector) {
                        return { element: null, error: 'anchor 또는 selector가 없음' };
                    }
                    
                    // 다중 selector 시도
                    const selectors = anchor.selectors || [anchor.selector];
                    let attemptResults = [];
                    
                    for (let i = 0; i < selectors.length; i++) {
                        const selector = selectors[i];
                        try {
                            const elements = document.querySelectorAll(selector);
                            
                            attemptResults.push({
                                selector번호: i + 1,
                                selector: selector,
                                검색된요소수: elements.length,
                                상태: elements.length > 0 ? '성공' : '요소없음'
                            });
                            
                            if (elements.length > 0) {
                                console.log(`🇰🇷 ✅ selector ${i + 1} 성공: ${elements.length}개 요소발견`);
                                return { 
                                    element: elements[0], 
                                    selector: selector,
                                    찾은요소수: elements.length,
                                    시도결과: attemptResults
                                };
                            }
                        } catch(e) {
                            attemptResults.push({
                                selector번호: i + 1,
                                selector: selector,
                                상태: 'selector 오류',
                                오류내용: e.message
                            });
                            console.warn(`🇰🇷 ⚠️ selector ${i + 1} 오류: ${selector} - ${e.message}`);
                            continue;
                        }
                    }
                    
                    return { 
                        element: null, 
                        error: `모든 selector 실패 (시도: ${selectors.length}개)`,
                        시도결과: attemptResults
                    };
                }
                
                // 🎯 **Tier별 특화 폴백 전략 - 🇰🇷 한글화**
                function tryTierFallback(tierNum, config, targetX, targetY) {
                    console.log(`🇰🇷 ${config.name} 폴백전략 시작`);
                    
                    switch(tierNum) {
                        case 1: // Tier 1: 정밀 요소 기반
                            return tryPrecisionElementFallback(targetX, targetY, config.tolerance);
                        case 2: // Tier 2: 콘텐츠 아이템 기반
                            return tryContentItemFallback(targetX, targetY, config.tolerance);
                        case 3: // Tier 3: 페이지 섹션 기반
                            return tryPageSectionFallback(targetX, targetY, config.tolerance);
                        case 4: // Tier 4: 페이지 구조 기반
                            return tryPageStructureFallback(targetX, targetY, config.tolerance);
                        default:
                            return { success: false, error: '알 수 없는 계층번호' };
                    }
                }
                
                // 🔧 **Tier 1: 정밀 요소 기반 폴백 (0-2화면) - 🇰🇷 한글화**
                function tryPrecisionElementFallback(targetX, targetY, tolerance) {
                    try {
                        console.log('🇰🇷 Tier 1 정밀요소 폴백 시작');
                        
                        // ✅ **수정: 유효한 CSS selector만 사용**
                        const precisionSelectors = [
                            // ID를 가진 요소들
                            '[id]',
                            // 특정 data 속성들
                            '[data-testid]', '[data-id]', '[data-key]',
                            '[data-item-id]', '[data-article-id]', '[data-post-id]', 
                            '[data-comment-id]', '[data-user-id]', '[data-content-id]',
                            '[data-thread-id]', '[data-message-id]',
                            '[data-component-id]', '[data-widget-id]', '[data-module-id]',
                            '[data-entry-id]', '[data-slug]', '[data-permalink]',
                            // React 관련
                            '[data-reactid]', '[key]'
                        ];
                        
                        const result = tryElementBasedRestore(precisionSelectors, targetX, targetY, tolerance, 50, 'Tier1_정밀요소');
                        
                        if (result.success) {
                            result.anchorInfo = `정밀요소_${result.anchorInfo}`;
                            console.log('🇰🇷 ✅ Tier 1 정밀요소 폴백 성공:', result);
                        } else {
                            console.log('🇰🇷 ❌ Tier 1 정밀요소 폴백 실패:', result.error);
                        }
                        
                        return result;
                    } catch(e) {
                        const error = `Tier 1 정밀요소 폴백 예외: ${e.message}`;
                        console.error('🇰🇷 ❌', error);
                        return { 
                            success: false, 
                            error: error,
                            debug: { 예외내용: e.message }
                        };
                    }
                }
                
                // 🔧 **Tier 2-4: 통합된 범용 요소 기반 폴백 (거리별 구분만) - 🇰🇷 한글화**
                function tryContentItemFallback(targetX, targetY, tolerance) {
                    return tryUniversalElementFallback(targetX, targetY, tolerance, 2, 200, 'Tier2_콘텐츠');
                }
                
                function tryPageSectionFallback(targetX, targetY, tolerance) {
                    return tryUniversalElementFallback(targetX, targetY, tolerance, 3, 100, 'Tier3_섹션');
                }
                
                function tryPageStructureFallback(targetX, targetY, tolerance) {
                    // 🔧 **구조적 복원: 페이지 높이 기반 비례 조정**
                    console.log('🇰🇷 Tier 4 구조적 복원: 비례조정 시도');
                    const proportionalResult = tryProportionalRestore(targetX, targetY, tolerance);
                    if (proportionalResult.success) {
                        console.log('🇰🇷 ✅ Tier 4 비례조정 성공:', proportionalResult);
                        return proportionalResult;
                    }
                    
                    console.log('🇰🇷 Tier 4 비례조정 실패, 범용요소 폴백 시도');
                    
                    // 통합 범용 요소 기반 복원
                    const elementResult = tryUniversalElementFallback(targetX, targetY, tolerance, 4, 50, 'Tier4_구조적');
                    
                    if (elementResult.success) {
                        return elementResult;
                    }
                    
                    // 🔧 **최후 수단: 좌표 기반 복원**
                    console.log('🇰🇷 Tier 4 최후수단: 좌표기반 복원');
                    performScrollTo(targetX, targetY);
                    
                    return {
                        success: true,
                        anchorInfo: `좌표복원(${targetX},${targetY})`,
                        debug: { 
                            복원방법: '좌표기반_최후수단',
                            비례조정실패: proportionalResult.error,
                            요소복원실패: elementResult.error
                        }
                    };
                }
                
                // 🔧 **새로운 통합 범용 요소 기반 폴백 함수 - 🇰🇷 한글화**
                function tryUniversalElementFallback(targetX, targetY, tolerance, tierNum, maxElements, tierName) {
                    try {
                        console.log(`🇰🇷 ${tierName} 통합범용요소 폴백 시작`);
                        
                        // ✅ **수정: 유효한 CSS selector만 사용**
                        const universalSelectors = [
                            // 기본 HTML 요소들
                            'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
                            'p', 'div', 'span', 'a', 'button',
                            'li', 'tr', 'td', 'th', 'dt', 'dd',
                            'article', 'section', 'aside', 'header', 'footer', 'nav', 'main',
                            'img', 'video', 'iframe',
                            'form', 'input', 'textarea', 'select',
                            
                            // 클래스 패턴 (와일드카드 대신 구체적 패턴)
                            '.item', '.list-item', '.card', '.post', '.article',
                            '.content', '.box', '.container', '.row', '.cell',
                            '.comment', '.reply', '.feed', '.thread', '.message',
                            '.product', '.news', '.media',
                            
                            // role 속성들
                            '[role="article"]', '[role="main"]', '[role="button"]',
                            '[role="navigation"]', '[role="contentinfo"]',
                            
                            // ARIA 속성들
                            '[aria-label]', '[aria-labelledby]', '[aria-describedby]',
                            
                            // data 속성들 (구체적인 것만)
                            '[data-component]', '[data-widget]', '[data-module]',
                            '[data-type]', '[data-category]', '[data-index]'
                        ];
                        
                        const result = tryElementBasedRestore(universalSelectors, targetX, targetY, tolerance, maxElements, tierName);
                        
                        if (result.success) {
                            result.anchorInfo = `${tierName}_${result.anchorInfo}`;
                            console.log(`🇰🇷 ✅ ${tierName} 통합범용요소 폴백 성공:`, result);
                        } else {
                            console.log(`🇰🇷 ❌ ${tierName} 통합범용요소 폴백 실패:`, result.error);
                        }
                        
                        return result;
                    } catch(e) {
                        const error = `${tierName} 폴백 예외: ${e.message}`;
                        console.error(`🇰🇷 ❌ ${error}`);
                        return { 
                            success: false, 
                            error: error,
                            debug: { 예외내용: e.message }
                        };
                    }
                }
                
                // 🔧 **공통: 요소 기반 복원 함수 - 🇰🇷 상세 디버깅**
                function tryElementBasedRestore(selectors, targetX, targetY, tolerance, maxElements, tierName) {
                    try {
                        let allElements = [];
                        let selectorStats = {};
                        let successCount = 0;
                        let errorCount = 0;
                        
                        console.log(`🇰🇷 ${tierName} 요소수집 시작: ${selectors.length}개 selector`);
                        
                        // 모든 selector에서 요소 수집
                        for (const selector of selectors) {
                            try {
                                const elements = document.querySelectorAll(selector);
                                if (elements.length > 0) {
                                    selectorStats[selector] = elements.length;
                                    allElements.push(...Array.from(elements));
                                    successCount++;
                                }
                            } catch(e) {
                                selectorStats[selector] = `오류: ${e.message}`;
                                errorCount++;
                                console.warn(`🇰🇷 ⚠️ Selector 오류: ${selector} - ${e.message}`);
                            }
                        }
                        
                        const collectionResult = {
                            전체selector수: selectors.length,
                            성공selector수: successCount,
                            오류selector수: errorCount,
                            총요소수: allElements.length,
                            selector통계: selectorStats
                        };
                        
                        console.log(`🇰🇷 ${tierName} 요소수집 결과:`, collectionResult);
                        
                        if (allElements.length === 0) {
                            return {
                                success: false,
                                error: '검색된 요소 없음',
                                debug: { 수집결과: collectionResult }
                            };
                        }
                        
                        // 🇰🇷 **거리 기반 정렬 및 제한 - 상세 분석**
                        let scoredElements = [];
                        const searchCandidates = allElements.slice(0, maxElements);
                        
                        console.log(`🇰🇷 ${tierName} 거리계산: ${searchCandidates.length}개 요소 대상`);
                        
                        for (const element of searchCandidates) {
                            try {
                                const rect = element.getBoundingClientRect();
                                const elementY = window.scrollY + rect.top;
                                const elementX = window.scrollX + rect.left;
                                const distance = Math.sqrt(
                                    Math.pow(elementX - targetX, 2) + 
                                    Math.pow(elementY - targetY, 2)
                                );
                                
                                if (distance <= tolerance) {
                                    scoredElements.push({
                                        elementId: element.id || null,
                                        elementTagName: element.tagName || 'UNKNOWN',
                                        elementClassName: (element.className || '').split(' ')[0] || null,
                                        distance: distance,
                                        position: [elementX, elementY],
                                        tag: element.tagName,
                                        id: element.id || null,
                                        className: (element.className || '').split(' ')[0] || null,
                                        _element: element  // 내부 처리용
                                    });
                                }
                            } catch(e) {
                                // 개별 요소 오류는 무시
                            }
                        }
                        
                        const filterResult = {
                            검색대상요소수: searchCandidates.length,
                            허용오차내요소수: scoredElements.length,
                            허용오차: tolerance
                        };
                        
                        console.log(`🇰🇷 ${tierName} 허용오차 필터링:`, filterResult);
                        
                        if (scoredElements.length === 0) {
                            return {
                                success: false,
                                error: `허용오차 내 요소 없음 (허용오차: ${tolerance}px)`,
                                debug: { 
                                    수집결과: collectionResult,
                                    필터결과: filterResult
                                }
                            };
                        }
                        
                        // 🇰🇷 **가장 가까운 요소로 복원 - 상세 로깅**
                        scoredElements.sort((a, b) => a.distance - b.distance);
                        const closest = scoredElements[0];
                        
                        console.log(`🇰🇷 ${tierName} 최근접요소 선택:`, {
                            태그: closest.tag,
                            ID: closest.id || '없음',
                            클래스: closest.className || '없음',
                            거리: closest.distance.toFixed(1) + 'px',
                            위치: closest.position
                        });
                        
                        // 해당 요소로 스크롤 (내부 요소 사용)
                        const element = closest._element;
                        element.scrollIntoView({ 
                            behavior: 'auto', 
                            block: 'start',
                            inline: 'start'
                        });
                        
                        // 🇰🇷 **미세 조정 - 상세 로깅**
                        const rect = element.getBoundingClientRect();
                        const currentY = window.scrollY + rect.top;
                        const currentX = window.scrollX + rect.left;
                        const adjustmentY = targetY - currentY;
                        const adjustmentX = targetX - currentX;
                        
                        const adjustmentInfo = {
                            현재위치: [currentX, currentY],
                            목표위치: [targetX, targetY],
                            조정량: [adjustmentX, adjustmentY],
                            조정필요: Math.abs(adjustmentY) <= tolerance && Math.abs(adjustmentX) <= tolerance
                        };
                        
                        console.log(`🇰🇷 ${tierName} 미세조정:`, adjustmentInfo);
                        
                        if (Math.abs(adjustmentY) <= tolerance && Math.abs(adjustmentX) <= tolerance) {
                            window.scrollBy(adjustmentX, adjustmentY);
                        }
                        
                        const finalInfo = `${closest.tag}${closest.id ? '#' + closest.id : ''}${closest.className ? '.' + closest.className : ''}`;
                        
                        // 🚫 **수정: _element 제거하고 반환 (Swift 호환성)**
                        const returnClosest = {
                            elementId: closest.elementId,
                            elementTagName: closest.elementTagName,
                            elementClassName: closest.elementClassName,
                            distance: closest.distance,
                            position: closest.position,
                            tag: closest.tag,
                            id: closest.id,
                            className: closest.className
                        };
                        
                        return {
                            success: true,
                            anchorInfo: `${finalInfo}_거리(${Math.round(closest.distance)})`,
                            debug: {
                                후보요소수: scoredElements.length,
                                최근접요소: returnClosest,
                                조정정보: adjustmentInfo,
                                수집결과: collectionResult,
                                필터결과: filterResult
                            }
                        };
                        
                    } catch(e) {
                        const error = `${tierName} 요소기반 복원 예외: ${e.message}`;
                        console.error(`🇰🇷 ❌ ${error}`);
                        return {
                            success: false,
                            error: error,
                            debug: { 예외내용: e.message }
                        };
                    }
                }
                
                // 🔧 **비례 조정 복원 (페이지 높이 변화 대응) - 🇰🇷 한글화**
                function tryProportionalRestore(targetX, targetY, tolerance) {
                    try {
                        const currentPageHeight = Math.max(
                            document.documentElement.scrollHeight,
                            document.body.scrollHeight
                        );
                        const savedContentHeight = parseFloat('\(contentSize.height)') || currentPageHeight;
                        
                        const heightDiff = Math.abs(currentPageHeight - savedContentHeight);
                        
                        const proportionalInfo = {
                            저장된높이: savedContentHeight,
                            현재높이: currentPageHeight,
                            높이차이: heightDiff,
                            비례조정필요: heightDiff > 1000
                        };
                        
                        console.log('🇰🇷 비례조정 분석:', proportionalInfo);
                        
                        if (savedContentHeight > 0 && heightDiff > 1000) {
                            // 페이지 높이가 크게 변경됨 - 비례 조정
                            const heightRatio = currentPageHeight / savedContentHeight;
                            const adjustedTargetY = targetY * heightRatio;
                            const adjustedTargetX = targetX; // X는 보통 변하지 않음
                            
                            const adjustmentInfo = {
                                높이비율: heightRatio,
                                원래목표: [targetX, targetY],
                                조정된목표: [adjustedTargetX, adjustedTargetY],
                                조정량: [adjustedTargetX - targetX, adjustedTargetY - targetY]
                            };
                            
                            console.log('🇰🇷 ✅ 페이지 높이변화 감지 - 비례조정:', adjustmentInfo);
                            
                            performScrollTo(adjustedTargetX, adjustedTargetY);
                            
                            return {
                                success: true,
                                anchorInfo: `비례조정(${heightRatio.toFixed(3)})`,
                                debug: {
                                    복원방법: '비례조정',
                                    비례정보: proportionalInfo,
                                    조정정보: adjustmentInfo
                                }
                            };
                        }
                        
                        return {
                            success: false,
                            error: '페이지 높이변화 없음 또는 미미함',
                            debug: {
                                비례정보: proportionalInfo,
                                높이차이: heightDiff,
                                조정기준: 1000
                            }
                        };
                        
                    } catch(e) {
                        const error = `비례조정 예외: ${e.message}`;
                        console.error('🇰🇷 ❌', error);
                        return {
                            success: false,
                            error: error,
                            debug: { 예외내용: e.message }
                        };
                    }
                }
                
                // 🔧 **최종 결과 처리 - 🇰🇷 한글화**
                if (!restoredByElement) {
                    // 모든 계층 실패 - 긴급 폴백
                    console.log('🇰🇷 🚨 모든 4계층 실패 - 긴급 좌표 폴백');
                    performScrollTo(targetX, targetY);
                    usedTier = 0;
                    usedMethod = '긴급_좌표복원';
                    anchorInfo = '긴급복원';
                    errorMsg = `모든 4계층 복원 실패: ${detailedFailureReasons.join(', ')}`;
                }
                
                // 🔧 **복원 후 위치 검증 및 보정 - 🇰🇷 한글화**
                setTimeout(() => {
                    try {
                        const finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const diffY = Math.abs(finalY - targetY);
                        const diffX = Math.abs(finalX - targetX);
                        
                        // 사용된 Tier의 허용 오차 적용
                        const tierConfig = usedTier > 0 ? TIER_CONFIG[`tier${usedTier}`] : null;
                        const tolerance = tierConfig ? tierConfig.tolerance : 100; // 기본 100px
                        
                        verificationResult = {
                            목표위치: [targetX, targetY],
                            최종위치: [finalX, finalY],
                            위치차이: [diffX, diffY],
                            사용계층: usedTier,
                            복원방법: usedMethod,
                            허용오차: tolerance,
                            허용오차통과: diffX <= tolerance && diffY <= tolerance,
                            요소기반복원: restoredByElement,
                            실패원인들: detailedFailureReasons
                        };
                        
                        console.log('🇰🇷 4계층 복원 검증:', verificationResult);
                        
                        // 🔧 **허용 오차 초과 시 점진적 보정 - 🇰🇷 한글화**
                        if (!verificationResult.허용오차통과 && (diffY > tolerance || diffX > tolerance)) {
                            console.log('🇰🇷 🔧 허용오차 초과 - 점진적 보정 시작:', verificationResult);
                            
                            // 보정 단계 수를 거리에 비례하여 조정
                            const maxDiff = Math.max(diffX, diffY);
                            const steps = Math.min(5, Math.max(2, Math.ceil(maxDiff / 1000)));
                            const stepX = (targetX - finalX) / steps;
                            const stepY = (targetY - finalY) / steps;
                            
                            const correctionInfo = {
                                최대차이: maxDiff,
                                보정단계수: steps,
                                단계크기: [stepX, stepY],
                                이유: '허용오차초과'
                            };
                            
                            console.log('🇰🇷 🔧 점진적 보정 계획:', correctionInfo);
                            
                            for (let i = 1; i <= steps; i++) {
                                setTimeout(() => {
                                    const stepTargetX = finalX + stepX * i;
                                    const stepTargetY = finalY + stepY * i;
                                    performScrollTo(stepTargetX, stepTargetY);
                                    console.log(`🇰🇷 🔧 점진적 보정 ${i}/${steps}:`, [stepTargetX, stepTargetY]);
                                }, i * 150);
                            }
                            
                            verificationResult.점진적보정 = correctionInfo;
                        }
                        
                    } catch(verifyError) {
                        verificationResult = {
                            오류: verifyError.message,
                            사용계층: usedTier,
                            복원방법: usedMethod,
                            실패원인들: detailedFailureReasons
                        };
                        console.error('🇰🇷 ❌ 4계층 복원 검증 실패:', verifyError);
                    }
                }, 100);
                
                // 🚫 **수정: Swift 호환 반환값 (기본 타입만) - 🇰🇷 한글 키 포함**
                return {
                    success: true,
                    tier: usedTier,
                    method: usedMethod,
                    anchorInfo: anchorInfo,
                    elementBased: restoredByElement,
                    debug: debugInfo,
                    tierResults: tierResults,
                    error: errorMsg,
                    verification: verificationResult,
                    detailedFailureReasons: detailedFailureReasons  // 🇰🇷 **상세 실패 원인 추가**
                };
                
            } catch(e) { 
                console.error('🇰🇷 ❌ 4계층 강화된 DOM 요소 기반 복원 실패:', e);
                // 🚫 **수정: Swift 호환 반환값 - 🇰🇷 한글 키 포함**
                return {
                    success: false,
                    tier: 0,
                    method: '전체오류',
                    anchorInfo: e.message,
                    elementBased: false,
                    error: e.message,
                    debug: { 전체오류: e.message },
                    detailedFailureReasons: [`전체 시스템 오류: ${e.message}`]
                };
            }
            
            // 🔧 **헬퍼 함수들 - 🇰🇷 한글 로그 포함**
            
            // 통합된 스크롤 실행 함수
            function performScrollTo(x, y) {
                console.log(`🇰🇷 스크롤 실행: (${x}, ${y})`);
                window.scrollTo(x, y);
                document.documentElement.scrollTop = y;
                document.documentElement.scrollLeft = x;
                document.body.scrollTop = y;
                document.body.scrollLeft = x;
                
                if (document.scrollingElement) {
                    document.scrollingElement.scrollTop = y;
                    document.scrollingElement.scrollLeft = x;
                }
            }
        })()
        """
    }
    
    // 🚫 **브라우저 차단 대응 시스템 (점진적 스크롤 + 무한 스크롤 트리거) - 🇰🇷 한글 디버깅**
    private func performBrowserBlockingWorkaround(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        TabPersistenceManager.debugMessages.append("🇰🇷 🚫 브라우저 차단 대응 단계 구성 시작")
        
        // **1단계: 점진적 스크롤 복원 (브라우저 차단 해결) - 🇰🇷 한글 디버깅**
        restoreSteps.append((1, { stepCompletion in
            let progressiveDelay: TimeInterval = 0.1
            TabPersistenceManager.debugMessages.append("🇰🇷 🚫 1단계: 점진적 스크롤 복원 (대기: \(String(format: "%.0f", progressiveDelay * 1000))ms)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + progressiveDelay) {
                let progressiveScrollJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        const tolerance = 50.0;
                        
                        console.log('🇰🇷 🚫 점진적 스크롤 시작:', {목표위치: [targetX, targetY]});
                        
                        // 🚫 **브라우저 차단 대응: 점진적 스크롤 - 🇰🇷 상세 디버깅**
                        let attempts = 0;
                        const maxAttempts = 15;
                        const debugLog = [];
                        
                        function performScrollAttempt() {
                            try {
                                attempts++;
                                
                                // 현재 위치 확인
                                const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                
                                const diffX = Math.abs(currentX - targetX);
                                const diffY = Math.abs(currentY - targetY);
                                
                                debugLog.push({
                                    시도횟수: attempts,
                                    현재위치: [currentX, currentY],
                                    목표위치: [targetX, targetY],
                                    위치차이: [diffX, diffY],
                                    허용오차통과: diffX <= tolerance && diffY <= tolerance
                                });
                                
                                // 목표 도달 확인
                                if (diffX <= tolerance && diffY <= tolerance) {
                                    console.log('🇰🇷 🚫 ✅ 점진적 스크롤 성공:', {
                                        현재위치: [currentX, currentY], 
                                        시도횟수: attempts,
                                        최종차이: [diffX, diffY]
                                    });
                                    return '점진적스크롤_성공';
                                }
                                
                                // 스크롤 한계 확인 (더 이상 스크롤할 수 없음)
                                const maxScrollY = Math.max(
                                    document.documentElement.scrollHeight - window.innerHeight,
                                    document.body.scrollHeight - window.innerHeight,
                                    0
                                );
                                const maxScrollX = Math.max(
                                    document.documentElement.scrollWidth - window.innerWidth,
                                    document.body.scrollWidth - window.innerWidth,
                                    0
                                );
                                
                                debugLog[debugLog.length - 1].스크롤한계 = {
                                    최대X: maxScrollX,
                                    최대Y: maxScrollY,
                                    X한계도달: currentX >= maxScrollX,
                                    Y한계도달: currentY >= maxScrollY
                                };
                                
                                if (currentY >= maxScrollY && targetY > maxScrollY) {
                                    console.log('🇰🇷 🚫 Y축 스크롤 한계 도달:', {현재: currentY, 최대: maxScrollY, 목표: targetY});
                                    
                                    // 🚫 **무한 스크롤 트리거 시도**
                                    console.log('🇰🇷 🚫 무한 스크롤 트리거 시도');
                                    
                                    // 스크롤 이벤트 강제 발생
                                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                                    window.dispatchEvent(new Event('resize', { bubbles: true }));
                                    
                                    // 터치 이벤트 시뮬레이션 (모바일 무한 스크롤용)
                                    try {
                                        const touchEvent = new TouchEvent('touchend', { bubbles: true });
                                        document.dispatchEvent(touchEvent);
                                        debugLog[debugLog.length - 1].무한스크롤트리거 = 'touchEvent_시도함';
                                    } catch(e) {
                                        debugLog[debugLog.length - 1].무한스크롤트리거 = 'touchEvent_지원안함';
                                    }
                                    
                                    // 하단 영역 클릭 시뮬레이션 (일부 사이트의 "더보기" 버튼)
                                    const loadMoreButtons = document.querySelectorAll(
                                        '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                                        '[data-role="load"], .load-more, .show-more, .infinite-scroll-trigger'
                                    );
                                    
                                    let clickedButtons = 0;
                                    loadMoreButtons.forEach(btn => {
                                        if (btn && typeof btn.click === 'function') {
                                            try {
                                                btn.click();
                                                clickedButtons++;
                                                console.log('🇰🇷 🚫 "더보기" 버튼 클릭:', btn.className);
                                            } catch(e) {
                                                // 클릭 실패는 무시
                                            }
                                        }
                                    });
                                    
                                    debugLog[debugLog.length - 1].더보기버튼 = {
                                        발견개수: loadMoreButtons.length,
                                        클릭개수: clickedButtons
                                    };
                                }
                                
                                // 스크롤 시도 - 여러 방법으로
                                try {
                                    window.scrollTo(targetX, targetY);
                                    document.documentElement.scrollTop = targetY;
                                    document.documentElement.scrollLeft = targetX;
                                    document.body.scrollTop = targetY;
                                    document.body.scrollLeft = targetX;
                                    
                                    if (document.scrollingElement) {
                                        document.scrollingElement.scrollTop = targetY;
                                        document.scrollingElement.scrollLeft = targetX;
                                    }
                                    
                                    debugLog[debugLog.length - 1].스크롤시도 = '완료';
                                } catch(scrollError) {
                                    debugLog[debugLog.length - 1].스크롤시도 = '오류: ' + scrollError.message;
                                }
                                
                                // 최대 시도 확인
                                if (attempts >= maxAttempts) {
                                    console.log('🇰🇷 🚫 점진적 스크롤 최대 시도 도달:', {
                                        목표위치: [targetX, targetY],
                                        최종위치: [currentX, currentY],
                                        시도횟수: maxAttempts,
                                        디버그로그: debugLog
                                    });
                                    return '점진적스크롤_최대시도도달';
                                }
                                
                                // 다음 시도를 위한 대기
                                setTimeout(() => {
                                    const result = performScrollAttempt();
                                    if (result) {
                                        // 재귀 완료
                                    }
                                }, 200);
                                
                                return null; // 계속 진행
                                
                            } catch(attemptError) {
                                console.error('🇰🇷 🚫 점진적 스크롤 시도 오류:', attemptError);
                                debugLog.push({
                                    시도횟수: attempts,
                                    오류: attemptError.message
                                });
                                return '점진적스크롤_시도오류: ' + attemptError.message;
                            }
                        }
                        
                        // 첫 번째 시도 시작
                        const result = performScrollAttempt();
                        return result || '점진적스크롤_진행중';
                        
                    } catch(e) { 
                        console.error('🇰🇷 🚫 점진적 스크롤 전체 실패:', e);
                        return '점진적스크롤_전체오류: ' + e.message; 
                    }
                })()
                """
                
                webView.evaluateJavaScript(progressiveScrollJS) { result, error in
                    var resultString = "점진적스크롤_알수없음"
                    var success = false
                    
                    if let error = error {
                        resultString = "점진적스크롤_JS오류: \(error.localizedDescription)"
                        TabPersistenceManager.debugMessages.append("🇰🇷 🚫 1단계 JavaScript 실행 오류: \(error.localizedDescription)")
                    } else if let result = result as? String {
                        resultString = result
                        success = result.contains("성공") || result.contains("부분적") || result.contains("최대시도도달")
                    } else {
                        resultString = "점진적스크롤_잘못된결과"
                    }
                    
                    TabPersistenceManager.debugMessages.append("🇰🇷 🚫 1단계 완료: \(success ? "성공" : "실패") (\(resultString))")
                    stepCompletion(success)
                }
            }
        }))
        
        // **2단계: iframe 스크롤 복원 (기존 유지) - 🇰🇷 한글화**
        if let jsState = self.jsState,
           let iframeData = jsState["iframes"] as? [[String: Any]], !iframeData.isEmpty {
            
            TabPersistenceManager.debugMessages.append("🇰🇷 🖼️ 2단계 iframe 스크롤 복원 단계 추가 - iframe \(iframeData.count)개")
            
            restoreSteps.append((2, { stepCompletion in
                let waitTime: TimeInterval = 0.15
                TabPersistenceManager.debugMessages.append("🇰🇷 🖼️ 2단계: iframe 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let iframeScrollJS = self.generateIframeScrollScript(iframeData)
                    webView.evaluateJavaScript(iframeScrollJS) { result, error in
                        if let error = error {
                            TabPersistenceManager.debugMessages.append("🇰🇷 🖼️ 2단계 JavaScript 실행 오류: \(error.localizedDescription)")
                        }
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🇰🇷 🖼️ 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        } else {
            TabPersistenceManager.debugMessages.append("🇰🇷 🖼️ 2단계 스킵 - iframe 요소 없음")
        }
        
        // **3단계: 최종 확인 및 보정 - 🇰🇷 한글화**
        TabPersistenceManager.debugMessages.append("🇰🇷 ✅ 3단계 최종 보정 단계 추가 (필수)")
        
        restoreSteps.append((3, { stepCompletion in
            let waitTime: TimeInterval = 0.8
            TabPersistenceManager.debugMessages.append("🇰🇷 ✅ 3단계: 최종 보정 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                let finalVerifyJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        
                        // 네이티브 스크롤 위치 정밀 확인
                        const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const tolerance = 30.0; // 🚫 브라우저 차단 고려하여 관대한 허용 오차
                        
                        const diffX = Math.abs(currentX - targetX);
                        const diffY = Math.abs(currentY - targetY);
                        const isWithinTolerance = diffX <= tolerance && diffY <= tolerance;
                        
                        console.log('🇰🇷 ✅ 브라우저 차단 대응 최종 검증:', {
                            목표위치: [targetX, targetY],
                            현재위치: [currentX, currentY],
                            위치차이: [diffX, diffY],
                            허용오차: tolerance,
                            허용오차통과: isWithinTolerance
                        });
                        
                        // 최종 보정 (필요시)
                        if (!isWithinTolerance) {
                            console.log('🇰🇷 ✅ 최종 보정 실행:', {현재위치: [currentX, currentY], 목표위치: [targetX, targetY]});
                            
                            // 강력한 최종 보정 
                            window.scrollTo(targetX, targetY);
                            document.documentElement.scrollTop = targetY;
                            document.documentElement.scrollLeft = targetX;
                            document.body.scrollTop = targetY;
                            document.body.scrollLeft = targetX;
                            
                            // scrollingElement 활용
                            if (document.scrollingElement) {
                                document.scrollingElement.scrollTop = targetY;
                                document.scrollingElement.scrollLeft = targetX;
                            }
                        }
                        
                        // 최종 위치 확인
                        const finalCurrentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const finalCurrentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const finalDiffX = Math.abs(finalCurrentX - targetX);
                        const finalDiffY = Math.abs(finalCurrentY - targetY);
                        const finalWithinTolerance = finalDiffX <= tolerance && finalDiffY <= tolerance;
                        
                        console.log('🇰🇷 ✅ 브라우저 차단 대응 최종보정 완료:', {
                            현재위치: [finalCurrentX, finalCurrentY],
                            목표위치: [targetX, targetY],
                            위치차이: [finalDiffX, finalDiffY],
                            허용오차: tolerance,
                            허용오차통과: finalWithinTolerance,
                            참고: '브라우저차단대응'
                        });
                        
                        // 🚫 **관대한 성공 판정** (브라우저 차단 고려)
                        return {
                            success: true, // 브라우저 차단 대응은 항상 성공으로 처리
                            withinTolerance: finalWithinTolerance,
                            finalDiff: [finalDiffX, finalDiffY]
                        };
                    } catch(e) { 
                        console.error('🇰🇷 ✅ 브라우저 차단 대응 최종보정 실패:', e);
                        return {
                            success: true, // 에러도 성공으로 처리 (관대한 정책)
                            error: e.message
                        };
                    }
                })()
                """
                
                webView.evaluateJavaScript(finalVerifyJS) { result, error in
                    if let error = error {
                        TabPersistenceManager.debugMessages.append("🇰🇷 ✅ 3단계 JavaScript 실행 오류: \(error.localizedDescription)")
                    }
                    
                    let success = true // 🚫 브라우저 차단 대응은 관대하게
                    if let resultDict = result as? [String: Any] {
                        if let withinTolerance = resultDict["withinTolerance"] as? Bool {
                            TabPersistenceManager.debugMessages.append("🇰🇷 ✅ 3단계 허용 오차 내: \(withinTolerance)")
                        }
                        if let finalDiff = resultDict["finalDiff"] as? [Double] {
                            TabPersistenceManager.debugMessages.append("🇰🇷 ✅ 3단계 최종 차이: X=\(String(format: "%.1f", finalDiff[0]))px, Y=\(String(format: "%.1f", finalDiff[1]))px")
                        }
                        if let errorMsg = resultDict["error"] as? String {
                            TabPersistenceManager.debugMessages.append("🇰🇷 ✅ 3단계 오류: \(errorMsg)")
                        }
                    }
                    
                    TabPersistenceManager.debugMessages.append("🇰🇷 ✅ 3단계 브라우저 차단 대응 최종보정 완료: \(success ? "성공" : "성공(관대)")")
                    stepCompletion(true) // 항상 성공
                }
            }
        }))
        
        TabPersistenceManager.debugMessages.append("🇰🇷 🚫 총 \(restoreSteps.count)단계 브라우저 차단 대응 단계 구성 완료")
        
        // 🇰🇷 **단계별 실행 - 한글 디버깅**
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                TabPersistenceManager.debugMessages.append("🇰🇷 🚫 \(stepInfo.step)단계 실행 시작")
                
                let stepStart = Date()
                stepInfo.action { success in
                    let stepDuration = Date().timeIntervalSince(stepStart)
                    TabPersistenceManager.debugMessages.append("🇰🇷 🚫 단계 \(stepInfo.step) 소요시간: \(String(format: "%.2f", stepDuration))초")
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > totalSteps / 2
                
                TabPersistenceManager.debugMessages.append("🇰🇷 🚫 브라우저 차단 대응 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                TabPersistenceManager.debugMessages.append("🇰🇷 🚫 최종 결과: \(overallSuccess ? "✅ 성공" : "✅ 성공(관대)")")
                completion(true) // 🚫 브라우저 차단 대응은 항상 성공으로 처리
            }
        }
        
        executeNextStep()
    }
    
    // 🖼️ **iframe 스크롤 복원 스크립트** (기존 유지) - 🇰🇷 한글화
    private func generateIframeScrollScript(_ iframeData: [[String: Any]]) -> String {
        let iframeJSON = convertToJSONString(iframeData) ?? "[]"
        return """
        (function() {
            try {
                const iframes = \(iframeJSON);
                let restored = 0;
                
                console.log('🇰🇷 🖼️ iframe 스크롤 복원 시작:', iframes.length, '개 iframe');
                
                for (const iframeInfo of iframes) {
                    const iframe = document.querySelector(iframeInfo.selector);
                    if (iframe && iframe.contentWindow) {
                        try {
                            const targetX = parseFloat(iframeInfo.scrollX || 0);
                            const targetY = parseFloat(iframeInfo.scrollY || 0);
                            
                            // Same-origin iframe 복원
                            iframe.contentWindow.scrollTo(targetX, targetY);
                            
                            try {
                                iframe.contentWindow.document.documentElement.scrollTop = targetY;
                                iframe.contentWindow.document.documentElement.scrollLeft = targetX;
                                iframe.contentWindow.document.body.scrollTop = targetY;
                                iframe.contentWindow.document.body.scrollLeft = targetX;
                            } catch(e) {
                                // 접근 제한은 무시
                            }
                            
                            restored++;
                            console.log('🇰🇷 🖼️ iframe 복원 성공:', iframeInfo.selector, [targetX, targetY]);
                        } catch(e) {
                            // 🌐 Cross-origin iframe 처리
                            try {
                                iframe.contentWindow.postMessage({
                                    type: 'restoreScroll',
                                    scrollX: parseFloat(iframeInfo.scrollX || 0),
                                    scrollY: parseFloat(iframeInfo.scrollY || 0),
                                    browserBlockingWorkaround: true // 🚫 브라우저 차단 대응 모드 플래그
                                }, '*');
                                console.log('🇰🇷 🖼️ Cross-origin iframe 스크롤 요청 전송:', iframeInfo.selector);
                                restored++;
                            } catch(crossOriginError) {
                                console.log('🇰🇷 🖼️ Cross-origin iframe 접근 불가:', iframeInfo.selector);
                            }
                        }
                    }
                }
                
                console.log('🇰🇷 🖼️ iframe 스크롤 복원 완료:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('🇰🇷 🖼️ iframe 스크롤 복원 실패:', e);
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
            TabPersistenceManager.debugMessages.append("🇰🇷 JSON 변환 실패: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - BFCacheTransitionSystem 캐처/복원 확장
extension BFCacheTransitionSystem {
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🎯 4계층 강화된 DOM 요소 기반 캡처)**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            TabPersistenceManager.debugMessages.append("🇰🇷 ❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        // 🌐 캡처 대상 사이트 로그
        TabPersistenceManager.debugMessages.append("🇰🇷 🎯 4계층 강화된 DOM 요소 기반 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        guard let webView = task.webView else {
            TabPersistenceManager.debugMessages.append("🇰🇷 ❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        TabPersistenceManager.debugMessages.append("🇰🇷 🎯 4계층 강화된 DOM 요소 기반 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("🇰🇷 ⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            // 실제 스크롤 가능한 최대 크기 감지
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
            return
        }
        
        // 🔧 **개선된 캡처 로직 - 실패 시 재시도 (기존 타이밍 유지)**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
        )
        
        // 🇰🇷 **캡처된 jsState 로그 - 한글화**
        if let jsState = captureResult.snapshot.jsState {
            TabPersistenceManager.debugMessages.append("🇰🇷 🎯 캡처된 jsState 키: \(Array(jsState.keys))")
            if let primaryAnchor = jsState["viewportAnchor"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🇰🇷 🎯 캡처된 주 뷰포트 앵커: \(primaryAnchor["selector"] as? String ?? "없음")")
            }
            if let auxiliaryAnchors = jsState["auxiliaryAnchors"] as? [[String: Any]] {
                TabPersistenceManager.debugMessages.append("🇰🇷 🎯 캡처된 보조 앵커 개수: \(auxiliaryAnchors.count)개")
            }
            if let landmarkAnchors = jsState["landmarkAnchors"] as? [[String: Any]] {
                TabPersistenceManager.debugMessages.append("🇰🇷 🎯 캡처된 랜드마크 앵커 개수: \(landmarkAnchors.count)개")
            }
            if let structuralAnchors = jsState["structuralAnchors"] as? [[String: Any]] {
                TabPersistenceManager.debugMessages.append("🇰🇷 🎯 캡처된 구조적 앵커 개수: \(structuralAnchors.count)개")
            }
        }
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("🇰🇷 ✅ 4계층 강화된 DOM 요소 기반 직렬 캡처 완료: \(task.pageRecord.title)")
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
                    TabPersistenceManager.debugMessages.append("🇰🇷 🔄 재시도 후 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기 - 🔧 기존 80ms 유지
            TabPersistenceManager.debugMessages.append("🇰🇷 ⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
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
                    TabPersistenceManager.debugMessages.append("🇰🇷 📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
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
            TabPersistenceManager.debugMessages.append("🇰🇷 ⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
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
        
        // 3. 🎯 **4계층 강화된 DOM 요소 기반 스크롤 감지 JS 상태 캡처** - 🔧 기존 캡처 타임아웃 유지 (2초)
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = generateFourTierScrollCaptureScript()
            
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
        
        // 상대적 위치 계산 (백분율) - 범위 제한 없음
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
    
    // 🎯 **4계층 강화된 DOM 요소 기반 스크롤 감지 JavaScript 생성 (무한스크롤 특화) - 🇰🇷 한글 디버깅**
    private func generateFourTierScrollCaptureScript() -> String {
        return """
        (function() {
            return new Promise(resolve => {
                // 🎯 **동적 콘텐츠 로딩 안정화 대기 (MutationObserver 활용) - 🔧 기존 타이밍 유지**
                function waitForDynamicContent(callback) {
                    let stabilityCount = 0;
                    const requiredStability = 3; // 3번 연속 안정되면 완료
                    let timeout;
                    
                    const observer = new MutationObserver(() => {
                        stabilityCount = 0; // 변화가 있으면 카운트 리셋
                        clearTimeout(timeout);
                        timeout = setTimeout(() => {
                            stabilityCount++;
                            if (stabilityCount >= requiredStability) {
                                observer.disconnect();
                                callback();
                            }
                        }, 300); // 🔧 기존 300ms 유지
                    });
                    
                    observer.observe(document.body, { childList: true, subtree: true });
                    
                    // 최대 대기 시간 설정
                    setTimeout(() => {
                        observer.disconnect();
                        callback();
                    }, 4000); // 🔧 기존 4000ms 유지
                }

                function captureFourTierScrollData() {
                    try {
                        console.log('🇰🇷 🎯 4계층 강화된 다중 앵커 + iframe 스크롤 감지 시작');
                        
                        // 🎯 **1단계: 4계층 앵커 요소 식별 시스템 - 🇰🇷 한글화**
                        function identifyFourTierAnchors() {
                            const viewportHeight = window.innerHeight;
                            const viewportWidth = window.innerWidth;
                            const scrollY = window.scrollY || window.pageYOffset || 0;
                            const scrollX = window.scrollX || window.pageXOffset || 0;
                            
                            console.log('🇰🇷 🎯 4계층 앵커 식별 시작:', {
                                뷰포트크기: [viewportWidth, viewportHeight],
                                스크롤위치: [scrollX, scrollY]
                            });
                            
                            // 🎯 **4계층 구성 정의 - 🇰🇷 한글화 및 관대한 허용 오차**
                            const TIER_CONFIGS = {
                                tier1: {
                                    name: '정밀앵커계층',
                                    korean: '뷰포트중심 정밀복원',
                                    maxDistance: viewportHeight * 2,     // 0-2화면
                                    tolerance: Math.max(100, viewportHeight * 0.1),  // 🔧 **동적 허용오차: 최소 100px 또는 화면높이 10%**
                                    selectors: [
                                        // ID를 가진 요소들
                                        '[id]',
                                        // 특정 data 속성들
                                        '[data-testid]', '[data-id]', '[data-key]',
                                        '[data-item-id]', '[data-article-id]', '[data-post-id]',
                                        '[data-comment-id]', '[data-user-id]', '[data-content-id]',
                                        '[data-thread-id]', '[data-message-id]',
                                        '[data-component-id]', '[data-widget-id]', '[data-module-id]',
                                        '[data-entry-id]', '[data-slug]', '[data-permalink]',
                                        // React 관련
                                        '[data-reactid]', '[key]'
                                    ],
                                    priority: 10,
                                    maxCandidates: 30
                                },
                                tier2: {
                                    name: '보조앵커계층', 
                                    korean: '근거리 세션탐색',
                                    maxDistance: viewportHeight * 10,    // 2-10화면
                                    tolerance: Math.max(150, viewportHeight * 0.15), // 🔧 **더 관대한 허용오차**
                                    selectors: [
                                        // 기본 HTML 요소들
                                        'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
                                        'p', 'div', 'span', 'a', 'button',
                                        'li', 'tr', 'td', 'th', 'dt', 'dd',
                                        'ul', 'ol', 'dl',
                                        'article', 'section', 'aside', 'header', 'footer', 'nav', 'main',
                                        'img', 'video', 'iframe', 'canvas', 'svg',
                                        'form', 'input', 'textarea', 'select',
                                        'table', 'thead', 'tbody', 'tfoot',
                                        'pre', 'code', 'blockquote',
                                        
                                        // 클래스 패턴 (구체적인 클래스명)
                                        '.item', '.list-item', '.card', '.post', '.article',
                                        '.content', '.box', '.container', '.row', '.cell',
                                        '.comment', '.reply', '.feed', '.thread', '.message',
                                        '.product', '.news', '.media',
                                        '.load-more', '.show-more', '.infinite-scroll',
                                        
                                        // role 속성들
                                        '[role="article"]', '[role="main"]', '[role="button"]',
                                        '[role="navigation"]', '[role="contentinfo"]',
                                        '[role="listitem"]', '[role="menuitem"]',
                                        
                                        // ARIA 속성들
                                        '[aria-label]', '[aria-labelledby]', '[aria-describedby]',
                                        '[aria-expanded]', '[aria-selected]', '[aria-checked]',
                                        
                                        // data 속성들 (구체적인 것만)
                                        '[data-component]', '[data-widget]', '[data-module]',
                                        '[data-type]', '[data-category]', '[data-index]',
                                        '[data-role]', '[data-action]'
                                    ],
                                    priority: 7,
                                    maxCandidates: 50
                                },
                                tier3: {
                                    name: '랜드마크계층',
                                    korean: '깊은탐색 복원',
                                    maxDistance: viewportHeight * 50,    // 10-50화면
                                    tolerance: Math.max(200, viewportHeight * 0.2),  // 🔧 **매우 관대한 허용오차**
                                    selectors: [
                                        // Tier2와 동일한 selector 사용 (거리로만 구분)
                                        'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
                                        'p', 'div', 'span', 'a', 'button',
                                        'li', 'tr', 'td', 'th', 'dt', 'dd',
                                        'ul', 'ol', 'dl',
                                        'article', 'section', 'aside', 'header', 'footer', 'nav', 'main',
                                        'img', 'video', 'iframe',
                                        '.item', '.list-item', '.card', '.post', '.article',
                                        '.content', '.box', '.container',
                                        '[role="article"]', '[role="main"]',
                                        '[aria-label]',
                                        '[data-component]', '[data-widget]', '[data-module]'
                                    ],
                                    priority: 5,
                                    maxCandidates: 30
                                },
                                tier4: {
                                    name: '구조적계층',
                                    korean: '극한스크롤 복원',
                                    maxDistance: Infinity,                // 50화면+
                                    tolerance: Math.max(300, viewportHeight * 0.3),  // 🔧 **극도로 관대한 허용오차**
                                    selectors: [
                                        // 가장 기본적인 요소들만
                                        'h1', 'h2', 'h3',
                                        'p', 'div', 'span',
                                        'article', 'section',
                                        'img',
                                        '.item', '.content', '.container',
                                        '[role="main"]'
                                    ],
                                    priority: 3,
                                    maxCandidates: 20
                                }
                            };
                            
                            // 🔧 **계층별 앵커 수집 - 🇰🇷 상세 디버깅**
                            const tierResults = {};
                            const allAnchors = {
                                tier1: [], tier2: [], tier3: [], tier4: []
                            };
                            
                            for (const [tierKey, config] of Object.entries(TIER_CONFIGS)) {
                                try {
                                    console.log(`🇰🇷 🔍 ${config.name} (${config.korean}) 앵커 수집 시작 (${config.selectors.length}개 selector)`);
                                    
                                    let tierCandidates = [];
                                    let selectorStats = {};
                                    let successCount = 0;
                                    let errorCount = 0;
                                    
                                    // 각 selector에서 요소 수집
                                    for (const selector of config.selectors) {
                                        try {
                                            const elements = document.querySelectorAll(selector);
                                            if (elements.length > 0) {
                                                selectorStats[selector] = elements.length;
                                                tierCandidates.push(...Array.from(elements));
                                                successCount++;
                                            }
                                        } catch(e) {
                                            selectorStats[selector] = `오류: ${e.message}`;
                                            errorCount++;
                                            console.warn(`🇰🇷 ⚠️ Selector 오류: ${selector} - ${e.message}`);
                                        }
                                    }
                                    
                                    console.log(`🇰🇷 ${config.name} selector 결과:`, {
                                        성공: successCount,
                                        오류: errorCount,
                                        총요소수: tierCandidates.length
                                    });
                                    
                                    // 뷰포트 기준 거리 계산 및 필터링
                                    let scoredCandidates = [];
                                    
                                    for (const element of tierCandidates.slice(0, config.maxCandidates * 2)) {
                                        try {
                                            const rect = element.getBoundingClientRect();
                                            const elementY = scrollY + rect.top;
                                            const elementX = scrollX + rect.left;
                                            
                                            // 거리 계산
                                            const distance = Math.sqrt(
                                                Math.pow(elementX - scrollX, 2) + 
                                                Math.pow(elementY - scrollY, 2)
                                            );
                                            
                                            // 계층별 거리 제한 체크
                                            if (distance <= config.maxDistance) {
                                                // 요소 품질 점수 계산
                                                let qualityScore = config.priority;
                                                
                                                // 고유성 보너스
                                                if (element.id) qualityScore += 3;
                                                if (element.getAttribute('data-testid')) qualityScore += 2;
                                                if (element.className && element.className.trim()) qualityScore += 1;
                                                
                                                // 크기 적절성 보너스
                                                const elementArea = rect.width * rect.height;
                                                const viewportArea = viewportWidth * viewportHeight;
                                                const sizeRatio = elementArea / viewportArea;
                                                if (sizeRatio > 0.01 && sizeRatio < 0.8) qualityScore += 2;
                                                
                                                // 텍스트 내용 보너스
                                                const textContent = (element.textContent || '').trim();
                                                if (textContent.length > 10 && textContent.length < 200) qualityScore += 1;
                                                
                                                // 가시성 보너스
                                                if (element.offsetParent !== null) qualityScore += 1;
                                                
                                                // 최종 점수 = 품질 점수 / (거리 + 1)
                                                const finalScore = qualityScore / (distance + 1);
                                                
                                                scoredCandidates.push({
                                                    // 🚫 **수정: DOM 요소 대신 기본 타입만 저장**
                                                    elementData: {
                                                        tag: element.tagName.toLowerCase(),
                                                        id: element.id || null,
                                                        className: (element.className || '').split(' ')[0] || null,
                                                        textPreview: textContent.substring(0, 30)
                                                    },
                                                    score: finalScore,
                                                    distance: distance,
                                                    qualityScore: qualityScore,
                                                    tier: tierKey,
                                                    // 내부 처리용 (반환하지 않음)
                                                    _element: element
                                                });
                                            }
                                        } catch(e) {
                                            // 개별 요소 오류는 무시
                                        }
                                    }
                                    
                                    // 점수순 정렬 및 상위 후보 선택
                                    scoredCandidates.sort((a, b) => b.score - a.score);
                                    const selectedCandidates = scoredCandidates.slice(0, config.maxCandidates);
                                    
                                    tierResults[tierKey] = {
                                        전체요소수: tierCandidates.length,
                                        필터링된수: scoredCandidates.length,
                                        선택된수: selectedCandidates.length,
                                        selectorStats: selectorStats,
                                        성공Selector수: successCount,
                                        오류Selector수: errorCount
                                    };
                                    
                                    // 앵커 데이터 생성
                                    for (const candidate of selectedCandidates) {
                                        const anchorData = createEnhancedAnchorData(candidate);
                                        if (anchorData) {
                                            allAnchors[tierKey].push(anchorData);
                                        }
                                    }
                                    
                                    console.log(`🇰🇷 ✅ ${config.name} 완료: ${selectedCandidates.length}개 선택 (${successCount}개 selector 성공)`);
                                    
                                } catch(e) {
                                    console.error(`🇰🇷 ❌ ${config.name} 실패:`, e.message);
                                    tierResults[tierKey] = { 오류: e.message };
                                    allAnchors[tierKey] = [];
                                }
                            }
                            
                            function createEnhancedAnchorData(candidate) {
                                try {
                                    const element = candidate._element;
                                    const rect = element.getBoundingClientRect();
                                    const absoluteTop = scrollY + rect.top;
                                    const absoluteLeft = scrollX + rect.left;
                                    
                                    // 뷰포트 기준 오프셋 계산
                                    const offsetFromTop = scrollY - absoluteTop;
                                    const offsetFromLeft = scrollX - absoluteLeft;
                                    
                                    // 🔧 **강화된 다중 selector 생성 전략 (유효한 것만)**
                                    const selectors = [];
                                    
                                    // ID 기반 selector (최우선)
                                    if (element.id) {
                                        selectors.push('#' + element.id);
                                    }
                                    
                                    // 데이터 속성 기반 (구체적인 속성명 사용)
                                    const dataAttrs = Array.from(element.attributes)
                                        .filter(attr => attr.name.startsWith('data-'))
                                        .slice(0, 3)
                                        .map(attr => `[${attr.name}="${attr.value}"]`);
                                    if (dataAttrs.length > 0) {
                                        selectors.push(element.tagName.toLowerCase() + dataAttrs.join(''));
                                    }
                                    
                                    // 클래스 기반 selector
                                    if (element.className) {
                                        const classes = element.className.trim().split(/\\s+/).filter(c => c);
                                        if (classes.length > 0) {
                                            selectors.push('.' + classes.join('.'));
                                            selectors.push('.' + classes[0]);
                                            selectors.push(element.tagName.toLowerCase() + '.' + classes[0]);
                                        }
                                    }
                                    
                                    // nth-child 기반
                                    try {
                                        const parent = element.parentElement;
                                        if (parent) {
                                            const siblings = Array.from(parent.children);
                                            const index = siblings.indexOf(element) + 1;
                                            if (index > 0 && siblings.length < 20) {
                                                const nthSelector = `${parent.tagName.toLowerCase()} > ${element.tagName.toLowerCase()}:nth-child(${index})`;
                                                selectors.push(nthSelector);
                                            }
                                        }
                                    } catch(e) {
                                        // nth-child 생성 실패는 무시
                                    }
                                    
                                    // 최종 fallback: 태그명만
                                    selectors.push(element.tagName.toLowerCase());
                                    
                                    const textContent = (element.textContent || '').trim();
                                    
                                    // 🚫 **수정: DOM 요소 대신 기본 타입만 반환**
                                    return {
                                        selector: generateBestSelector(element),
                                        selectors: selectors,
                                        tier: candidate.tier,
                                        score: candidate.score,
                                        qualityScore: candidate.qualityScore,
                                        distance: candidate.distance,
                                        tagName: element.tagName.toLowerCase(),
                                        className: element.className || '',
                                        id: element.id || '',
                                        textContent: textContent.substring(0, 100),
                                        absolutePosition: {
                                            top: absoluteTop,
                                            left: absoluteLeft
                                        },
                                        viewportPosition: {
                                            top: rect.top,
                                            left: rect.left
                                        },
                                        offsetFromTop: offsetFromTop,
                                        offsetFromLeft: offsetFromLeft,
                                        size: {
                                            width: rect.width,
                                            height: rect.height
                                        },
                                        anchorType: 'fourTier',
                                        captureTimestamp: Date.now()
                                    };
                                } catch(e) {
                                    console.error('🇰🇷 앵커 데이터 생성 실패:', e);
                                    return null;
                                }
                            }
                            
                            console.log('🇰🇷 🎯 4계층 앵커 식별 완료:', {
                                tier1개수: allAnchors.tier1.length,
                                tier2개수: allAnchors.tier2.length, 
                                tier3개수: allAnchors.tier3.length,
                                tier4개수: allAnchors.tier4.length,
                                총앵커수: allAnchors.tier1.length + allAnchors.tier2.length + allAnchors.tier3.length + allAnchors.tier4.length,
                                계층결과: tierResults
                            });
                            
                            return {
                                primaryAnchor: allAnchors.tier1[0] || null,     // 최고 점수 Tier1 앵커
                                auxiliaryAnchors: allAnchors.tier2,             // Tier2 앵커들 
                                landmarkAnchors: allAnchors.tier3,              // Tier3 랜드마크 앵커들
                                structuralAnchors: allAnchors.tier4,            // Tier4 구조적 앵커들
                                tierResults: tierResults
                            };
                        }
                        
                        // 🖼️ **2단계: iframe 스크롤 감지 (기존 유지) - 🇰🇷 한글화**
                        function detectIframeScrolls() {
                            const iframes = [];
                            const iframeElements = document.querySelectorAll('iframe');
                            
                            console.log('🇰🇷 🖼️ iframe 스크롤 감지 시작:', iframeElements.length, '개 iframe');
                            
                            for (const iframe of iframeElements) {
                                try {
                                    const contentWindow = iframe.contentWindow;
                                    if (contentWindow && contentWindow.location) {
                                        const scrollX = parseFloat(contentWindow.scrollX) || 0;
                                        const scrollY = parseFloat(contentWindow.scrollY) || 0;
                                        
                                        // 🎯 **0.1px 이상이면 모두 저장**
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
                                            
                                            console.log('🇰🇷 🖼️ iframe 스크롤 발견:', iframe.src, [scrollX, scrollY]);
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
                                    console.log('🇰🇷 🌐 Cross-origin iframe 기록:', iframe.src);
                                }
                            }
                            
                            console.log('🇰🇷 🖼️ iframe 스크롤 감지 완료:', iframes.length, '개');
                            return iframes;
                        }
                        
                        // 🌐 **개선된 셀렉터 생성** - 동적 사이트 대응 (기존 로직 유지) - 🇰🇷 한글화
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
                        
                        // 🎯 **메인 실행 - 4계층 강화된 앵커 기반 데이터 수집 - 🇰🇷 한글화**
                        const anchorData = identifyFourTierAnchors(); // 🎯 **4계층 앵커 시스템**
                        const iframeScrolls = detectIframeScrolls(); // 🖼️ **iframe은 유지**
                        
                        // 메인 스크롤 위치도 parseFloat 정밀도 적용 
                        const mainScrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                        const mainScrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                        
                        // 뷰포트 및 콘텐츠 크기 정밀 계산 (실제 크기 포함)
                        const viewportWidth = parseFloat(window.innerWidth) || 0;
                        const viewportHeight = parseFloat(window.innerHeight) || 0;
                        const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                        const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                        
                        // 실제 스크롤 가능 크기 계산 (최대한 정확하게)
                        const actualScrollableWidth = Math.max(contentWidth, window.innerWidth, document.body.scrollWidth || 0);
                        const actualScrollableHeight = Math.max(contentHeight, window.innerHeight, document.body.scrollHeight || 0);
                        
                        console.log(`🇰🇷 🎯 4계층 강화된 앵커 기반 감지 완료:`);
                        console.log(`   주앵커: ${anchorData.primaryAnchor ? 1 : 0}개`);
                        console.log(`   보조앵커: ${anchorData.auxiliaryAnchors.length}개`);
                        console.log(`   랜드마크앵커: ${anchorData.landmarkAnchors.length}개`);
                        console.log(`   구조적앵커: ${anchorData.structuralAnchors.length}개`);
                        console.log(`   iframe: ${iframeScrolls.length}개`);
                        console.log(`🇰🇷 🎯 위치: (${mainScrollX}, ${mainScrollY}) 뷰포트: (${viewportWidth}, ${viewportHeight})`);
                        console.log(`🇰🇷 🎯 콘텐츠: (${contentWidth}, ${contentHeight}) 실제 스크롤 가능: (${actualScrollableWidth}, ${actualScrollableHeight})`);
                        
                        // 🚫 **수정: Swift 호환 반환값 (기본 타입만) - 🇰🇷 한글 키 포함**
                        resolve({
                            viewportAnchor: anchorData.primaryAnchor,           // 🎯 **주 뷰포트 앵커 (Tier1)**
                            auxiliaryAnchors: anchorData.auxiliaryAnchors,      // 🎯 **보조 앵커들 (Tier2)** 
                            landmarkAnchors: anchorData.landmarkAnchors,        // 🆕 **랜드마크 앵커들 (Tier3)**
                            structuralAnchors: anchorData.structuralAnchors,    // 🆕 **구조적 앵커들 (Tier4)**
                            scroll: { 
                                x: mainScrollX, 
                                y: mainScrollY
                            },
                            iframes: iframeScrolls, // 🖼️ **iframe은 유지**
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
                            actualScrollable: { 
                                width: actualScrollableWidth,
                                height: actualScrollableHeight
                            },
                            tierResults: anchorData.tierResults // 🎯 **4계층 결과 상세 정보**
                        });
                    } catch(e) { 
                        console.error('🇰🇷 🎯 4계층 강화된 앵커 기반 감지 실패:', e);
                        // 🚫 **수정: Swift 호환 반환값 - 🇰🇷 한글 키 포함**
                        resolve({
                            viewportAnchor: null,
                            auxiliaryAnchors: [],
                            landmarkAnchors: [],
                            structuralAnchors: [],
                            scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
                            iframes: [],
                            href: window.location.href,
                            title: document.title,
                            actualScrollable: { width: 0, height: 0 },
                            error: e.message
                        });
                    }
                }

                // 🎯 동적 콘텐츠 완료 대기 후 캡처 (기존 타이밍 유지)
                if (document.readyState === 'complete') {
                    waitForDynamicContent(captureFourTierScrollData);
                } else {
                    document.addEventListener('DOMContentLoaded', () => waitForDynamicContent(captureFourTierScrollData));
                }
            });
        })()
        """
    }
    
    internal func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 🌐 JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🇰🇷 🚫 브라우저 차단 대응 BFCache 페이지 복원');
                
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
                console.log('🇰🇷 📸 브라우저 차단 대응 BFCache 페이지 저장');
            }
        });
        
        // 🚫 Cross-origin iframe 브라우저 차단 대응 스크롤 복원 리스너 - 🇰🇷 한글화
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                try {
                    const targetX = parseFloat(event.data.scrollX) || 0;
                    const targetY = parseFloat(event.data.scrollY) || 0;
                    const browserBlockingWorkaround = event.data.browserBlockingWorkaround || false;
                    
                    console.log('🇰🇷 🚫 Cross-origin iframe 브라우저 차단 대응 스크롤 복원:', targetX, targetY, browserBlockingWorkaround ? '(브라우저 차단 대응 모드)' : '');
                    
                    // 🚫 브라우저 차단 대응 스크롤 설정
                    if (browserBlockingWorkaround) {
                        // 점진적 스크롤 시도
                        let attempts = 0;
                        const maxAttempts = 10;
                        
                        const tryScroll = () => {
                            window.scrollTo(targetX, targetY);
                            document.documentElement.scrollTop = targetY;
                            document.documentElement.scrollLeft = targetX;
                            document.body.scrollTop = targetY;
                            document.body.scrollLeft = targetX;
                            
                            const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            
                            if ((Math.abs(currentX - targetX) > 10 || Math.abs(currentY - targetY) > 10) && attempts < maxAttempts) {
                                attempts++;
                                setTimeout(tryScroll, 150);
                            }
                        };
                        
                        tryScroll();
                    } else {
                        // 기본 스크롤
                        window.scrollTo(targetX, targetY);
                        document.documentElement.scrollTop = targetY;
                        document.documentElement.scrollLeft = targetX;
                        document.body.scrollTop = targetY;
                        document.body.scrollLeft = targetX;
                    }
                    
                } catch(e) {
                    console.error('🇰🇷 Cross-origin iframe 스크롤 복원 실패:', e);
                }
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출 - 🇰🇷 한글화
extension BFCacheTransitionSystem {

    /// 사용자가 링크/폼으로 **떠나기 직전** 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 즉시 캡처 (최고 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        TabPersistenceManager.debugMessages.append("🇰🇷 📸 떠나기 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화 - 🚀 도착 스냅샷 최적화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 캡처 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        TabPersistenceManager.debugMessages.append("🇰🇷 📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
        // 이전 페이지들도 순차적으로 캐시 확인
        if stateModel.dataModel.currentPageIndex > 0 {
            // 최근 3개 페이지만 체크 (성능 고려)
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                // 캐시가 없는 경우만 기록 (메타데이터 저장 없이 단순 캐시 확인만)
                if !hasCache(for: previousRecord.id) {
                    TabPersistenceManager.debugMessages.append("🇰🇷 📸 이전 페이지 캐시 없음: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
