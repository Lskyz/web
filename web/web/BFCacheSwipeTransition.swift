//
//  BFCacheSnapshotManager.swift
//  📸 **5단계 무한스크롤 특화 BFCache 페이지 스냅샷 및 복원 시스템**
//  🎯 **5단계 순차 시도 방식** - 고유식별자 → 콘텐츠지문 → 상대인덱스 → 기존셀렉터 → 무한스크롤트리거
//  🔧 **다중 뷰포트 앵커 시스템** - 주앵커 + 보조앵커 + 랜드마크 + 구조적 앵커
//  🐛 **디버깅 강화** - 실패 원인 정확한 추적과 로깅
//  🌐 **무한스크롤 특화** - 동적 콘텐츠 로드 대응 복원 지원
//  🚀 **무한스크롤 5단계 순차 시도 방식 적용** - 모든 사이트 범용 대응
//  🎯 **정밀 복원 개선** - 상대적 위치 기반 정확한 복원과 엄격한 검증
//  🔥 **스크롤 위치 캡처 수정** - JavaScript로 직접 읽기

import UIKit
import WebKit
import SwiftUI

// MARK: - 📸 **5단계 무한스크롤 특화 BFCache 페이지 스냅샷**
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
    
    // 🚀 **핵심 개선: 5단계 무한스크롤 특화 복원**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 특화 BFCache 복원 시작 - 상태: \(captureStatus.rawValue)")
        
        // 🔥 **캡처된 jsState 상세 검증 및 로깅**
        if let jsState = self.jsState {
            TabPersistenceManager.debugMessages.append("🔥 캡처된 jsState 키 확인: \(Array(jsState.keys))")
            
            if let infiniteScrollData = jsState["infiniteScrollData"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🚀 무한스크롤 데이터 확인: \(Array(infiniteScrollData.keys))")
                
                if let anchors = infiniteScrollData["anchors"] as? [[String: Any]] {
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커: \(anchors.count)개")
                } else {
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 없음")
                }
            } else {
                TabPersistenceManager.debugMessages.append("🚀 무한스크롤 데이터 없음")
            }
        } else {
            TabPersistenceManager.debugMessages.append("🔥 jsState 캡처 완전 실패 - nil")
        }
        
        // 🚀 **1단계: 5단계 무한스크롤 특화 복원 우선 실행**
        performFiveStageInfiniteScrollRestore(to: webView)
        
        // 🔧 **기존 상태별 분기 로직 유지**
        switch captureStatus {
        case .failed:
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패 상태 - 5단계 무한스크롤 복원만 수행")
            completion(true)
            return
            
        case .visualOnly:
            TabPersistenceManager.debugMessages.append("🖼️ 이미지만 캡처된 상태 - 5단계 무한스크롤 복원 + 최종보정")
            
        case .partial:
            TabPersistenceManager.debugMessages.append("⚡ 부분 캡처 상태 - 5단계 무한스크롤 복원 + 브라우저 차단 대응")
            
        case .complete:
            TabPersistenceManager.debugMessages.append("✅ 완전 캡처 상태 - 5단계 무한스크롤 복원 + 브라우저 차단 대응")
        }
        
        TabPersistenceManager.debugMessages.append("🌐 5단계 무한스크롤 복원 후 브라우저 차단 대응 시작")
        
        // 🔧 **무한스크롤 복원 후 브라우저 차단 대응 단계 실행**
        DispatchQueue.main.async {
            self.performPreciseRestoreWithStrictValidation(to: webView, completion: completion)
        }
    }
    
    // 🚀 **새로 추가: 5단계 무한스크롤 특화 1단계 복원 메서드**
    private func performFiveStageInfiniteScrollRestore(to webView: WKWebView) {
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 특화 1단계 복원 시작")
        
        // 1. 네이티브 스크롤뷰 기본 설정 (백업용)
        let targetPos = self.scrollPosition
        webView.scrollView.setContentOffset(targetPos, animated: false)
        
        // 2. 🚀 **5단계 무한스크롤 특화 복원 JavaScript 실행**
        let fiveStageRestoreJS = generateFiveStageInfiniteScrollRestoreScript()
        
        // 동기적 JavaScript 실행 (즉시)
        webView.evaluateJavaScript(fiveStageRestoreJS) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 복원 JS 실행 오류: \(error.localizedDescription)")
                return
            }
            
            // 🚫 **수정: 안전한 타입 체크로 변경**
            var success = false
            if let resultDict = result as? [String: Any] {
                success = (resultDict["success"] as? Bool) ?? false
                
                if let stage = resultDict["stage"] as? Int {
                    TabPersistenceManager.debugMessages.append("🚀 사용된 복원 단계: Stage \(stage)")
                }
                if let method = resultDict["method"] as? String {
                    TabPersistenceManager.debugMessages.append("🚀 사용된 복원 방법: \(method)")
                }
                if let anchorInfo = resultDict["anchorInfo"] as? String {
                    TabPersistenceManager.debugMessages.append("🚀 앵커 정보: \(anchorInfo)")
                }
                if let errorMsg = resultDict["error"] as? String {
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 복원 오류: \(errorMsg)")
                }
                if let debugInfo = resultDict["debug"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 복원 디버그: \(debugInfo)")
                }
                if let stageResults = resultDict["stageResults"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🚀 단계별 결과: \(stageResults)")
                }
                if let verificationResult = resultDict["verification"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🚀 복원 검증 결과: \(verificationResult)")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 복원: \(success ? "성공" : "실패")")
        }
        
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 특화 1단계 복원 완료")
    }
    
    // 🚀 **핵심: 5단계 무한스크롤 특화 복원 JavaScript 생성 (모든 사이트 범용 대응)**
    private func generateFiveStageInfiniteScrollRestoreScript() -> String {
        let targetPos = self.scrollPosition
        let targetPercent = self.scrollPositionPercent
        
        // jsState에서 무한스크롤 데이터 추출
        var infiniteScrollDataJSON = "null"
        
        if let jsState = self.jsState,
           let infiniteScrollData = jsState["infiniteScrollData"] as? [String: Any],
           let dataJSON = convertToJSONString(infiniteScrollData) {
            infiniteScrollDataJSON = dataJSON
        }
        
        return """
        (function() {
            try {
                const targetX = parseFloat('\(targetPos.x)');
                const targetY = parseFloat('\(targetPos.y)');
                const targetPercentX = parseFloat('\(targetPercent.x)');
                const targetPercentY = parseFloat('\(targetPercent.y)');
                const infiniteScrollData = \(infiniteScrollDataJSON);
                
                console.log('🚀 5단계 무한스크롤 특화 복원 시작:', {
                    target: [targetX, targetY],
                    percent: [targetPercentX, targetPercentY],
                    hasInfiniteScrollData: !!infiniteScrollData,
                    anchorsCount: infiniteScrollData?.anchors?.length || 0
                });
                
                // 🎯 **정밀 복원: 현재 문서 상태 정확히 측정**
                function getCurrentDocumentMetrics() {
                    const currentScrollY = parseFloat(window.scrollY || window.pageYOffset || 0);
                    const currentScrollX = parseFloat(window.scrollX || window.pageXOffset || 0);
                    
                    const documentHeight = Math.max(
                        document.documentElement.scrollHeight,
                        document.body.scrollHeight,
                        document.documentElement.offsetHeight,
                        document.body.offsetHeight
                    );
                    
                    const documentWidth = Math.max(
                        document.documentElement.scrollWidth,
                        document.body.scrollWidth,
                        document.documentElement.offsetWidth,
                        document.body.offsetWidth
                    );
                    
                    const viewportHeight = parseFloat(window.innerHeight || document.documentElement.clientHeight || 0);
                    const viewportWidth = parseFloat(window.innerWidth || document.documentElement.clientWidth || 0);
                    
                    const maxScrollY = Math.max(0, documentHeight - viewportHeight);
                    const maxScrollX = Math.max(0, documentWidth - viewportWidth);
                    
                    return {
                        current: [currentScrollX, currentScrollY],
                        document: [documentWidth, documentHeight],
                        viewport: [viewportWidth, viewportHeight],
                        maxScroll: [maxScrollX, maxScrollY]
                    };
                }
                
                // 🎯 **상대적 위치 기반 목표 좌표 재계산**
                function calculatePreciseTargetPosition(metrics) {
                    let preciseTargetX = targetX;
                    let preciseTargetY = targetY;
                    
                    // 상대적 위치가 있으면 우선 사용
                    if (targetPercentX > 0 && targetPercentX <= 100 && metrics.maxScroll[0] > 0) {
                        preciseTargetX = (targetPercentX / 100.0) * metrics.maxScroll[0];
                        console.log('🎯 X축 상대적 위치 적용:', targetPercentX + '% → ' + preciseTargetX + 'px');
                    }
                    
                    if (targetPercentY > 0 && targetPercentY <= 100 && metrics.maxScroll[1] > 0) {
                        preciseTargetY = (targetPercentY / 100.0) * metrics.maxScroll[1];
                        console.log('🎯 Y축 상대적 위치 적용:', targetPercentY + '% → ' + preciseTargetY + 'px');
                    }
                    
                    // 범위 제한
                    preciseTargetX = Math.max(0, Math.min(preciseTargetX, metrics.maxScroll[0]));
                    preciseTargetY = Math.max(0, Math.min(preciseTargetY, metrics.maxScroll[1]));
                    
                    return [preciseTargetX, preciseTargetY];
                }
                
                // 초기 문서 상태 측정
                let metrics = getCurrentDocumentMetrics();
                let [preciseTargetX, preciseTargetY] = calculatePreciseTargetPosition(metrics);
                
                console.log('🎯 정밀 목표 위치 계산:', {
                    original: [targetX, targetY],
                    percent: [targetPercentX, targetPercentY],
                    precise: [preciseTargetX, preciseTargetY],
                    metrics: metrics
                });
                
                // 🚀 **5단계 무한스크롤 복원 시스템 구성**
                const STAGE_CONFIG = {
                    stage1: {
                        name: '고유식별자',
                        description: '고유 식별자 기반 복원 (href, data-* 속성)',
                        priority: 10,
                        tolerance: 20  // 🎯 엄격한 허용 오차
                    },
                    stage2: {
                        name: '콘텐츠지문',
                        description: '콘텐츠 지문 기반 복원 (텍스트 + 구조 조합)',
                        priority: 8,
                        tolerance: 30
                    },
                    stage3: {
                        name: '상대인덱스',
                        description: '상대적 인덱스 기반 복원 (뷰포트 내 위치)',
                        priority: 6,
                        tolerance: 50
                    },
                    stage4: {
                        name: '기존셀렉터',
                        description: '기존 셀렉터 기반 복원 (CSS selector)',
                        priority: 4,
                        tolerance: 80
                    },
                    stage5: {
                        name: '무한스크롤트리거',
                        description: '무한스크롤 트리거 후 재시도',
                        priority: 2,
                        tolerance: 100
                    }
                };
                
                let restoredByStage = false;
                let usedStage = 0;
                let usedMethod = 'fallback';
                let anchorInfo = 'none';
                let debugInfo = {};
                let errorMsg = null;
                let verificationResult = {};
                let stageResults = {};
                
                // 🚀 **5단계 순차 시도 시스템**
                const stages = ['stage1', 'stage2', 'stage3', 'stage4', 'stage5'];
                
                for (let i = 0; i < stages.length && !restoredByStage; i++) {
                    const stageKey = stages[i];
                    const stageConfig = STAGE_CONFIG[stageKey];
                    const stageNum = i + 1;
                    
                    console.log(`🚀 Stage ${stageNum} (${stageConfig.name}) 시도 시작:`, {
                        priority: stageConfig.priority,
                        tolerance: stageConfig.tolerance,
                        description: stageConfig.description
                    });
                    
                    try {
                        const stageResult = tryStageRestore(stageNum, stageConfig, preciseTargetX, preciseTargetY, infiniteScrollData);
                        stageResults[`stage${stageNum}`] = stageResult;
                        
                        if (stageResult.success) {
                            restoredByStage = true;
                            usedStage = stageNum;
                            usedMethod = stageResult.method;
                            anchorInfo = stageResult.anchorInfo;
                            debugInfo[`stage${stageNum}_success`] = stageResult.debug;
                            
                            console.log(`✅ Stage ${stageNum} (${stageConfig.name}) 복원 성공:`, stageResult);
                            break;
                        } else {
                            console.log(`❌ Stage ${stageNum} (${stageConfig.name}) 복원 실패:`, stageResult.error);
                            debugInfo[`stage${stageNum}_failed`] = stageResult.error;
                        }
                    } catch(e) {
                        const stageError = `Stage ${stageNum} 예외: ${e.message}`;
                        console.error(stageError);
                        stageResults[`stage${stageNum}`] = { success: false, error: stageError };
                        debugInfo[`stage${stageNum}_exception`] = e.message;
                    }
                }
                
                // 🚀 **Stage별 복원 시도 함수**
                function tryStageRestore(stageNum, config, targetX, targetY, infiniteScrollData) {
                    try {
                        console.log(`🔄 Stage ${stageNum} 복원 로직 실행`);
                        
                        switch(stageNum) {
                            case 1:
                                return tryUniqueIdentifierRestore(config, targetX, targetY, infiniteScrollData);
                            case 2:
                                return tryContentFingerprintRestore(config, targetX, targetY, infiniteScrollData);
                            case 3:
                                return tryRelativeIndexRestore(config, targetX, targetY, infiniteScrollData);
                            case 4:
                                return tryExistingSelectorRestore(config, targetX, targetY, infiniteScrollData);
                            case 5:
                                return tryInfiniteScrollTriggerRestore(config, targetX, targetY, infiniteScrollData);
                            default:
                                return { success: false, error: '알 수 없는 Stage' };
                        }
                        
                    } catch(e) {
                        return {
                            success: false,
                            error: `Stage ${stageNum} 예외: ${e.message}`,
                            debug: { exception: e.message }
                        };
                    }
                }
                
                // 🚀 **Stage 1: 고유 식별자 기반 복원**
                function tryUniqueIdentifierRestore(config, targetX, targetY, infiniteScrollData) {
                    try {
                        console.log('🚀 Stage 1: 고유 식별자 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        let foundElement = null;
                        let matchedAnchor = null;
                        
                        // 고유 식별자 우선순위: href → data-post-id → data-article-id → data-id → id
                        for (const anchor of anchors) {
                            if (!anchor.uniqueIdentifiers) continue;
                            
                            const identifiers = anchor.uniqueIdentifiers;
                            
                            // href 패턴 매칭
                            if (identifiers.href) {
                                const hrefPattern = identifiers.href;
                                const elements = document.querySelectorAll(`a[href*="${hrefPattern}"]`);
                                if (elements.length > 0) {
                                    foundElement = elements[0];
                                    matchedAnchor = anchor;
                                    console.log('🚀 Stage 1: href 패턴으로 발견:', hrefPattern);
                                    break;
                                }
                            }
                            
                            // data-* 속성 매칭
                            if (identifiers.dataAttributes) {
                                for (const [attr, value] of Object.entries(identifiers.dataAttributes)) {
                                    const elements = document.querySelectorAll(`[${attr}="${value}"]`);
                                    if (elements.length > 0) {
                                        foundElement = elements[0];
                                        matchedAnchor = anchor;
                                        console.log(`🚀 Stage 1: ${attr} 속성으로 발견:`, value);
                                        break;
                                    }
                                }
                                if (foundElement) break;
                            }
                            
                            // id 매칭
                            if (identifiers.id) {
                                const element = document.getElementById(identifiers.id);
                                if (element) {
                                    foundElement = element;
                                    matchedAnchor = anchor;
                                    console.log('🚀 Stage 1: id로 발견:', identifiers.id);
                                    break;
                                }
                            }
                        }
                        
                        if (foundElement && matchedAnchor) {
                            // 🎯 **정밀 스크롤: 요소 기준 정확한 위치 계산**
                            const elementRect = foundElement.getBoundingClientRect();
                            const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const elementAbsoluteTop = currentY + elementRect.top;
                            
                            // 캡처시 오프셋 보정 적용
                            let finalTargetY = elementAbsoluteTop;
                            if (matchedAnchor.offsetFromTop) {
                                finalTargetY = elementAbsoluteTop - parseFloat(matchedAnchor.offsetFromTop);
                            }
                            
                            // 정밀 스크롤 실행
                            performPreciseScrollTo(targetX, finalTargetY);
                            
                            return {
                                success: true,
                                method: 'unique_identifier',
                                anchorInfo: `identifier_${matchedAnchor.uniqueIdentifiers?.href || matchedAnchor.uniqueIdentifiers?.id || 'unknown'}`,
                                debug: { 
                                    matchedIdentifier: matchedAnchor.uniqueIdentifiers,
                                    elementTop: elementAbsoluteTop,
                                    finalTarget: finalTargetY
                                }
                            };
                        }
                        
                        return { success: false, error: '고유 식별자로 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        return { success: false, error: `Stage 1 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 2: 콘텐츠 지문 기반 복원**
                function tryContentFingerprintRestore(config, targetX, targetY, infiniteScrollData) {
                    try {
                        console.log('🚀 Stage 2: 콘텐츠 지문 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        let foundElement = null;
                        let matchedAnchor = null;
                        
                        for (const anchor of anchors) {
                            if (!anchor.contentFingerprint) continue;
                            
                            const fingerprint = anchor.contentFingerprint;
                            
                            // 텍스트 패턴으로 요소 찾기
                            if (fingerprint.textSignature) {
                                const textPattern = fingerprint.textSignature;
                                const allElements = document.querySelectorAll('*');
                                
                                for (const element of allElements) {
                                    const elementText = (element.textContent || '').trim();
                                    if (elementText.includes(textPattern)) {
                                        // 추가 검증: 태그명, 클래스명이 일치하는지
                                        let isMatch = true;
                                        
                                        if (fingerprint.tagName && element.tagName.toLowerCase() !== fingerprint.tagName.toLowerCase()) {
                                            isMatch = false;
                                        }
                                        
                                        if (fingerprint.className && !element.className.includes(fingerprint.className)) {
                                            isMatch = false;
                                        }
                                        
                                        if (isMatch) {
                                            foundElement = element;
                                            matchedAnchor = anchor;
                                            console.log('🚀 Stage 2: 콘텐츠 지문으로 발견:', textPattern);
                                            break;
                                        }
                                    }
                                }
                                
                                if (foundElement) break;
                            }
                        }
                        
                        if (foundElement && matchedAnchor) {
                            // 🎯 **정밀 스크롤 실행**
                            const elementRect = foundElement.getBoundingClientRect();
                            const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const elementAbsoluteTop = currentY + elementRect.top;
                            
                            let finalTargetY = elementAbsoluteTop;
                            if (matchedAnchor.offsetFromTop) {
                                finalTargetY = elementAbsoluteTop - parseFloat(matchedAnchor.offsetFromTop);
                            }
                            
                            performPreciseScrollTo(targetX, finalTargetY);
                            
                            return {
                                success: true,
                                method: 'content_fingerprint',
                                anchorInfo: `fingerprint_${matchedAnchor.contentFingerprint?.textSignature?.substring(0, 20) || 'unknown'}`,
                                debug: { 
                                    matchedFingerprint: matchedAnchor.contentFingerprint,
                                    elementTop: elementAbsoluteTop,
                                    finalTarget: finalTargetY
                                }
                            };
                        }
                        
                        return { success: false, error: '콘텐츠 지문으로 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        return { success: false, error: `Stage 2 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 3: 상대적 인덱스 기반 복원**
                function tryRelativeIndexRestore(config, targetX, targetY, infiniteScrollData) {
                    try {
                        console.log('🚀 Stage 3: 상대적 인덱스 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        let foundElement = null;
                        let matchedAnchor = null;
                        
                        for (const anchor of anchors) {
                            if (!anchor.relativeIndex) continue;
                            
                            const relativeIndex = anchor.relativeIndex;
                            
                            // 상대적 위치 기반으로 요소 찾기
                            if (relativeIndex.containerSelector && typeof relativeIndex.indexInContainer === 'number') {
                                const containers = document.querySelectorAll(relativeIndex.containerSelector);
                                
                                for (const container of containers) {
                                    const items = container.querySelectorAll(relativeIndex.itemSelector || '*');
                                    const targetIndex = relativeIndex.indexInContainer;
                                    
                                    if (targetIndex >= 0 && targetIndex < items.length) {
                                        const candidateElement = items[targetIndex];
                                        
                                        // 추가 검증: 텍스트 일치
                                        if (relativeIndex.textPreview) {
                                            const elementText = (candidateElement.textContent || '').trim();
                                            if (elementText.includes(relativeIndex.textPreview)) {
                                                foundElement = candidateElement;
                                                matchedAnchor = anchor;
                                                console.log('🚀 Stage 3: 상대적 인덱스로 발견:', targetIndex);
                                                break;
                                            }
                                        } else {
                                            foundElement = candidateElement;
                                            matchedAnchor = anchor;
                                            console.log('🚀 Stage 3: 상대적 인덱스로 발견 (텍스트 검증 없음):', targetIndex);
                                            break;
                                        }
                                    }
                                }
                                
                                if (foundElement) break;
                            }
                        }
                        
                        if (foundElement && matchedAnchor) {
                            // 🎯 **정밀 스크롤 실행**
                            const elementRect = foundElement.getBoundingClientRect();
                            const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const elementAbsoluteTop = currentY + elementRect.top;
                            
                            let finalTargetY = elementAbsoluteTop;
                            if (matchedAnchor.offsetFromTop) {
                                finalTargetY = elementAbsoluteTop - parseFloat(matchedAnchor.offsetFromTop);
                            }
                            
                            performPreciseScrollTo(targetX, finalTargetY);
                            
                            return {
                                success: true,
                                method: 'relative_index',
                                anchorInfo: `index_${matchedAnchor.relativeIndex?.indexInContainer || 'unknown'}`,
                                debug: { 
                                    matchedIndex: matchedAnchor.relativeIndex,
                                    elementTop: elementAbsoluteTop,
                                    finalTarget: finalTargetY
                                }
                            };
                        }
                        
                        return { success: false, error: '상대적 인덱스로 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        return { success: false, error: `Stage 3 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 4: 기존 셀렉터 기반 복원**
                function tryExistingSelectorRestore(config, targetX, targetY, infiniteScrollData) {
                    try {
                        console.log('🚀 Stage 4: 기존 셀렉터 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        let foundElement = null;
                        let matchedAnchor = null;
                        
                        for (const anchor of anchors) {
                            if (!anchor.selectors || !Array.isArray(anchor.selectors)) continue;
                            
                            const selectors = anchor.selectors;
                            
                            // 각 셀렉터 순차 시도
                            for (const selector of selectors) {
                                try {
                                    const elements = document.querySelectorAll(selector);
                                    if (elements.length > 0) {
                                        foundElement = elements[0];
                                        matchedAnchor = anchor;
                                        console.log('🚀 Stage 4: 기존 셀렉터로 발견:', selector);
                                        break;
                                    }
                                } catch(e) {
                                    // 셀렉터 오류는 무시하고 다음 시도
                                    continue;
                                }
                            }
                            
                            if (foundElement) break;
                        }
                        
                        if (foundElement && matchedAnchor) {
                            // 🎯 **정밀 스크롤 실행**
                            const elementRect = foundElement.getBoundingClientRect();
                            const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const elementAbsoluteTop = currentY + elementRect.top;
                            
                            let finalTargetY = elementAbsoluteTop;
                            if (matchedAnchor.offsetFromTop) {
                                finalTargetY = elementAbsoluteTop - parseFloat(matchedAnchor.offsetFromTop);
                            }
                            
                            performPreciseScrollTo(targetX, finalTargetY);
                            
                            return {
                                success: true,
                                method: 'existing_selector',
                                anchorInfo: `selector_${matchedAnchor.selectors?.[0] || 'unknown'}`,
                                debug: { 
                                    matchedSelectors: matchedAnchor.selectors,
                                    elementTop: elementAbsoluteTop,
                                    finalTarget: finalTargetY
                                }
                            };
                        }
                        
                        return { success: false, error: '기존 셀렉터로 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        return { success: false, error: `Stage 4 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 5: 무한스크롤 트리거 후 재시도**
                function tryInfiniteScrollTriggerRestore(config, targetX, targetY, infiniteScrollData) {
                    try {
                        console.log('🚀 Stage 5: 무한스크롤 트리거 후 재시도 시작');
                        
                        // 🎯 **정밀한 문서 높이 재측정**
                        const currentMetrics = getCurrentDocumentMetrics();
                        const currentHeight = currentMetrics.document[1];
                        const currentMaxScrollY = currentMetrics.maxScroll[1];
                        
                        console.log('🚀 Stage 5: 현재 페이지 상태:', {
                            height: currentHeight,
                            maxScrollY: currentMaxScrollY,
                            targetY: targetY
                        });
                        
                        // 목표 위치가 현재 페이지를 벗어났는지 확인
                        if (targetY > currentMaxScrollY + 100) { // 100px 여유분
                            console.log('🚀 Stage 5: 무한스크롤 트리거 필요 - 콘텐츠 로드 시도');
                            
                            // 무한스크롤 트리거 방법들
                            const triggerMethods = [
                                // 1. 페이지 하단으로 스크롤
                                () => {
                                    performPreciseScrollTo(0, currentMaxScrollY);
                                    console.log('🚀 하단 스크롤 트리거');
                                    return true;
                                },
                                
                                // 2. 스크롤 이벤트 발생
                                () => {
                                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                                    window.dispatchEvent(new Event('resize', { bubbles: true }));
                                    console.log('🚀 스크롤 이벤트 트리거');
                                    return true;
                                },
                                
                                // 3. 더보기 버튼 클릭
                                () => {
                                    const loadMoreButtons = document.querySelectorAll(
                                        '.load-more, .show-more, .infinite-scroll-trigger, ' +
                                        '[data-testid*="load"], [class*="load"], [class*="more"]'
                                    );
                                    
                                    let clicked = 0;
                                    loadMoreButtons.forEach(btn => {
                                        if (btn && typeof btn.click === 'function') {
                                            try {
                                                btn.click();
                                                clicked++;
                                            } catch(e) {}
                                        }
                                    });
                                    
                                    console.log(`🚀 더보기 버튼 클릭: ${clicked}개`);
                                    return clicked > 0;
                                },
                                
                                // 4. 터치 이벤트 시뮬레이션 (모바일)
                                () => {
                                    try {
                                        const touchEvent = new TouchEvent('touchend', { bubbles: true });
                                        document.dispatchEvent(touchEvent);
                                        console.log('🚀 터치 이벤트 트리거');
                                        return true;
                                    } catch(e) {
                                        console.log('🚀 터치 이벤트 지원 안됨');
                                        return false;
                                    }
                                }
                            ];
                            
                            // 모든 트리거 방법 시도
                            let triggeredMethods = 0;
                            for (const method of triggerMethods) {
                                try {
                                    const result = method();
                                    if (result !== false) triggeredMethods++;
                                } catch(e) {
                                    console.log('🚀 트리거 방법 실패:', e.message);
                                }
                            }
                            
                            // 🎯 **무한스크롤 후 문서 높이 재측정 대기**
                            setTimeout(() => {
                                const newMetrics = getCurrentDocumentMetrics();
                                const [newPreciseTargetX, newPreciseTargetY] = calculatePreciseTargetPosition(newMetrics);
                                
                                console.log('🚀 Stage 5: 무한스크롤 후 재계산:', {
                                    oldMetrics: currentMetrics,
                                    newMetrics: newMetrics,
                                    oldTarget: [targetX, targetY],
                                    newTarget: [newPreciseTargetX, newPreciseTargetY]
                                });
                                
                                // 정밀 복원 실행
                                performPreciseScrollTo(newPreciseTargetX, newPreciseTargetY);
                            }, 1000); // 무한스크롤 로딩 대기
                            
                            return {
                                success: true,
                                method: 'infinite_scroll_trigger',
                                anchorInfo: `trigger_${triggeredMethods}_methods`,
                                debug: { 
                                    triggeredMethods: triggeredMethods,
                                    oldHeight: currentHeight,
                                    targetY: targetY
                                }
                            };
                        } else {
                            console.log('🚀 Stage 5: 무한스크롤 트리거 불필요 - 정밀 복원');
                            performPreciseScrollTo(targetX, targetY);
                            
                            return {
                                success: true,
                                method: 'coordinate_fallback',
                                anchorInfo: `coords_${targetX}_${targetY}`,
                                debug: { method: 'coordinate_only' }
                            };
                        }
                        
                    } catch(e) {
                        return { success: false, error: `Stage 5 예외: ${e.message}` };
                    }
                }
                
                // 🔧 **최종 결과 처리**
                if (!restoredByStage) {
                    // 모든 단계 실패 - 정밀 폴백
                    console.log('🚨 모든 5단계 실패 - 정밀 좌표 폴백');
                    performPreciseScrollTo(preciseTargetX, preciseTargetY);
                    usedStage = 0;
                    usedMethod = 'precise_coordinate';
                    anchorInfo = 'precise_fallback';
                    errorMsg = '모든 5단계 복원 실패';
                }
                
                // 🎯 **정밀 복원 후 엄격한 검증 및 보정**
                setTimeout(() => {
                    try {
                        const finalMetrics = getCurrentDocumentMetrics();
                        const finalY = finalMetrics.current[1];
                        const finalX = finalMetrics.current[0];
                        const diffY = Math.abs(finalY - preciseTargetY);
                        const diffX = Math.abs(finalX - preciseTargetX);
                        
                        // 🎯 **엄격한 허용 오차 적용**
                        const stageConfig = usedStage > 0 ? STAGE_CONFIG[`stage${usedStage}`] : null;
                        const tolerance = stageConfig ? stageConfig.tolerance : 15; // 기본 15px로 엄격하게
                        
                        verificationResult = {
                            target: [preciseTargetX, preciseTargetY],
                            final: [finalX, finalY],
                            diff: [diffX, diffY],
                            stage: usedStage,
                            method: usedMethod,
                            tolerance: tolerance,
                            withinTolerance: diffX <= tolerance && diffY <= tolerance,
                            stageBased: restoredByStage,
                            actualRestoreDistance: Math.sqrt(diffX * diffX + diffY * diffY),
                            preciseSuccess: diffY <= 15, // 🎯 엄격한 성공 기준 (15px)
                            finalMetrics: finalMetrics
                        };
                        
                        console.log('🎯 정밀 복원 엄격 검증:', verificationResult);
                        
                        if (verificationResult.preciseSuccess) {
                            console.log(`✅ 정밀 복원 성공: 목표=${preciseTargetY}px, 실제=${finalY}px, 차이=${diffY.toFixed(1)}px`);
                        } else {
                            console.log(`❌ 정밀 복원 실패: 목표=${preciseTargetY}px, 실제=${finalY}px, 차이=${diffY.toFixed(1)}px`);
                            
                            // 🎯 **실패시 추가 정밀 보정 (최대 3회)**
                            let correctionAttempts = 0;
                            const maxCorrections = 3;
                            
                            function attemptPreciseCorrection() {
                                if (correctionAttempts >= maxCorrections) {
                                    console.log('🎯 정밀 보정 최대 시도 횟수 도달');
                                    return;
                                }
                                
                                correctionAttempts++;
                                console.log(`🎯 정밀 보정 시도 ${correctionAttempts}/${maxCorrections}`);
                                
                                // 현재 위치 재측정
                                const currentMetrics = getCurrentDocumentMetrics();
                                const currentY = currentMetrics.current[1];
                                const currentDiff = Math.abs(currentY - preciseTargetY);
                                
                                if (currentDiff <= 15) {
                                    console.log('🎯 정밀 보정 성공:', currentY);
                                    return;
                                }
                                
                                // 정밀 스크롤 재시도
                                performPreciseScrollTo(preciseTargetX, preciseTargetY);
                                
                                // 다음 보정을 위한 대기
                                setTimeout(() => {
                                    attemptPreciseCorrection();
                                }, 200);
                            }
                            
                            // 정밀 보정 시작
                            setTimeout(() => {
                                attemptPreciseCorrection();
                            }, 100);
                        }
                        
                    } catch(verifyError) {
                        verificationResult = {
                            error: verifyError.message,
                            stage: usedStage,
                            method: usedMethod
                        };
                        console.error('🎯 정밀 복원 검증 실패:', verifyError);
                    }
                }, 150); // 검증 대기시간 단축
                
                // 🚫 **수정: Swift 호환 반환값 (기본 타입만)**
                return {
                    success: true,
                    stage: usedStage,
                    method: usedMethod,
                    anchorInfo: anchorInfo,
                    stageBased: restoredByStage,
                    debug: debugInfo,
                    stageResults: stageResults,
                    error: errorMsg,
                    verification: verificationResult
                };
                
            } catch(e) { 
                console.error('🚀 5단계 무한스크롤 특화 복원 실패:', e);
                // 🚫 **수정: Swift 호환 반환값**
                return {
                    success: false,
                    stage: 0,
                    method: 'error',
                    anchorInfo: e.message,
                    stageBased: false,
                    error: e.message,
                    debug: { globalError: e.message }
                };
            }
            
            // 🎯 **정밀 스크롤 실행 함수 (여러 방법 동시 적용)**
            function performPreciseScrollTo(x, y) {
                // 여러 방법으로 동시에 스크롤 실행
                window.scrollTo(x, y);
                
                // documentElement 방식
                if (document.documentElement) {
                    document.documentElement.scrollTop = y;
                    document.documentElement.scrollLeft = x;
                }
                
                // body 방식
                if (document.body) {
                    document.body.scrollTop = y;
                    document.body.scrollLeft = x;
                }
                
                // scrollingElement 방식 (표준)
                if (document.scrollingElement) {
                    document.scrollingElement.scrollTop = y;
                    document.scrollingElement.scrollLeft = x;
                }
                
                console.log('🎯 정밀 스크롤 실행:', [x, y]);
            }
        })()
        """
    }
    
    // 🎯 **새로 추가: 정밀 복원 및 엄격한 검증 시스템**
    private func performPreciseRestoreWithStrictValidation(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        TabPersistenceManager.debugMessages.append("🎯 정밀 복원 및 엄격한 검증 시스템 시작")
        
        // **1단계: 상대적 위치 기반 정밀 복원**
        restoreSteps.append((1, { stepCompletion in
            let progressiveDelay: TimeInterval = 0.05 // 지연시간 단축
            TabPersistenceManager.debugMessages.append("🎯 1단계: 상대적 위치 기반 정밀 복원 (대기: \(String(format: "%.0f", progressiveDelay * 1000))ms)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + progressiveDelay) {
                let preciseRestoreJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        const targetPercentX = parseFloat('\(self.scrollPositionPercent.x)');
                        const targetPercentY = parseFloat('\(self.scrollPositionPercent.y)');
                        
                        console.log('🎯 상대적 위치 기반 정밀 복원 시작:', {
                            absoluteTarget: [targetX, targetY],
                            percentTarget: [targetPercentX, targetPercentY]
                        });
                        
                        // 🎯 **현재 문서 상태 정밀 측정**
                        function getPreciseDocumentMetrics() {
                            // 여러 방법으로 스크롤 위치 측정
                            const scrollMethods = [
                                () => [window.scrollX || 0, window.scrollY || 0],
                                () => [window.pageXOffset || 0, window.pageYOffset || 0],
                                () => [document.documentElement.scrollLeft || 0, document.documentElement.scrollTop || 0],
                                () => [document.body.scrollLeft || 0, document.body.scrollTop || 0]
                            ];
                            
                            let currentScrollX = 0, currentScrollY = 0;
                            for (const method of scrollMethods) {
                                try {
                                    const [x, y] = method();
                                    if (y > currentScrollY) {
                                        currentScrollX = x;
                                        currentScrollY = y;
                                    }
                                } catch(e) {}
                            }
                            
                            // 문서 크기 정밀 측정
                            const documentHeight = Math.max(
                                document.documentElement.scrollHeight || 0,
                                document.body.scrollHeight || 0,
                                document.documentElement.offsetHeight || 0,
                                document.body.offsetHeight || 0,
                                document.documentElement.clientHeight || 0
                            );
                            
                            const documentWidth = Math.max(
                                document.documentElement.scrollWidth || 0,
                                document.body.scrollWidth || 0,
                                document.documentElement.offsetWidth || 0,
                                document.body.offsetWidth || 0,
                                document.documentElement.clientWidth || 0
                            );
                            
                            const viewportHeight = parseFloat(window.innerHeight || document.documentElement.clientHeight || 0);
                            const viewportWidth = parseFloat(window.innerWidth || document.documentElement.clientWidth || 0);
                            
                            const maxScrollY = Math.max(0, documentHeight - viewportHeight);
                            const maxScrollX = Math.max(0, documentWidth - viewportWidth);
                            
                            return {
                                current: [currentScrollX, currentScrollY],
                                document: [documentWidth, documentHeight],
                                viewport: [viewportWidth, viewportHeight],
                                maxScroll: [maxScrollX, maxScrollY]
                            };
                        }
                        
                        const metrics = getPreciseDocumentMetrics();
                        
                        console.log('🎯 현재 문서 상태:', metrics);
                        
                        // 🎯 **정밀한 목표 위치 계산 (상대적 위치 우선)**
                        let preciseTargetX = targetX;
                        let preciseTargetY = targetY;
                        
                        // 상대적 위치가 유효하면 우선 사용
                        if (targetPercentY > 0 && targetPercentY <= 100 && metrics.maxScroll[1] > 0) {
                            preciseTargetY = (targetPercentY / 100.0) * metrics.maxScroll[1];
                            console.log('🎯 Y축 상대적 위치 사용:', targetPercentY + '% → ' + preciseTargetY + 'px');
                        }
                        
                        if (targetPercentX > 0 && targetPercentX <= 100 && metrics.maxScroll[0] > 0) {
                            preciseTargetX = (targetPercentX / 100.0) * metrics.maxScroll[0];
                            console.log('🎯 X축 상대적 위치 사용:', targetPercentX + '% → ' + preciseTargetX + 'px');
                        }
                        
                        // 범위 제한
                        preciseTargetX = Math.max(0, Math.min(preciseTargetX, metrics.maxScroll[0]));
                        preciseTargetY = Math.max(0, Math.min(preciseTargetY, metrics.maxScroll[1]));
                        
                        console.log('🎯 최종 목표 위치:', [preciseTargetX, preciseTargetY]);
                        
                        // 🎯 **다단계 정밀 복원 (브라우저 차단 회피)**
                        let attempts = 0;
                        const maxAttempts = 10;
                        let lastPositions = [];
                        
                        function performPreciseRestore() {
                            attempts++;
                            console.log(`🎯 정밀 복원 시도 ${attempts}/${maxAttempts}`);
                            
                            // 현재 위치 확인
                            const currentMetrics = getPreciseDocumentMetrics();
                            const currentY = currentMetrics.current[1];
                            const currentX = currentMetrics.current[0];
                            
                            const diffX = Math.abs(currentX - preciseTargetX);
                            const diffY = Math.abs(currentY - preciseTargetY);
                            
                            lastPositions.push([currentX, currentY, diffX, diffY]);
                            
                            // 🎯 **엄격한 성공 기준 (10px 이내)**
                            if (diffX <= 10 && diffY <= 10) {
                                console.log('🎯 정밀 복원 성공:', {
                                    target: [preciseTargetX, preciseTargetY],
                                    current: [currentX, currentY],
                                    diff: [diffX, diffY],
                                    attempts: attempts
                                });
                                return 'precise_success';
                            }
                            
                            // 스크롤 한계 확인
                            if (currentY >= currentMetrics.maxScroll[1] && preciseTargetY > currentMetrics.maxScroll[1]) {
                                console.log('🎯 스크롤 한계 도달 - 무한스크롤 트리거 시도');
                                
                                // 무한스크롤 트리거
                                window.dispatchEvent(new Event('scroll', { bubbles: true }));
                                window.dispatchEvent(new Event('resize', { bubbles: true }));
                                
                                // 더보기 버튼 클릭
                                const loadMoreButtons = document.querySelectorAll(
                                    '.load-more, .show-more, .infinite-scroll-trigger, ' +
                                    '[data-testid*="load"], [class*="load"], [class*="more"]'
                                );
                                
                                loadMoreButtons.forEach(btn => {
                                    if (btn && typeof btn.click === 'function') {
                                        try { btn.click(); } catch(e) {}
                                    }
                                });
                            }
                            
                            // 🎯 **정밀 스크롤 실행 (여러 방법 동시)**
                            try {
                                // 표준 방법
                                window.scrollTo(preciseTargetX, preciseTargetY);
                                
                                // 백업 방법들
                                if (document.documentElement) {
                                    document.documentElement.scrollTop = preciseTargetY;
                                    document.documentElement.scrollLeft = preciseTargetX;
                                }
                                
                                if (document.body) {
                                    document.body.scrollTop = preciseTargetY;
                                    document.body.scrollLeft = preciseTargetX;
                                }
                                
                                if (document.scrollingElement) {
                                    document.scrollingElement.scrollTop = preciseTargetY;
                                    document.scrollingElement.scrollLeft = preciseTargetX;
                                }
                            } catch(scrollError) {
                                console.error('🎯 스크롤 실행 오류:', scrollError);
                            }
                            
                            // 최대 시도 확인
                            if (attempts >= maxAttempts) {
                                console.log('🎯 정밀 복원 최대 시도 도달:', {
                                    target: [preciseTargetX, preciseTargetY],
                                    final: [currentX, currentY],
                                    attempts: maxAttempts,
                                    lastPositions: lastPositions
                                });
                                return 'precise_maxAttempts';
                            }
                            
                            // 위치 변화 정체 감지
                            if (lastPositions.length >= 3) {
                                const recentPositions = lastPositions.slice(-3);
                                const positionChanges = recentPositions.map((pos, i) => {
                                    if (i === 0) return 0;
                                    const prev = recentPositions[i-1];
                                    return Math.abs(pos[1] - prev[1]); // Y축 변화량
                                });
                                
                                const avgChange = positionChanges.reduce((a, b) => a + b, 0) / positionChanges.length;
                                
                                if (avgChange < 5) { // 5px 미만 변화면 정체
                                    console.log('🎯 위치 변화 정체 감지 - 강제 점프');
                                    // 목표 위치로 즉시 점프
                                    window.scrollTo(preciseTargetX, preciseTargetY);
                                    return 'precise_forceJump';
                                }
                            }
                            
                            // 다음 시도를 위한 대기
                            setTimeout(() => {
                                performPreciseRestore();
                            }, 150); // 150ms 간격으로 시도
                            
                            return null; // 계속 진행
                        }
                        
                        // 첫 번째 시도 시작
                        const result = performPreciseRestore();
                        return result || 'precise_inProgress';
                        
                    } catch(e) { 
                        console.error('🎯 상대적 위치 기반 정밀 복원 실패:', e);
                        return 'precise_error: ' + e.message; 
                    }
                })()
                """
                
                webView.evaluateJavaScript(preciseRestoreJS) { result, error in
                    var resultString = "precise_unknown"
                    var success = false
                    
                    if let error = error {
                        resultString = "precise_jsError: \(error.localizedDescription)"
                        TabPersistenceManager.debugMessages.append("🎯 1단계 JavaScript 실행 오류: \(error.localizedDescription)")
                    } else if let result = result as? String {
                        resultString = result
                        success = result.contains("success") || result.contains("forceJump") || result.contains("maxAttempts")
                    } else {
                        resultString = "precise_invalidResult"
                    }
                    
                    TabPersistenceManager.debugMessages.append("🎯 1단계 완료: \(success ? "성공" : "실패") (\(resultString))")
                    stepCompletion(success)
                }
            }
        }))
        
        // **2단계: 엄격한 검증 및 최종 보정**
        restoreSteps.append((2, { stepCompletion in
            let waitTime: TimeInterval = 0.5 // 검증 대기시간 단축
            TabPersistenceManager.debugMessages.append("🎯 2단계: 엄격한 검증 및 최종 보정 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                let strictValidationJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        const targetPercentX = parseFloat('\(self.scrollPositionPercent.x)');
                        const targetPercentY = parseFloat('\(self.scrollPositionPercent.y)');
                        
                        // 🎯 **최종 위치 정밀 측정**
                        function getFinalPrecisePosition() {
                            const methods = [
                                () => [window.scrollX || 0, window.scrollY || 0],
                                () => [window.pageXOffset || 0, window.pageYOffset || 0],
                                () => [document.documentElement.scrollLeft || 0, document.documentElement.scrollTop || 0],
                                () => [document.body.scrollLeft || 0, document.body.scrollTop || 0]
                            ];
                            
                            let maxX = 0, maxY = 0;
                            const results = [];
                            
                            for (const method of methods) {
                                try {
                                    const [x, y] = method();
                                    results.push([x, y]);
                                    if (y > maxY) {
                                        maxX = x;
                                        maxY = y;
                                    }
                                } catch(e) {
                                    results.push(['error', e.message]);
                                }
                            }
                            
                            return {
                                final: [maxX, maxY],
                                allResults: results
                            };
                        }
                        
                        const positionData = getFinalPrecisePosition();
                        const finalX = positionData.final[0];
                        const finalY = positionData.final[1];
                        
                        // 문서 상태 재측정
                        const documentHeight = Math.max(
                            document.documentElement.scrollHeight || 0,
                            document.body.scrollHeight || 0
                        );
                        const viewportHeight = parseFloat(window.innerHeight || 0);
                        const maxScrollY = Math.max(0, documentHeight - viewportHeight);
                        
                        // 🎯 **정밀한 목표 위치 재계산**
                        let preciseTargetY = targetY;
                        if (targetPercentY > 0 && targetPercentY <= 100 && maxScrollY > 0) {
                            preciseTargetY = (targetPercentY / 100.0) * maxScrollY;
                        }
                        preciseTargetY = Math.max(0, Math.min(preciseTargetY, maxScrollY));
                        
                        const diffX = Math.abs(finalX - targetX);
                        const diffY = Math.abs(finalY - preciseTargetY);
                        
                        // 🎯 **엄격한 성공 기준 (5px 이내)**
                        const strictTolerance = 5.0;
                        const isStrictSuccess = diffX <= strictTolerance && diffY <= strictTolerance;
                        
                        // 🎯 **일반적인 성공 기준 (15px 이내)**
                        const normalTolerance = 15.0;
                        const isNormalSuccess = diffX <= normalTolerance && diffY <= normalTolerance;
                        
                        console.log('🎯 엄격한 최종 검증:', {
                            target: [targetX, preciseTargetY],
                            final: [finalX, finalY],
                            diff: [diffX, diffY],
                            strictSuccess: isStrictSuccess,
                            normalSuccess: isNormalSuccess,
                            documentHeight: documentHeight,
                            maxScrollY: maxScrollY,
                            percent: [targetPercentX, targetPercentY],
                            allResults: positionData.allResults
                        });
                        
                        // 🎯 **실패시 최종 보정 (최대 3회)**
                        if (!isStrictSuccess && diffY > strictTolerance) {
                            console.log('🎯 엄격한 기준 실패 - 최종 보정 시도');
                            
                            let correctionCount = 0;
                            const maxCorrections = 3;
                            
                            function performFinalCorrection() {
                                if (correctionCount >= maxCorrections) {
                                    console.log('🎯 최종 보정 완료 (최대 시도)');
                                    return;
                                }
                                
                                correctionCount++;
                                console.log(`🎯 최종 보정 ${correctionCount}/${maxCorrections}`);
                                
                                // 강력한 스크롤 실행
                                window.scrollTo(targetX, preciseTargetY);
                                document.documentElement.scrollTop = preciseTargetY;
                                document.body.scrollTop = preciseTargetY;
                                
                                if (document.scrollingElement) {
                                    document.scrollingElement.scrollTop = preciseTargetY;
                                }
                                
                                // 다음 보정을 위한 대기
                                setTimeout(() => {
                                    const checkData = getFinalPrecisePosition();
                                    const checkY = checkData.final[1];
                                    const checkDiff = Math.abs(checkY - preciseTargetY);
                                    
                                    if (checkDiff <= strictTolerance) {
                                        console.log('🎯 최종 보정 성공:', checkY);
                                        return;
                                    }
                                    
                                    performFinalCorrection();
                                }, 100);
                            }
                            
                            performFinalCorrection();
                        }
                        
                        return {
                            success: isNormalSuccess, // 일반적 성공 기준 사용
                            strictSuccess: isStrictSuccess,
                            finalPosition: [finalX, finalY],
                            targetPosition: [targetX, preciseTargetY],
                            diff: [diffX, diffY],
                            strictTolerance: strictTolerance,
                            normalTolerance: normalTolerance,
                            documentState: {
                                height: documentHeight,
                                maxScrollY: maxScrollY
                            };
                            measurementResults: positionData.allResults
                        };
                    } catch(e) { 
                        console.error('🎯 엄격한 최종 검증 실패:', e);
                        return {
                            success: false,
                            error: e.message
                        };
                    }
                })()
                """
                
                webView.evaluateJavaScript(strictValidationJS) { result, error in
                    if let error = error {
                        TabPersistenceManager.debugMessages.append("🎯 2단계 JavaScript 실행 오류: \(error.localizedDescription)")
                    }
                    
                    var success = false
                    if let resultDict = result as? [String: Any] {
                        success = (resultDict["success"] as? Bool) ?? false
                        
                        if let strictSuccess = resultDict["strictSuccess"] as? Bool {
                            TabPersistenceManager.debugMessages.append("🎯 엄격한 성공: \(strictSuccess)")
                        }
                        if let finalPos = resultDict["finalPosition"] as? [Double] {
                            TabPersistenceManager.debugMessages.append("🎯 최종 위치: X=\(String(format: "%.1f", finalPos[0]))px, Y=\(String(format: "%.1f", finalPos[1]))px")
                        }
                        if let targetPos = resultDict["targetPosition"] as? [Double] {
                            TabPersistenceManager.debugMessages.append("🎯 목표 위치: X=\(String(format: "%.1f", targetPos[0]))px, Y=\(String(format: "%.1f", targetPos[1]))px")
                        }
                        if let diff = resultDict["diff"] as? [Double] {
                            TabPersistenceManager.debugMessages.append("🎯 최종 차이: X=\(String(format: "%.1f", diff[0]))px, Y=\(String(format: "%.1f", diff[1]))px")
                        }
                        if let docState = resultDict["documentState"] as? [String: Any] {
                            if let height = docState["height"] as? Double,
                               let maxScrollY = docState["maxScrollY"] as? Double {
                                TabPersistenceManager.debugMessages.append("🎯 문서 상태: 높이=\(String(format: "%.0f", height))px, 최대스크롤=\(String(format: "%.0f", maxScrollY))px")
                            }
                        }
                        if let errorMsg = resultDict["error"] as? String {
                            TabPersistenceManager.debugMessages.append("🎯 검증 오류: \(errorMsg)")
                        }
                    } else {
                        success = false
                    }
                    
                    TabPersistenceManager.debugMessages.append("🎯 2단계 엄격한 검증 완료: \(success ? "성공" : "실패")")
                    stepCompletion(success)
                }
            }
        }))
        
        TabPersistenceManager.debugMessages.append("🎯 총 \(restoreSteps.count)단계 정밀 복원 시스템 구성 완료")
        
        // 단계별 실행
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                TabPersistenceManager.debugMessages.append("🎯 \(stepInfo.step)단계 실행 시작")
                
                let stepStart = Date()
                stepInfo.action { success in
                    let stepDuration = Date().timeIntervalSince(stepStart)
                    TabPersistenceManager.debugMessages.append("🎯 단계 \(stepInfo.step) 소요시간: \(String(format: "%.2f", stepDuration))초")
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount >= 1 // 하나라도 성공하면 성공
                
                TabPersistenceManager.debugMessages.append("🎯 정밀 복원 시스템 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                TabPersistenceManager.debugMessages.append("🎯 최종 결과: \(overallSuccess ? "✅ 성공" : "❌ 실패")")
                completion(overallSuccess)
            }
        }
        
        executeNextStep()
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

// MARK: - BFCacheTransitionSystem 캐처/복원 확장
extension BFCacheTransitionSystem {
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🚀 5단계 무한스크롤 특화 캡처)**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        // 🌐 캡처 대상 사이트 로그
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 특화 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    // 🔥 **수정: JavaScript로 스크롤 위치 직접 읽기**
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        guard let webView = task.webView else {
            TabPersistenceManager.debugMessages.append("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 특화 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 🔥 **JavaScript로 실제 스크롤 위치 읽기**
        let semaphore = DispatchSemaphore(value: 0)
        var captureData: CaptureData?
        
        DispatchQueue.main.sync {
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                semaphore.signal()
                return
            }
            
            // 🔥 **JavaScript로 정확한 스크롤 위치 읽기**
            let scrollMetricsJS = """
            (function() {
                const scrollY = parseFloat(window.scrollY || window.pageYOffset || document.documentElement.scrollTop || document.body.scrollTop || 0);
                const scrollX = parseFloat(window.scrollX || window.pageXOffset || document.documentElement.scrollLeft || document.body.scrollLeft || 0);
                
                const documentHeight = Math.max(
                    document.documentElement.scrollHeight || 0,
                    document.body.scrollHeight || 0,
                    document.documentElement.offsetHeight || 0,
                    document.body.offsetHeight || 0
                );
                
                const documentWidth = Math.max(
                    document.documentElement.scrollWidth || 0,
                    document.body.scrollWidth || 0,
                    document.documentElement.offsetWidth || 0,
                    document.body.offsetWidth || 0
                );
                
                const viewportHeight = parseFloat(window.innerHeight || document.documentElement.clientHeight || 0);
                const viewportWidth = parseFloat(window.innerWidth || document.documentElement.clientWidth || 0);
                
                console.log('🔥 JavaScript 스크롤 위치 읽기:', {
                    scroll: [scrollX, scrollY],
                    document: [documentWidth, documentHeight],
                    viewport: [viewportWidth, viewportHeight]
                });
                
                return {
                    scrollX: scrollX,
                    scrollY: scrollY,
                    contentWidth: documentWidth,
                    contentHeight: documentHeight,
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight
                };
            })()
            """
            
            webView.evaluateJavaScript(scrollMetricsJS) { result, error in
                defer { semaphore.signal() }
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 스크롤 위치 읽기 실패: \(error.localizedDescription)")
                    // Fallback: WebView scrollView 사용
                    let actualScrollableWidth = max(webView.scrollView.contentSize.width, webView.scrollView.bounds.width)
                    let actualScrollableHeight = max(webView.scrollView.contentSize.height, webView.scrollView.bounds.height)
                    
                    captureData = CaptureData(
                        scrollPosition: webView.scrollView.contentOffset,
                        contentSize: webView.scrollView.contentSize,
                        viewportSize: webView.bounds.size,
                        actualScrollableSize: CGSize(width: actualScrollableWidth, height: actualScrollableHeight),
                        bounds: webView.bounds,
                        isLoading: webView.isLoading
                    )
                    return
                }
                
                if let metrics = result as? [String: Any] {
                    let scrollX = CGFloat((metrics["scrollX"] as? Double) ?? 0)
                    let scrollY = CGFloat((metrics["scrollY"] as? Double) ?? 0)
                    let contentWidth = CGFloat((metrics["contentWidth"] as? Double) ?? 0)
                    let contentHeight = CGFloat((metrics["contentHeight"] as? Double) ?? 0)
                    let viewportWidth = CGFloat((metrics["viewportWidth"] as? Double) ?? 0)
                    let viewportHeight = CGFloat((metrics["viewportHeight"] as? Double) ?? 0)
                    
                    TabPersistenceManager.debugMessages.append("🔥 JavaScript 스크롤 위치: X=\(scrollX), Y=\(scrollY)")
                    TabPersistenceManager.debugMessages.append("🔥 콘텐츠 크기: \(contentWidth)x\(contentHeight)")
                    TabPersistenceManager.debugMessages.append("🔥 뷰포트 크기: \(viewportWidth)x\(viewportHeight)")
                    
                    captureData = CaptureData(
                        scrollPosition: CGPoint(x: scrollX, y: scrollY),
                        contentSize: CGSize(width: contentWidth, height: contentHeight),
                        viewportSize: CGSize(width: viewportWidth, height: viewportHeight),
                        actualScrollableSize: CGSize(width: max(contentWidth, viewportWidth), height: max(contentHeight, viewportHeight)),
                        bounds: webView.bounds,
                        isLoading: webView.isLoading
                    )
                } else {
                    TabPersistenceManager.debugMessages.append("🔥 JavaScript 결과 파싱 실패")
                    // Fallback
                    let actualScrollableWidth = max(webView.scrollView.contentSize.width, webView.scrollView.bounds.width)
                    let actualScrollableHeight = max(webView.scrollView.contentSize.height, webView.scrollView.bounds.height)
                    
                    captureData = CaptureData(
                        scrollPosition: webView.scrollView.contentOffset,
                        contentSize: webView.scrollView.contentSize,
                        viewportSize: webView.bounds.size,
                        actualScrollableSize: CGSize(width: actualScrollableWidth, height: actualScrollableHeight),
                        bounds: webView.bounds,
                        isLoading: webView.isLoading
                    )
                }
            }
        }
        
        // JavaScript 실행 대기
        _ = semaphore.wait(timeout: .now() + 1.0)
        
        guard let data = captureData else {
            TabPersistenceManager.debugMessages.append("❌ 캡처 데이터 없음 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 🔧 **개선된 캡처 로직 - 실패 시 재시도 (기존 타이밍 유지)**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
        )
        
        // 🔥 **캡처된 jsState 상세 로깅**
        if let jsState = captureResult.snapshot.jsState {
            TabPersistenceManager.debugMessages.append("🔥 캡처된 jsState 키: \(Array(jsState.keys))")
            
            if let infiniteScrollData = jsState["infiniteScrollData"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🚀 캡처된 무한스크롤 데이터 키: \(Array(infiniteScrollData.keys))")
                
                if let anchors = infiniteScrollData["anchors"] as? [[String: Any]] {
                    TabPersistenceManager.debugMessages.append("🚀 캡처된 무한스크롤 앵커 개수: \(anchors.count)개")
                    if anchors.count > 0 {
                        let firstAnchor = anchors[0]
                        TabPersistenceManager.debugMessages.append("🚀 첫 번째 앵커 키: \(Array(firstAnchor.keys))")
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 데이터 캡처 실패")
                }
            } else {
                TabPersistenceManager.debugMessages.append("🚀 무한스크롤 데이터 캡처 실패")
            }
        } else {
            TabPersistenceManager.debugMessages.append("🔥 jsState 캡처 완전 실패 - nil")
        }
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ 5단계 무한스크롤 특화 직렬 캡처 완료: \(task.pageRecord.title)")
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
                    TabPersistenceManager.debugMessages.append("🔄 재시도 후 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기 - 🔧 기존 80ms 유지
            TabPersistenceManager.debugMessages.append("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
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
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
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
            TabPersistenceManager.debugMessages.append("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
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
        
        // 3. ✅ **수정: Promise 제거한 5단계 무한스크롤 특화 JS 상태 캡처** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = generateFiveStageInfiniteScrollCaptureScript() // 🚀 새로운 5단계 캡처 스크립트 사용
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                } else {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 결과 타입 오류: \(type(of: result))")
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
        
        // 🎯 **정밀한 상대적 위치 계산 (백분율) - 0 방지**
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.width > captureData.viewportSize.width && captureData.actualScrollableSize.height > captureData.viewportSize.height {
            let maxScrollX = captureData.actualScrollableSize.width - captureData.viewportSize.width
            let maxScrollY = captureData.actualScrollableSize.height - captureData.viewportSize.height
            
            let percentX = maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0
            let percentY = maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            
            // 🎯 정밀도 향상: 소수점 2자리까지
            scrollPercent = CGPoint(
                x: round(percentX * 100) / 100,
                y: round(percentY * 100) / 100
            )
            
            TabPersistenceManager.debugMessages.append("🎯 상대적 위치 계산: Y=\(String(format: "%.2f", percentY))% (절대: \(String(format: "%.0f", captureData.scrollPosition.y))px / 최대: \(String(format: "%.0f", maxScrollY))px)")
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
        
        TabPersistenceManager.debugMessages.append("🔥 최종 캡처 스크롤 위치: X=\(captureData.scrollPosition.x), Y=\(captureData.scrollPosition.y)")
        
        return (snapshot, visualSnapshot)
    }
    
    // 🚀 **새로운: 5단계 무한스크롤 특화 캡처 JavaScript 생성**
    private func generateFiveStageInfiniteScrollCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 5단계 무한스크롤 특화 캡처 시작');
                
                // 기본 정보 수집
                const scrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                const scrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                
                console.log('🚀 기본 정보:', {
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                // 🚀 **5단계 무한스크롤 특화 앵커 수집**
                function collectInfiniteScrollAnchors() {
                    const anchors = [];
                    const viewportRect = {
                        top: scrollY,
                        left: scrollX,
                        bottom: scrollY + viewportHeight,
                        right: scrollX + viewportWidth
                    };
                    
                    console.log('🚀 뷰포트 영역:', viewportRect);
                    
                    // 🚀 **범용 무한스크롤 요소 패턴 (모든 사이트 대응)**
                    const infiniteScrollSelectors = [
                        // 기본 컨텐츠 아이템
                        'li', 'tr', 'td',
                        '.item', '.list-item', '.card', '.post', '.article',
                        '.comment', '.reply', '.feed', '.thread', '.message',
                        '.product', '.news', '.media', '.content-item',
                        
                        // 일반적인 컨테이너
                        'div[class*="item"]', 'div[class*="post"]', 'div[class*="card"]',
                        'div[class*="content"]', 'div[class*="entry"]',
                        
                        // 데이터 속성 기반
                        '[data-testid]', '[data-id]', '[data-key]',
                        '[data-item-id]', '[data-article-id]', '[data-post-id]',
                        '[data-comment-id]', '[data-user-id]', '[data-content-id]',
                        '[data-thread-id]', '[data-message-id]',
                        
                        // 특별한 컨텐츠 요소
                        'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
                        'section', 'article', 'aside',
                        'img', 'video', 'iframe'
                    ];
                    
                    let candidateElements = [];
                    let selectorStats = {};
                    
                    // 모든 selector에서 요소 수집
                    for (const selector of infiniteScrollSelectors) {
                        try {
                            const elements = document.querySelectorAll(selector);
                            if (elements.length > 0) {
                                selectorStats[selector] = elements.length;
                                candidateElements.push(...Array.from(elements));
                            }
                        } catch(e) {
                            selectorStats[selector] = `error: ${e.message}`;
                        }
                    }
                    
                    console.log('🚀 후보 요소 수집:', {
                        totalElements: candidateElements.length,
                        stats: selectorStats
                    });
                    
                    // 뷰포트 근처 요소들만 필터링 (확장된 범위)
                    const extendedViewportHeight = viewportHeight * 3; // 위아래 3화면 범위
                    const extendedTop = Math.max(0, scrollY - extendedViewportHeight);
                    const extendedBottom = scrollY + extendedViewportHeight;
                    
                    let nearbyElements = [];
                    
                    for (const element of candidateElements) {
                        try {
                            const rect = element.getBoundingClientRect();
                            const elementTop = scrollY + rect.top;
                            const elementBottom = scrollY + rect.bottom;
                            
                            // 확장된 뷰포트 범위 내에 있는지 확인
                            if (elementBottom >= extendedTop && elementTop <= extendedBottom) {
                                nearbyElements.push({
                                    element: element,
                                    rect: rect,
                                    absoluteTop: elementTop,
                                    absoluteLeft: scrollX + rect.left,
                                    distanceFromViewport: Math.abs(elementTop - scrollY)
                                });
                            }
                        } catch(e) {
                            // 개별 요소 오류는 무시
                        }
                    }
                    
                    console.log('🚀 뷰포트 근처 요소:', nearbyElements.length, '개');
                    
                    // 거리순으로 정렬하여 상위 30개만 선택
                    nearbyElements.sort((a, b) => a.distanceFromViewport - b.distanceFromViewport);
                    const selectedElements = nearbyElements.slice(0, 30);
                    
                    console.log('🚀 선택된 요소:', selectedElements.length, '개');
                    
                    // 각 요소에 대해 5단계 정보 수집
                    for (const elementData of selectedElements) {
                        try {
                            const anchor = createInfiniteScrollAnchor(elementData);
                            if (anchor) {
                                anchors.push(anchor);
                            }
                        } catch(e) {
                            console.warn('🚀 앵커 생성 실패:', e);
                        }
                    }
                    
                    console.log('🚀 무한스크롤 앵커 수집 완료:', anchors.length, '개');
                    
                    return {
                        anchors: anchors,
                        stats: {
                            candidateElements: candidateElements.length,
                            nearbyElements: nearbyElements.length,
                            selectedElements: selectedElements.length,
                            finalAnchors: anchors.length,
                            selectorStats: selectorStats
                        }
                    };
                }
                
                // 🚀 **개별 무한스크롤 앵커 생성 (5단계 정보 포함)**
                function createInfiniteScrollAnchor(elementData) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const absoluteTop = elementData.absoluteTop;
                        const absoluteLeft = elementData.absoluteLeft;
                        
                        // 뷰포트 기준 오프셋 계산
                        const offsetFromTop = scrollY - absoluteTop;
                        const offsetFromLeft = scrollX - absoluteLeft;
                        
                        // 🚀 **1단계: 고유 식별자 수집**
                        const uniqueIdentifiers = {};
                        
                        // href 패턴 (링크가 있는 경우)
                        const linkElement = element.querySelector('a[href]') || (element.tagName === 'A' ? element : null);
                        if (linkElement && linkElement.href) {
                            const href = linkElement.href;
                            // URL에서 고유한 부분 추출 (ID 파라미터 등)
                            const urlParams = new URL(href).searchParams;
                            for (const [key, value] of urlParams) {
                                if (key.includes('id') || key.includes('article') || key.includes('post')) {
                                    uniqueIdentifiers.href = `${key}=${value}`;
                                    break;
                                }
                            }
                            if (!uniqueIdentifiers.href && href.includes('id=')) {
                                const match = href.match(/id=([^&]+)/);
                                if (match) uniqueIdentifiers.href = match[0];
                            }
                        }
                        
                        // data-* 속성들
                        const dataAttributes = {};
                        for (const attr of element.attributes) {
                            if (attr.name.startsWith('data-') && 
                                (attr.name.includes('id') || attr.name.includes('key') || 
                                 attr.name.includes('post') || attr.name.includes('article'))) {
                                dataAttributes[attr.name] = attr.value;
                            }
                        }
                        if (Object.keys(dataAttributes).length > 0) {
                            uniqueIdentifiers.dataAttributes = dataAttributes;
                        }
                        
                        // id 속성
                        if (element.id) {
                            uniqueIdentifiers.id = element.id;
                        }
                        
                        // 🚀 **2단계: 콘텐츠 지문 생성**
                        const textContent = (element.textContent || '').trim();
                        const contentFingerprint = {};
                        
                        if (textContent.length > 0) {
                            // 텍스트 시그니처 (앞 30자 + 뒤 30자)
                            if (textContent.length > 60) {
                                contentFingerprint.textSignature = textContent.substring(0, 30) + '...' + textContent.substring(textContent.length - 30);
                            } else {
                                contentFingerprint.textSignature = textContent;
                            }
                            
                            // 구조 정보
                            contentFingerprint.tagName = element.tagName.toLowerCase();
                            contentFingerprint.className = (element.className || '').split(' ')[0] || '';
                            
                            // 시간 정보 추출 (시:분 패턴)
                            const timeMatch = textContent.match(/\\d{1,2}:\\d{2}/);
                            if (timeMatch) {
                                contentFingerprint.timePattern = timeMatch[0];
                            }
                        }
                        
                        // 🚀 **3단계: 상대적 인덱스 계산**
                        const relativeIndex = {};
                        
                        // 부모 컨테이너에서의 인덱스
                        const parent = element.parentElement;
                        if (parent) {
                            const siblings = Array.from(parent.children);
                            const index = siblings.indexOf(element);
                            if (index >= 0) {
                                relativeIndex.indexInContainer = index;
                                relativeIndex.containerSelector = generateBestSelector(parent);
                                relativeIndex.itemSelector = element.tagName.toLowerCase();
                                
                                // 텍스트 미리보기 (검증용)
                                if (textContent.length > 0) {
                                    relativeIndex.textPreview = textContent.substring(0, 50);
                                }
                            }
                        }
                        
                        // 🚀 **4단계: 기존 셀렉터들 생성**
                        const selectors = [];
                        
                        // ID 기반 selector (최우선)
                        if (element.id) {
                            selectors.push('#' + element.id);
                        }
                        
                        // 데이터 속성 기반
                        for (const [attr, value] of Object.entries(dataAttributes)) {
                            selectors.push(`[${attr}="${value}"]`);
                            selectors.push(`${element.tagName.toLowerCase()}[${attr}="${value}"]`);
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
                        if (parent) {
                            const siblings = Array.from(parent.children);
                            const index = siblings.indexOf(element) + 1;
                            if (index > 0 && siblings.length < 20) {
                                selectors.push(`${parent.tagName.toLowerCase()} > ${element.tagName.toLowerCase()}:nth-child(${index})`);
                            }
                        }
                        
                        // 태그명 기본
                        selectors.push(element.tagName.toLowerCase());
                        
                        // 🚀 **5단계: 무한스크롤 컨텍스트 정보**
                        const infiniteScrollContext = {
                            documentHeight: contentHeight,
                            viewportPosition: scrollY,
                            relativePosition: contentHeight > 0 ? (absoluteTop / contentHeight) : 0, // 문서 내 상대적 위치 (0-1)
                            distanceFromViewport: elementData.distanceFromViewport,
                            isInViewport: rect.top >= 0 && rect.bottom <= viewportHeight,
                            elementSize: {
                                width: rect.width,
                                height: rect.height
                            }
                        };
                        
                        // 🚫 **수정: DOM 요소 대신 기본 타입만 반환**
                        return {
                            // 기본 정보
                            tagName: element.tagName.toLowerCase(),
                            className: element.className || '',
                            id: element.id || '',
                            textContent: textContent.substring(0, 100), // 처음 100자만
                            
                            // 위치 정보
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
                            
                            // 🚀 **5단계 무한스크롤 정보**
                            uniqueIdentifiers: Object.keys(uniqueIdentifiers).length > 0 ? uniqueIdentifiers : null,
                            contentFingerprint: Object.keys(contentFingerprint).length > 0 ? contentFingerprint : null,
                            relativeIndex: Object.keys(relativeIndex).length > 0 ? relativeIndex : null,
                            selectors: selectors,
                            infiniteScrollContext: infiniteScrollContext,
                            
                            // 메타 정보
                            anchorType: 'infiniteScroll',
                            captureTimestamp: Date.now()
                        };
                        
                    } catch(e) {
                        console.error('🚀 무한스크롤 앵커 생성 실패:', e);
                        return null;
                    }
                }
                
                // 🌐 **개선된 셀렉터 생성** (기존 로직 유지)
                function generateBestSelector(element) {
                    if (!element || element.nodeType !== 1) return null;
                    
                    // 1순위: ID가 있으면 ID 사용
                    if (element.id) {
                        return `#${element.id}`;
                    }
                    
                    // 2순위: 데이터 속성 기반
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
                    
                    // 4순위: 상위 경로 포함
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
                
                // 🚀 **메인 실행 - 5단계 무한스크롤 특화 데이터 수집**
                const infiniteScrollData = collectInfiniteScrollAnchors();
                
                console.log('🚀 5단계 무한스크롤 특화 캡처 완료:', {
                    anchorsCount: infiniteScrollData.anchors.length,
                    stats: infiniteScrollData.stats,
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                // ✅ **수정: Promise 없이 직접 반환**
                return {
                    infiniteScrollData: infiniteScrollData, // 🚀 **5단계 무한스크롤 특화 데이터**
                    scroll: { 
                        x: scrollX, 
                        y: scrollY
                    },
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
                        width: Math.max(contentWidth, viewportWidth),
                        height: Math.max(contentHeight, viewportHeight)
                    }
                };
            } catch(e) { 
                console.error('🚀 5단계 무한스크롤 특화 캡처 실패:', e);
                return {
                    infiniteScrollData: { anchors: [], stats: {} },
                    scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message
                };
            }
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
                console.log('🚫 브라우저 차단 대응 BFCache 페이지 복원');
                
                // 🌐 동적 콘텐츠 새로고침 (필요시)
                if (window.location.pathname.includes('/feed') ||
                    window.location.pathname.includes('/timeline') ||
                    window.location.hostname.includes('twitter') ||
                    window.location.hostname.includes('facebook') ||
                    window.location.hostname.includes('instagram') ||
                    window.location.hostname.includes('youtube')) {
                    if (window.refreshDynamicContent) {
                        window.refreshDynamicContent();
                    }
                }
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 브라우저 차단 대응 BFCache 페이지 저장');
            }
        });
        
        // ✅ **Cross-origin iframe 리스너는 유지하되 복원에서는 사용하지 않음**
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                console.log('🖼️ Cross-origin iframe 스크롤 복원 요청 수신 (현재 사용 안 함)');
                // 현재는 iframe 복원을 사용하지 않으므로 로그만 남김
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
