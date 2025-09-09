//
//  BFCacheSnapshotManager.swift
//  📸 **5단계 무한스크롤 특화 BFCache 페이지 스냅샷 및 복원 시스템**
//  🎯 **5단계 순차 시도 방식** - 고유식별자 → 콘텐츠지문 → 상대인덱스 → 기존셀렉터 → 무한스크롤트리거
//  🔧 **다중 뷰포트 앵커 시스템** - 주앵커 + 보조앵커 + 랜드마크 + 구조적 앵커
//  🐛 **디버깅 강화** - 실패 원인 정확한 추적과 로깅
//  🌐 **무한스크롤 특화** - 동적 콘텐츠 로드 대응 복원 지원
//  🔧 **범용 selector 확장** - 모든 사이트 호환 selector 패턴
//  🚫 **JavaScript 반환값 타입 오류 수정** - Swift 호환성 보장
//  ✅ **selector 문법 오류 수정** - 유효한 CSS selector만 사용
//  🎯 **앵커 복원 로직 수정** - 선택자 처리 및 허용 오차 개선
//  🔥 **앵커 우선순위 강화** - fallback 전에 앵커 먼저 시도
//  ✅ **Promise 제거** - 직접 실행으로 jsState 캡처 수정
//  🎯 **스크롤 위치 기반 앵커 선택 개선** - 실제 컨텐츠 요소 우선
//  🔧 **iframe 복원 제거** - 불필요한 단계 제거
//  ✅ **복원 검증 로직 수정** - 실제 스크롤 위치 정확 측정
//  🚀 **무한스크롤 5단계 순차 시도 방식 적용** - 모든 사이트 범용 대응
//  🎯 **실제 스크롤 컨테이너 감지** - window 대신 실제 스크롤 요소 탐지
//  🔧 **다중 스티키 헤더 보정** - 복합 고정 요소 높이 계산
//  🚀 **레이아웃 안정화 강화** - 충분한 대기시간과 재검증
//  📐 **퍼센트 기반 복원 활용** - 실제 스크롤 범위 대비 퍼센트 사용
//  🔍 **앵커 매칭 신뢰성 강화** - 동형 컨텐츠 오매칭 방지

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
            self.performBrowserBlockingWorkaround(to: webView, completion: completion)
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
    
    // 🚀 **핵심: 5단계 무한스크롤 특화 복원 JavaScript 생성 (문제점 수정)**
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
                
                // 🎯 **핵심 수정 1: 실제 스크롤 컨테이너 탐지**
                function detectRealScrollContainer() {
                    // 일반적인 스크롤 컨테이너 후보들
                    const scrollContainerSelectors = [
                        // 네이버 카페, 다음 카페 등 주요 사이트들
                        '#content-area', '.content_area', '#contentArea', '.contentArea',
                        '.main-content', '.main_content', '#main-content', '#main_content',
                        '.list_container', '.list-container', '#list_container', '#list-container',
                        '.feed-container', '.feed_container', '#feed-container', '#feed_container',
                        '.scroll-container', '.scroll_container', '#scroll-container', '#scroll_container',
                        
                        // 일반적인 스크롤 가능 영역들
                        '.scroll-area', '.scrollable', '#scrollable-area', '.viewport',
                        '.content-wrapper', '.content_wrapper', '.inner-content', '.inner_content',
                        '.article-list', '.post-list', '.item-list', '.thread-list',
                        
                        // 범용적 패턴들
                        '[data-testid*="scroll"]', '[class*="scroll"]', '[id*="scroll"]',
                        '[data-testid*="content"]', '[class*="content"]', '[id*="content"]',
                        '[data-testid*="list"]', '[class*="list"]', '[id*="list"]'
                    ];
                    
                    let realScrollContainer = null;
                    let maxScrollHeight = 0;
                    
                    for (const selector of scrollContainerSelectors) {
                        try {
                            const elements = document.querySelectorAll(selector);
                            for (const element of elements) {
                                const computedStyle = window.getComputedStyle(element);
                                const overflowY = computedStyle.overflowY;
                                const overflowX = computedStyle.overflowX;
                                
                                // 스크롤 가능한 요소인지 확인
                                if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                                    element.scrollHeight > element.clientHeight) {
                                    
                                    // 가장 큰 스크롤 높이를 가진 요소를 실제 컨테이너로 선택
                                    if (element.scrollHeight > maxScrollHeight) {
                                        maxScrollHeight = element.scrollHeight;
                                        realScrollContainer = element;
                                        console.log('🎯 실제 스크롤 컨테이너 발견:', selector, {
                                            scrollHeight: element.scrollHeight,
                                            clientHeight: element.clientHeight,
                                            overflowY: overflowY,
                                            overflowX: overflowX
                                        });
                                    }
                                }
                            }
                        } catch(e) {
                            // 개별 selector 오류는 무시
                        }
                    }
                    
                    // body나 document가 실제 스크롤 대상인 경우도 확인
                    const documentHeight = Math.max(
                        document.documentElement.scrollHeight,
                        document.body.scrollHeight
                    );
                    
                    if (!realScrollContainer && documentHeight > window.innerHeight) {
                        realScrollContainer = document.documentElement.scrollHeight >= document.body.scrollHeight 
                            ? document.documentElement 
                            : document.body;
                        console.log('🎯 기본 스크롤 컨테이너 사용:', realScrollContainer.tagName);
                    }
                    
                    return realScrollContainer;
                }
                
                // 🔧 **핵심 수정 2: 다중 스티키 헤더 보정**
                function calculateStickyOffset() {
                    const stickySelectors = [
                        // 네비게이션 바
                        '.navbar', '.nav-bar', '.navigation', '.header', '.top-bar',
                        '#navbar', '#nav-bar', '#navigation', '#header', '#top-bar',
                        
                        // 스티키 헤더들
                        '[style*="position: sticky"]', '[style*="position:sticky"]',
                        '[style*="position: fixed"]', '[style*="position:fixed"]',
                        '.sticky', '.fixed', '.pinned', '.floating',
                        
                        // 사이트별 공통 패턴들
                        '.gnb', '.lnb', '.tab', '.tabs', '.menu',
                        '[class*="sticky"]', '[class*="fixed"]', '[class*="float"]',
                        '[data-testid*="header"]', '[data-testid*="nav"]', '[data-testid*="bar"]'
                    ];
                    
                    let totalOffset = 0;
                    const stickyElements = [];
                    
                    for (const selector of stickySelectors) {
                        try {
                            const elements = document.querySelectorAll(selector);
                            for (const element of elements) {
                                const computedStyle = window.getComputedStyle(element);
                                const position = computedStyle.position;
                                
                                if (position === 'sticky' || position === 'fixed') {
                                    const rect = element.getBoundingClientRect();
                                    
                                    // 화면 상단에 고정된 요소만 계산
                                    if (rect.top >= 0 && rect.top <= 50 && rect.height > 0) {
                                        totalOffset += rect.height;
                                        stickyElements.push({
                                            element: element.tagName + (element.className ? '.' + element.className.split(' ')[0] : ''),
                                            height: rect.height,
                                            top: rect.top
                                        });
                                        console.log('🔧 스티키 요소 발견:', element.tagName, rect.height + 'px');
                                    }
                                }
                            }
                        } catch(e) {
                            // 개별 요소 오류는 무시
                        }
                    }
                    
                    console.log('🔧 총 스티키 오프셋:', totalOffset + 'px', stickyElements);
                    return { totalOffset: totalOffset, elements: stickyElements };
                }
                
                // 🚀 **5단계 무한스크롤 복원 시스템 구성**
                const STAGE_CONFIG = {
                    stage1: {
                        name: '고유식별자',
                        description: '고유 식별자 기반 복원 (href, data-* 속성)',
                        priority: 10,
                        tolerance: 50
                    },
                    stage2: {
                        name: '콘텐츠지문',
                        description: '콘텐츠 지문 기반 복원 (텍스트 + 구조 조합)',
                        priority: 8,
                        tolerance: 100
                    },
                    stage3: {
                        name: '상대인덱스',
                        description: '상대적 인덱스 기반 복원 (뷰포트 내 위치)',
                        priority: 6,
                        tolerance: 150
                    },
                    stage4: {
                        name: '기존셀렉터',
                        description: '기존 셀렉터 기반 복원 (CSS selector)',
                        priority: 4,
                        tolerance: 200
                    },
                    stage5: {
                        name: '퍼센트기반',
                        description: '퍼센트 기반 복원 + 무한스크롤 트리거',
                        priority: 2,
                        tolerance: 300
                    }
                };
                
                // 실제 스크롤 컨테이너와 스티키 오프셋 감지
                const realScrollContainer = detectRealScrollContainer();
                const stickyInfo = calculateStickyOffset();
                
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
                        const stageResult = tryStageRestore(stageNum, stageConfig, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo);
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
                function tryStageRestore(stageNum, config, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo) {
                    try {
                        console.log(`🔄 Stage ${stageNum} 복원 로직 실행`);
                        
                        switch(stageNum) {
                            case 1:
                                return tryUniqueIdentifierRestore(config, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo);
                            case 2:
                                return tryContentFingerprintRestore(config, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo);
                            case 3:
                                return tryRelativeIndexRestore(config, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo);
                            case 4:
                                return tryExistingSelectorRestore(config, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo);
                            case 5:
                                return tryPercentBasedRestore(config, targetX, targetY, targetPercentX, targetPercentY, realScrollContainer, stickyInfo);
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
                
                // 🚀 **Stage 1: 고유 식별자 기반 복원 (앵커 매칭 신뢰성 강화)**
                function tryUniqueIdentifierRestore(config, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo) {
                    try {
                        console.log('🚀 Stage 1: 고유 식별자 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        let foundElement = null;
                        let matchedAnchor = null;
                        let matchScore = 0;
                        
                        // 🔍 **신뢰성 강화: 여러 매칭 후보 중 가장 신뢰할 만한 것 선택**
                        for (const anchor of anchors) {
                            if (!anchor.uniqueIdentifiers) continue;
                            
                            const identifiers = anchor.uniqueIdentifiers;
                            let currentScore = 0;
                            let candidateElement = null;
                            
                            // href 패턴 매칭 (가장 높은 신뢰도)
                            if (identifiers.href) {
                                const hrefPattern = identifiers.href;
                                const elements = document.querySelectorAll(`a[href*="${hrefPattern}"]`);
                                if (elements.length === 1) { // 유일한 매칭만 신뢰
                                    candidateElement = elements[0];
                                    currentScore += 100;
                                } else if (elements.length > 0 && elements.length <= 3) {
                                    // 여러 매칭인 경우 추가 검증
                                    for (const elem of elements) {
                                        const elemText = elem.textContent || '';
                                        if (anchor.textContent && elemText.includes(anchor.textContent.substring(0, 30))) {
                                            candidateElement = elem;
                                            currentScore += 80;
                                            break;
                                        }
                                    }
                                }
                                console.log('🚀 Stage 1: href 패턴 체크:', hrefPattern, elements.length + '개', currentScore + '점');
                            }
                            
                            // data-* 속성 매칭 (높은 신뢰도)
                            if (!candidateElement && identifiers.dataAttributes) {
                                for (const [attr, value] of Object.entries(identifiers.dataAttributes)) {
                                    const elements = document.querySelectorAll(`[${attr}="${value}"]`);
                                    if (elements.length === 1) { // 유일한 매칭만 신뢰
                                        candidateElement = elements[0];
                                        currentScore += 90;
                                        console.log(`🚀 Stage 1: ${attr} 속성으로 유일 매칭:`, value, currentScore + '점');
                                        break;
                                    } else if (elements.length > 0) {
                                        console.log(`🚀 Stage 1: ${attr} 속성 다중 매칭:`, value, elements.length + '개 (스킵)');
                                    }
                                }
                            }
                            
                            // id 매칭 (최고 신뢰도)
                            if (!candidateElement && identifiers.id) {
                                const element = document.getElementById(identifiers.id);
                                if (element) {
                                    candidateElement = element;
                                    currentScore += 200;
                                    console.log('🚀 Stage 1: id로 유일 매칭:', identifiers.id, currentScore + '점');
                                }
                            }
                            
                            // 🔍 **추가 검증: 텍스트 내용 일치도**
                            if (candidateElement && anchor.textContent) {
                                const elemText = candidateElement.textContent || '';
                                const anchorText = anchor.textContent.substring(0, 50);
                                
                                if (elemText.includes(anchorText)) {
                                    currentScore += 50;
                                } else if (anchorText.length > 10 && elemText.includes(anchorText.substring(0, 20))) {
                                    currentScore += 20; // 부분 일치
                                } else {
                                    currentScore -= 30; // 텍스트 불일치 페널티
                                }
                            }
                            
                            // 최고 점수 후보 선택
                            if (candidateElement && currentScore > matchScore) {
                                foundElement = candidateElement;
                                matchedAnchor = anchor;
                                matchScore = currentScore;
                                console.log('🚀 Stage 1: 새로운 최고 점수 후보:', currentScore + '점');
                            }
                        }
                        
                        if (foundElement && matchedAnchor && matchScore >= 100) { // 최소 신뢰도 요구
                            // 스티키 헤더 보정하여 스크롤
                            performScrollToElement(foundElement, realScrollContainer, stickyInfo);
                            
                            return {
                                success: true,
                                method: 'unique_identifier',
                                anchorInfo: `identifier_${matchScore}점`,
                                debug: { 
                                    matchedIdentifier: matchedAnchor.uniqueIdentifiers,
                                    matchScore: matchScore,
                                    elementInfo: foundElement.tagName + (foundElement.id ? '#' + foundElement.id : '')
                                }
                            };
                        }
                        
                        return { 
                            success: false, 
                            error: `고유 식별자로 신뢰할 만한 요소를 찾을 수 없음 (최고점수: ${matchScore}점)` 
                        };
                        
                    } catch(e) {
                        return { success: false, error: `Stage 1 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 2: 콘텐츠 지문 기반 복원 (동형 컨텐츠 오매칭 방지)**
                function tryContentFingerprintRestore(config, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo) {
                    try {
                        console.log('🚀 Stage 2: 콘텐츠 지문 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        let foundElement = null;
                        let matchedAnchor = null;
                        let bestMatchScore = 0;
                        
                        for (const anchor of anchors) {
                            if (!anchor.contentFingerprint) continue;
                            
                            const fingerprint = anchor.contentFingerprint;
                            
                            // 🔍 **텍스트 패턴으로 요소 찾기 (정확도 강화)**
                            if (fingerprint.textSignature) {
                                const textPattern = fingerprint.textSignature;
                                const allElements = document.querySelectorAll('*');
                                
                                for (const element of allElements) {
                                    const elementText = (element.textContent || '').trim();
                                    
                                    // 정확한 텍스트 매칭 확인
                                    if (elementText.includes(textPattern)) {
                                        let matchScore = 0;
                                        
                                        // 🔍 **다중 검증으로 동형 컨텐츠 오매칭 방지**
                                        
                                        // 1. 텍스트 정확도
                                        if (elementText === textPattern) {
                                            matchScore += 100; // 완전 일치
                                        } else if (elementText.startsWith(textPattern)) {
                                            matchScore += 80; // 시작 부분 일치
                                        } else {
                                            matchScore += 40; // 부분 포함
                                        }
                                        
                                        // 2. 태그명 일치 검증
                                        if (fingerprint.tagName && element.tagName.toLowerCase() === fingerprint.tagName.toLowerCase()) {
                                            matchScore += 50;
                                        } else if (fingerprint.tagName) {
                                            matchScore -= 20; // 태그 불일치 페널티
                                        }
                                        
                                        // 3. 클래스명 일치 검증
                                        if (fingerprint.className && element.className.includes(fingerprint.className)) {
                                            matchScore += 30;
                                        } else if (fingerprint.className && fingerprint.className.length > 0) {
                                            matchScore -= 10; // 클래스 불일치 페널티
                                        }
                                        
                                        // 4. 시간 패턴 검증 (있는 경우)
                                        if (fingerprint.timePattern && elementText.includes(fingerprint.timePattern)) {
                                            matchScore += 40; // 시간 정보 일치 보너스
                                        }
                                        
                                        // 5. 위치 기반 검증 (너무 멀리 떨어진 요소 제외)
                                        const rect = element.getBoundingClientRect();
                                        const currentScrollY = realScrollContainer ? realScrollContainer.scrollTop : window.scrollY;
                                        const elementTop = currentScrollY + rect.top;
                                        
                                        const distanceFromTarget = Math.abs(elementTop - targetY);
                                        if (distanceFromTarget > window.innerHeight * 2) {
                                            matchScore -= 30; // 너무 멀리 있으면 페널티
                                        }
                                        
                                        // 🔍 **최고 점수 요소 선택**
                                        if (matchScore > bestMatchScore && matchScore >= 120) { // 최소 신뢰도
                                            bestMatchScore = matchScore;
                                            foundElement = element;
                                            matchedAnchor = anchor;
                                            console.log('🚀 Stage 2: 새로운 최고 점수 후보:', matchScore + '점', textPattern.substring(0, 30));
                                        }
                                    }
                                }
                            }
                        }
                        
                        if (foundElement && matchedAnchor) {
                            // 스티키 헤더 보정하여 스크롤
                            performScrollToElement(foundElement, realScrollContainer, stickyInfo);
                            
                            return {
                                success: true,
                                method: 'content_fingerprint',
                                anchorInfo: `fingerprint_${bestMatchScore}점`,
                                debug: { 
                                    matchedFingerprint: matchedAnchor.contentFingerprint,
                                    matchScore: bestMatchScore,
                                    elementInfo: foundElement.tagName + (foundElement.className ? '.' + foundElement.className.split(' ')[0] : '')
                                }
                            };
                        }
                        
                        return { 
                            success: false, 
                            error: `콘텐츠 지문으로 신뢰할 만한 요소를 찾을 수 없음 (최고점수: ${bestMatchScore}점)` 
                        };
                        
                    } catch(e) {
                        return { success: false, error: `Stage 2 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 3: 상대적 인덱스 기반 복원**
                function tryRelativeIndexRestore(config, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo) {
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
                            // 스티키 헤더 보정하여 스크롤
                            performScrollToElement(foundElement, realScrollContainer, stickyInfo);
                            
                            return {
                                success: true,
                                method: 'relative_index',
                                anchorInfo: `index_${matchedAnchor.relativeIndex?.indexInContainer || 'unknown'}`,
                                debug: { matchedIndex: matchedAnchor.relativeIndex }
                            };
                        }
                        
                        return { success: false, error: '상대적 인덱스로 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        return { success: false, error: `Stage 3 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 4: 기존 셀렉터 기반 복원 (유효성 검증 강화)**
                function tryExistingSelectorRestore(config, targetX, targetY, infiniteScrollData, realScrollContainer, stickyInfo) {
                    try {
                        console.log('🚀 Stage 4: 기존 셀렉터 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        let foundElement = null;
                        let matchedAnchor = null;
                        let usedSelector = '';
                        
                        for (const anchor of anchors) {
                            if (!anchor.selectors || !Array.isArray(anchor.selectors)) continue;
                            
                            const selectors = anchor.selectors;
                            
                            // 🔍 **각 셀렉터 순차 시도 (유효성 검증 강화)**
                            for (const selector of selectors) {
                                try {
                                    const elements = document.querySelectorAll(selector);
                                    
                                    // 🔍 **유일한 매칭만 신뢰**
                                    if (elements.length === 1) {
                                        const candidateElement = elements[0];
                                        
                                        // 추가 검증: 텍스트 내용 확인
                                        if (anchor.textContent) {
                                            const elemText = candidateElement.textContent || '';
                                            const anchorText = anchor.textContent.substring(0, 50);
                                            
                                            if (elemText.includes(anchorText)) {
                                                foundElement = candidateElement;
                                                matchedAnchor = anchor;
                                                usedSelector = selector;
                                                console.log('🚀 Stage 4: 기존 셀렉터로 유일 매칭:', selector);
                                                break;
                                            } else {
                                                console.log('🚀 Stage 4: 셀렉터 매칭되지만 텍스트 불일치:', selector);
                                            }
                                        } else {
                                            // 텍스트 검증 없이 매칭
                                            foundElement = candidateElement;
                                            matchedAnchor = anchor;
                                            usedSelector = selector;
                                            console.log('🚀 Stage 4: 기존 셀렉터로 유일 매칭 (텍스트 검증 없음):', selector);
                                            break;
                                        }
                                    } else if (elements.length > 1) {
                                        // 🔍 **다중 매칭인 경우 위치 기반으로 가장 가까운 것 선택**
                                        let closestElement = null;
                                        let minDistance = Infinity;
                                        
                                        for (const element of elements) {
                                            const rect = element.getBoundingClientRect();
                                            const currentScrollY = realScrollContainer ? realScrollContainer.scrollTop : window.scrollY;
                                            const elementTop = currentScrollY + rect.top;
                                            
                                            const distance = Math.abs(elementTop - targetY);
                                            if (distance < minDistance) {
                                                minDistance = distance;
                                                closestElement = element;
                                            }
                                        }
                                        
                                        if (closestElement && minDistance <= window.innerHeight) {
                                            // 추가 텍스트 검증
                                            if (anchor.textContent) {
                                                const elemText = closestElement.textContent || '';
                                                const anchorText = anchor.textContent.substring(0, 50);
                                                
                                                if (elemText.includes(anchorText)) {
                                                    foundElement = closestElement;
                                                    matchedAnchor = anchor;
                                                    usedSelector = selector;
                                                    console.log('🚀 Stage 4: 다중 매칭에서 가장 가까운 요소 선택:', selector, elements.length + '개 중');
                                                    break;
                                                }
                                            }
                                        }
                                        
                                        console.log('🚀 Stage 4: 다중 매칭 - 스킵:', selector, elements.length + '개');
                                    }
                                } catch(e) {
                                    // 셀렉터 오류는 무시하고 다음 시도
                                    console.log('🚀 Stage 4: 셀렉터 오류 - 스킵:', selector, e.message);
                                    continue;
                                }
                            }
                            
                            if (foundElement) break;
                        }
                        
                        if (foundElement && matchedAnchor) {
                            // 스티키 헤더 보정하여 스크롤
                            performScrollToElement(foundElement, realScrollContainer, stickyInfo);
                            
                            return {
                                success: true,
                                method: 'existing_selector',
                                anchorInfo: `selector_${usedSelector}`,
                                debug: { 
                                    matchedSelectors: matchedAnchor.selectors,
                                    usedSelector: usedSelector
                                }
                            };
                        }
                        
                        return { success: false, error: '기존 셀렉터로 신뢰할 만한 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        return { success: false, error: `Stage 4 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 5: 퍼센트 기반 복원 + 무한스크롤 트리거 (핵심 수정)**
                function tryPercentBasedRestore(config, targetX, targetY, targetPercentX, targetPercentY, realScrollContainer, stickyInfo) {
                    try {
                        console.log('🚀 Stage 5: 퍼센트 기반 복원 + 무한스크롤 트리거 시작');
                        
                        // 📐 **핵심 수정 3: 퍼센트 기반 복원 활용**
                        const currentContainer = realScrollContainer || document.documentElement;
                        const currentHeight = Math.max(
                            currentContainer.scrollHeight || 0,
                            document.documentElement.scrollHeight || 0,
                            document.body.scrollHeight || 0
                        );
                        
                        const viewportHeight = window.innerHeight;
                        const maxScrollY = Math.max(0, currentHeight - viewportHeight);
                        
                        // 퍼센트를 실제 스크롤 범위로 변환
                        let calculatedTargetY = targetY; // 기본값은 절대 좌표
                        
                        if (targetPercentY > 0 && maxScrollY > 0) {
                            calculatedTargetY = (targetPercentY / 100.0) * maxScrollY;
                            console.log('📐 퍼센트 기반 계산:', {
                                percent: targetPercentY + '%',
                                maxScrollY: maxScrollY,
                                calculated: calculatedTargetY,
                                original: targetY
                            });
                        }
                        
                        console.log('🚀 Stage 5: 현재 페이지 높이:', currentHeight, 'px, 목표 Y:', calculatedTargetY, 'px, 최대 스크롤:', maxScrollY, 'px');
                        
                        // 🚀 **레이아웃 안정화 강화: 충분한 무한스크롤 트리거**
                        if (calculatedTargetY > maxScrollY - viewportHeight * 0.1) { // 하단 90% 이상이면 트리거
                            console.log('🚀 Stage 5: 무한스크롤 트리거 필요 - 콘텐츠 로드 시도');
                            
                            // 무한스크롤 트리거 강화
                            const triggerSuccess = await performInfiniteScrollTrigger(currentContainer, calculatedTargetY);
                            
                            if (triggerSuccess) {
                                console.log('🚀 Stage 5: 무한스크롤 트리거 후 대기 시작');
                                
                                // 🚀 **레이아웃 안정화 대기 부족 해결: 충분한 대기 시간**
                                await new Promise(resolve => setTimeout(resolve, 2000)); // 2초 대기
                                
                                // 재계산된 높이로 다시 시도
                                const newHeight = Math.max(
                                    currentContainer.scrollHeight || 0,
                                    document.documentElement.scrollHeight || 0,
                                    document.body.scrollHeight || 0
                                );
                                
                                const newMaxScrollY = Math.max(0, newHeight - viewportHeight);
                                
                                if (targetPercentY > 0 && newMaxScrollY > 0) {
                                    calculatedTargetY = (targetPercentY / 100.0) * newMaxScrollY;
                                }
                                
                                console.log('🚀 Stage 5: 트리거 후 재계산:', {
                                    oldHeight: currentHeight,
                                    newHeight: newHeight,
                                    newMaxScrollY: newMaxScrollY,
                                    finalTarget: calculatedTargetY
                                });
                            }
                        }
                        
                        // 실제 스크롤 수행 (스티키 헤더 보정)
                        performScrollToPosition(calculatedTargetY, targetX, realScrollContainer, stickyInfo);
                        
                        return {
                            success: true,
                            method: 'percent_based',
                            anchorInfo: `percent_${targetPercentY.toFixed(1)}%`,
                            debug: { 
                                originalTarget: [targetX, targetY],
                                percentTarget: [targetX, calculatedTargetY],
                                percent: [targetPercentX, targetPercentY],
                                currentHeight: currentHeight,
                                maxScrollY: maxScrollY
                            }
                        };
                        
                    } catch(e) {
                        return { success: false, error: `Stage 5 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **무한스크롤 트리거 강화 함수**
                async function performInfiniteScrollTrigger(container, targetY) {
                    try {
                        let triggeredMethods = 0;
                        
                        // 1. 하단으로 스크롤하여 트리거
                        const currentMaxY = Math.max(0, (container.scrollHeight || 0) - window.innerHeight);
                        performScrollToPosition(currentMaxY, 0, container, {totalOffset: 0});
                        triggeredMethods++;
                        
                        await new Promise(resolve => setTimeout(resolve, 300));
                        
                        // 2. 스크롤 이벤트 강제 발생
                        window.dispatchEvent(new Event('scroll', { bubbles: true }));
                        window.dispatchEvent(new Event('resize', { bubbles: true }));
                        container.dispatchEvent(new Event('scroll', { bubbles: true }));
                        
                        // 3. 더보기 버튼 클릭
                        const loadMoreButtons = document.querySelectorAll(
                            '.load-more, .show-more, .infinite-scroll-trigger, ' +
                            '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                            '[data-role="load"], .btn-more, .more-btn, ' +
                            '[onclick*="more"], [onclick*="load"]'
                        );
                        
                        let clickedButtons = 0;
                        loadMoreButtons.forEach(btn => {
                            if (btn && typeof btn.click === 'function') {
                                try {
                                    btn.click();
                                    clickedButtons++;
                                    console.log('🚀 "더보기" 버튼 클릭:', btn.className || btn.tagName);
                                } catch(e) {}
                            }
                        });
                        
                        if (clickedButtons > 0) {
                            triggeredMethods++;
                        }
                        
                        // 4. 터치 이벤트 시뮬레이션
                        try {
                            const touchEvent = new TouchEvent('touchend', { bubbles: true });
                            document.dispatchEvent(touchEvent);
                            triggeredMethods++;
                        } catch(e) {}
                        
                        // 5. 인공 스크롤 반복 (일부 사이트는 스크롤 양에 반응)
                        for (let i = 0; i < 3; i++) {
                            performScrollToPosition(currentMaxY - 100 + (i * 50), 0, container, {totalOffset: 0});
                            await new Promise(resolve => setTimeout(resolve, 200));
                        }
                        
                        console.log('🚀 무한스크롤 트리거 완료:', triggeredMethods + '개 방법 시도');
                        return triggeredMethods > 0;
                        
                    } catch(e) {
                        console.error('🚀 무한스크롤 트리거 실패:', e);
                        return false;
                    }
                }
                
                // 🎯 **핵심 수정 4: 실제 컨테이너 기준 스크롤 함수**
                function performScrollToElement(element, realScrollContainer, stickyInfo) {
                    try {
                        const rect = element.getBoundingClientRect();
                        const container = realScrollContainer || document.documentElement;
                        
                        // 현재 스크롤 위치
                        const currentScrollY = container === document.documentElement ? window.scrollY : container.scrollTop;
                        const currentScrollX = container === document.documentElement ? window.scrollX : container.scrollLeft;
                        
                        // 타겟 위치 계산 (스티키 헤더 보정 포함)
                        const targetScrollY = currentScrollY + rect.top - stickyInfo.totalOffset - 20; // 20px 여유
                        const targetScrollX = currentScrollX + rect.left;
                        
                        performScrollToPosition(targetScrollY, targetScrollX, container, stickyInfo);
                        
                        console.log('🎯 요소 기준 스크롤:', {
                            element: element.tagName,
                            rect: [rect.left, rect.top, rect.width, rect.height],
                            stickyOffset: stickyInfo.totalOffset,
                            target: [targetScrollX, targetScrollY],
                            container: container === document.documentElement ? 'document' : container.tagName
                        });
                        
                    } catch(e) {
                        console.error('🎯 요소 기준 스크롤 실패:', e);
                    }
                }
                
                function performScrollToPosition(targetY, targetX, realScrollContainer, stickyInfo) {
                    try {
                        const container = realScrollContainer || document.documentElement;
                        const finalY = Math.max(0, targetY - stickyInfo.totalOffset);
                        const finalX = Math.max(0, targetX);
                        
                        if (container === document.documentElement) {
                            // 윈도우 스크롤
                            window.scrollTo(finalX, finalY);
                            document.documentElement.scrollTop = finalY;
                            document.documentElement.scrollLeft = finalX;
                            document.body.scrollTop = finalY;
                            document.body.scrollLeft = finalX;
                            
                            if (document.scrollingElement) {
                                document.scrollingElement.scrollTop = finalY;
                                document.scrollingElement.scrollLeft = finalX;
                            }
                        } else {
                            // 내부 컨테이너 스크롤
                            container.scrollTop = finalY;
                            container.scrollLeft = finalX;
                            
                            // 부드러운 스크롤 대신 즉시 스크롤
                            if (container.scrollTo) {
                                container.scrollTo(finalX, finalY);
                            }
                        }
                        
                        console.log('🎯 위치 기준 스크롤 수행:', {
                            original: [targetX, targetY],
                            stickyOffset: stickyInfo.totalOffset,
                            final: [finalX, finalY],
                            container: container === document.documentElement ? 'document' : container.tagName || 'element'
                        });
                        
                    } catch(e) {
                        console.error('🎯 위치 기준 스크롤 실패:', e);
                    }
                }
                
                // 🔧 **최종 결과 처리**
                if (!restoredByStage) {
                    // 모든 단계 실패 - 긴급 폴백
                    console.log('🚨 모든 5단계 실패 - 긴급 좌표 폴백');
                    performScrollToPosition(targetY, targetX, realScrollContainer, stickyInfo);
                    usedStage = 0;
                    usedMethod = 'emergency_coordinate';
                    anchorInfo = 'emergency';
                    errorMsg = '모든 5단계 복원 실패';
                }
                
                // 🔧 **복원 후 위치 검증 및 보정 (내부 컨테이너 검증 오류 수정)**
                setTimeout(() => {
                    try {
                        const container = realScrollContainer || document.documentElement;
                        
                        // ✅ **내부 컨테이너 검증 오류 수정: 실제 스크롤 요소 기준 검증**
                        const finalY = container === document.documentElement ? 
                            parseFloat(window.scrollY || window.pageYOffset || 0) : 
                            parseFloat(container.scrollTop || 0);
                        const finalX = container === document.documentElement ? 
                            parseFloat(window.scrollX || window.pageXOffset || 0) : 
                            parseFloat(container.scrollLeft || 0);
                            
                        const diffY = Math.abs(finalY - targetY);
                        const diffX = Math.abs(finalX - targetX);
                        
                        // 사용된 Stage의 허용 오차 적용
                        const stageConfig = usedStage > 0 ? STAGE_CONFIG[`stage${usedStage}`] : null;
                        const tolerance = stageConfig ? stageConfig.tolerance : 100;
                        
                        verificationResult = {
                            target: [targetX, targetY],
                            final: [finalX, finalY],
                            diff: [diffX, diffY],
                            stage: usedStage,
                            method: usedMethod,
                            tolerance: tolerance,
                            withinTolerance: diffX <= tolerance && diffY <= tolerance,
                            stageBased: restoredByStage,
                            actualRestoreDistance: Math.sqrt(diffX * diffX + diffY * diffY),
                            actualRestoreSuccess: diffY <= 50, // 50px 이내면 실제 성공으로 간주
                            containerType: container === document.documentElement ? 'document' : 'internal',
                            stickyOffset: stickyInfo.totalOffset
                        };
                        
                        console.log('🚀 5단계 복원 검증 (실제 컨테이너 기준):', verificationResult);
                        
                        if (verificationResult.actualRestoreSuccess) {
                            console.log(`✅ 실제 복원 성공: 목표=${targetY}px, 실제=${finalY}px, 차이=${diffY.toFixed(1)}px`);
                        } else {
                            console.log(`❌ 실제 복원 실패: 목표=${targetY}px, 실제=${finalY}px, 차이=${diffY.toFixed(1)}px`);
                        }
                        
                        // 🔧 **허용 오차 초과 시 점진적 보정**
                        if (!verificationResult.withinTolerance && (diffY > tolerance || diffX > tolerance)) {
                            console.log('🔧 허용 오차 초과 - 점진적 보정 시작:', verificationResult);
                            
                            const maxDiff = Math.max(diffX, diffY);
                            const steps = Math.min(5, Math.max(2, Math.ceil(maxDiff / 1000)));
                            const stepX = (targetX - finalX) / steps;
                            const stepY = (targetY - finalY) / steps;
                            
                            for (let i = 1; i <= steps; i++) {
                                setTimeout(() => {
                                    const stepTargetX = finalX + stepX * i;
                                    const stepTargetY = finalY + stepY * i;
                                    performScrollToPosition(stepTargetY, stepTargetX, container, stickyInfo);
                                    console.log(`🔧 점진적 보정 ${i}/${steps}:`, [stepTargetX, stepTargetY]);
                                }, i * 150);
                            }
                            
                            verificationResult.progressiveCorrection = {
                                steps: steps,
                                stepSize: [stepX, stepY],
                                reason: 'tolerance_exceeded'
                            };
                        }
                        
                    } catch(verifyError) {
                        verificationResult = {
                            error: verifyError.message,
                            stage: usedStage,
                            method: usedMethod
                        };
                        console.error('🚀 5단계 복원 검증 실패:', verifyError);
                    }
                }, 300); // 검증 대기 시간 증가
                
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
        })()
        """
    }
    
    // 🚫 **브라우저 차단 대응 시스템 (레이아웃 안정화 강화)**
    private func performBrowserBlockingWorkaround(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        TabPersistenceManager.debugMessages.append("🚫 브라우저 차단 대응 단계 구성 시작")
        
        // **1단계: 레이아웃 안정화 대기 강화**
        restoreSteps.append((1, { stepCompletion in
            let stabilizationDelay: TimeInterval = 1.5 // 🚀 **대기시간 증가: 0.1초 → 1.5초**
            TabPersistenceManager.debugMessages.append("🚀 1단계: 레이아웃 안정화 대기 강화 (대기: \(String(format: "%.1f", stabilizationDelay))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + stabilizationDelay) {
                let stabilizationJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        const targetPercentY = parseFloat('\(self.scrollPositionPercent.y)');
                        
                        console.log('🚀 레이아웃 안정화 대기 후 재검증:', {target: [targetX, targetY], percent: targetPercentY});
                        
                        // 🚀 **레이아웃 안정화 후 실제 컨테이너 재확인**
                        function redetectScrollContainer() {
                            const scrollContainerSelectors = [
                                '#content-area', '.content_area', '.main-content', '.list_container',
                                '.scroll-container', '.scrollable', '[class*="scroll"]', '[class*="content"]'
                            ];
                            
                            let realContainer = null;
                            let maxHeight = 0;
                            
                            for (const selector of scrollContainerSelectors) {
                                try {
                                    const elements = document.querySelectorAll(selector);
                                    for (const element of elements) {
                                        const style = window.getComputedStyle(element);
                                        if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                            element.scrollHeight > element.clientHeight) {
                                            if (element.scrollHeight > maxHeight) {
                                                maxHeight = element.scrollHeight;
                                                realContainer = element;
                                            }
                                        }
                                    }
                                } catch(e) {}
                            }
                            
                            return realContainer || document.documentElement;
                        }
                        
                        const container = redetectScrollContainer();
                        const isDocumentContainer = (container === document.documentElement);
                        
                        // 현재 위치 확인
                        const currentY = isDocumentContainer ? 
                            parseFloat(window.scrollY || window.pageYOffset || 0) : 
                            parseFloat(container.scrollTop || 0);
                        const currentX = isDocumentContainer ? 
                            parseFloat(window.scrollX || window.pageXOffset || 0) : 
                            parseFloat(container.scrollLeft || 0);
                            
                        // 컨테이너 높이 확인
                        const containerHeight = Math.max(
                            container.scrollHeight || 0,
                            isDocumentContainer ? document.documentElement.scrollHeight || 0 : 0,
                            isDocumentContainer ? document.body.scrollHeight || 0 : 0
                        );
                        
                        // 스티키 요소 재확인
                        let stickyOffset = 0;
                        document.querySelectorAll('[style*="position: sticky"], [style*="position:sticky"], [style*="position: fixed"], [style*="position:fixed"], .sticky, .fixed').forEach(el => {
                            const rect = el.getBoundingClientRect();
                            if (rect.top >= 0 && rect.top <= 50 && rect.height > 0) {
                                stickyOffset += rect.height;
                            }
                        });
                        
                        console.log('🚀 레이아웃 안정화 상태:', {
                            container: isDocumentContainer ? 'document' : container.tagName,
                            containerHeight: containerHeight,
                            current: [currentX, currentY],
                            stickyOffset: stickyOffset,
                            target: [targetX, targetY]
                        });
                        
                        // 🚀 **최종 위치 계산 (퍼센트 우선 사용)**
                        let finalTargetY = targetY;
                        if (targetPercentY > 0) {
                            const maxScrollY = Math.max(0, containerHeight - window.innerHeight);
                            if (maxScrollY > 0) {
                                finalTargetY = (targetPercentY / 100.0) * maxScrollY;
                                console.log('🚀 퍼센트 기반 최종 계산:', {
                                    percent: targetPercentY + '%',
                                    maxScrollY: maxScrollY,
                                    calculated: finalTargetY,
                                    original: targetY
                                });
                            }
                        }
                        
                        const adjustedTargetY = Math.max(0, finalTargetY - stickyOffset);
                        const adjustedTargetX = Math.max(0, targetX);
                        
                        // 스크롤 실행
                        if (isDocumentContainer) {
                            window.scrollTo(adjustedTargetX, adjustedTargetY);
                            document.documentElement.scrollTop = adjustedTargetY;
                            document.body.scrollTop = adjustedTargetY;
                            if (document.scrollingElement) {
                                document.scrollingElement.scrollTop = adjustedTargetY;
                            }
                        } else {
                            container.scrollTop = adjustedTargetY;
                            container.scrollLeft = adjustedTargetX;
                            if (container.scrollTo) {
                                container.scrollTo(adjustedTargetX, adjustedTargetY);
                            }
                        }
                        
                        console.log('🚀 레이아웃 안정화 후 스크롤 완료:', [adjustedTargetX, adjustedTargetY]);
                        
                        return {
                            success: true,
                            method: 'layout_stabilization',
                            containerType: isDocumentContainer ? 'document' : 'internal',
                            containerHeight: containerHeight,
                            finalTarget: [adjustedTargetX, adjustedTargetY],
                            stickyOffset: stickyOffset
                        };
                        
                    } catch(e) { 
                        console.error('🚀 레이아웃 안정화 실패:', e);
                        return {
                            success: false,
                            error: e.message
                        };
                    }
                })()
                """
                
                webView.evaluateJavaScript(stabilizationJS) { result, error in
                    var success = false
                    
                    if let error = error {
                        TabPersistenceManager.debugMessages.append("🚀 1단계 JavaScript 실행 오류: \(error.localizedDescription)")
                    } else if let resultDict = result as? [String: Any] {
                        success = (resultDict["success"] as? Bool) ?? false
                        
                        if let method = resultDict["method"] as? String {
                            TabPersistenceManager.debugMessages.append("🚀 1단계 사용된 방법: \(method)")
                        }
                        if let containerType = resultDict["containerType"] as? String {
                            TabPersistenceManager.debugMessages.append("🚀 1단계 컨테이너 타입: \(containerType)")
                        }
                        if let containerHeight = resultDict["containerHeight"] as? Double {
                            TabPersistenceManager.debugMessages.append("🚀 1단계 컨테이너 높이: \(String(format: "%.0f", containerHeight))px")
                        }
                        if let finalTarget = resultDict["finalTarget"] as? [Double] {
                            TabPersistenceManager.debugMessages.append("🚀 1단계 최종 타겟: X=\(String(format: "%.0f", finalTarget[0]))px, Y=\(String(format: "%.0f", finalTarget[1]))px")
                        }
                        if let stickyOffset = resultDict["stickyOffset"] as? Double {
                            TabPersistenceManager.debugMessages.append("🚀 1단계 스티키 오프셋: \(String(format: "%.0f", stickyOffset))px")
                        }
                        if let errorMsg = resultDict["error"] as? String {
                            TabPersistenceManager.debugMessages.append("🚀 1단계 오류: \(errorMsg)")
                        }
                    }
                    
                    TabPersistenceManager.debugMessages.append("🚀 1단계 레이아웃 안정화 완료: \(success ? "성공" : "실패")")
                    stepCompletion(success)
                }
            }
        }))
        
        // **2단계: 최종 확인 및 보정 (동적 허용치 적용)**
        restoreSteps.append((2, { stepCompletion in
            let waitTime: TimeInterval = 1.2 // 🚀 **대기시간 증가: 0.8초 → 1.2초**
            TabPersistenceManager.debugMessages.append("✅ 2단계: 최종 보정 강화 (대기: \(String(format: "%.1f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                let finalVerifyJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        const targetPercentY = parseFloat('\(self.scrollPositionPercent.y)');
                        
                        // 실제 컨테이너 재감지 (보강: scrollingElement 우선)
                        function getFinalScrollContainer() {
                            const candidates = document.querySelectorAll('#content-area, .content_area, .main-content, .list_container, .scroll-container, [class*="scroll"]');
                            
                            for (const candidate of candidates) {
                                const style = window.getComputedStyle(candidate);
                                if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                    candidate.scrollHeight > candidate.clientHeight) {
                                    return candidate;
                                }
                            }
                            
                            // 보강: scrollingElement 우선
                            return document.scrollingElement || document.documentElement;
                        }
                        
                        const container = getFinalScrollContainer();
                        const isDocumentContainer = (container === document.documentElement || container === document.scrollingElement);
                        
                        // ✅ **수정: 실제 스크롤 위치 정확 측정**
                        const dpr = window.devicePixelRatio || 1;
                        const viewportH = (window.visualViewport?.height || window.innerHeight) || 0;
                        const scrollingEl = document.scrollingElement || document.documentElement;
                        const containerHeight = isDocumentContainer
                          ? (scrollingEl?.scrollHeight || document.documentElement.scrollHeight || 0)
                          : (container.scrollHeight || 0);
                        
                        const currentX = isDocumentContainer ? 
                            parseFloat(window.scrollX || window.pageXOffset || 0) : 
                            parseFloat(container.scrollLeft || 0);
                        const currentY = isDocumentContainer ? 
                            parseFloat(window.scrollY || window.pageYOffset || 0) : 
                            parseFloat(container.scrollTop || 0);
                        
                        // 동적 허용 오차 계산
                        const rangeY = Math.max(0, containerHeight - viewportH);
                        
                        // 최소 2px*dpr, 최대 12px*dpr, 기본은 전체 범위의 0.5% 한도
                        const tolerance = Math.max(2*dpr, Math.min(0.005 * rangeY, 12*dpr));
                        
                        console.log('✅ 동적 허용 오차 계산:', {
                            dpr: dpr,
                            viewportH: viewportH,
                            containerHeight: containerHeight,
                            rangeY: rangeY,
                            tolerance: tolerance
                        });
                        
                        // 퍼센트 기반 타겟 재계산 (정확화)
                        let effectiveTargetY = targetY;
                        if (targetPercentY > 0) {
                            const totalH = isDocumentContainer
                                ? (scrollingEl?.scrollHeight || document.documentElement.scrollHeight || 0)
                                : (container.scrollHeight || 0);
                            const maxScrollY = Math.max(0, totalH - viewportH);
                            if (maxScrollY > 0) {
                                effectiveTargetY = Math.max(0, Math.min(maxScrollY, (targetPercentY / 100) * maxScrollY));
                            }
                        }
                        
                        // 서브픽셀 반올림 보정
                        const roundPx = v => Math.round(v * dpr) / dpr;
                        const diffX = Math.abs(roundPx(currentX) - roundPx(targetX));
                        const diffY = Math.abs(roundPx(currentY) - roundPx(effectiveTargetY));
                        const isWithinTolerance = diffX <= tolerance && diffY <= tolerance;
                        
                        console.log('✅ 최종 검증 (동적 허용치):', {
                            container: isDocumentContainer ? 'document' : container.tagName,
                            target: [targetX, effectiveTargetY],
                            current: [currentX, currentY],
                            diff: [diffX, diffY],
                            tolerance: tolerance,
                            withinTolerance: isWithinTolerance
                        });
                        
                        // 최종 보정 (필요시)
                        if (!isWithinTolerance) {
                            console.log('✅ 최종 보정 실행:', {current: [currentX, currentY], target: [targetX, effectiveTargetY]});
                            
                            // 스티키 재계산 (과잉합산 방지)
                            let finalStickyOffset = 0;
                            document.querySelectorAll('*').forEach(el => {
                                const style = window.getComputedStyle(el);
                                const pos = style.position;
                                if (pos === 'sticky' || pos === 'fixed') {
                                    const r = el.getBoundingClientRect();
                                    const visible = r.height > 0 && r.top <= 0 && r.bottom > 0;
                                    if (visible) finalStickyOffset = Math.max(finalStickyOffset, r.height);
                                }
                            });
                            
                            const finalY = Math.max(0, effectiveTargetY - finalStickyOffset);
                            const finalX = Math.max(0, targetX);
                            
                            // 즉시모드 스크롤 적용
                            const applyScroll = (y) => {
                                if (isDocumentContainer) {
                                    (window.scrollTo || window.scroll)(0, y); // instant
                                } else {
                                    container.scrollTop = y;
                                }
                            };
                            
                            applyScroll(finalY);
                            
                            // 재검증 루프
                            let retry = 2;
                            const verify = () => {
                                const nowY = isDocumentContainer ? (window.scrollY || window.pageYOffset || 0) : (container.scrollTop || 0);
                                if (Math.abs(roundPx(nowY) - roundPx(finalY)) > Math.max(1, 1*dpr) && retry-- > 0) {
                                    applyScroll(finalY);
                                    requestAnimationFrame(verify);
                                }
                            };
                            requestAnimationFrame(verify);
                        }
                        
                        // ✅ **최종 위치 정확 측정 및 기록**
                        const finalCurrentY = isDocumentContainer ? 
                            parseFloat(window.scrollY || window.pageYOffset || 0) : 
                            parseFloat(container.scrollTop || 0);
                        const finalCurrentX = isDocumentContainer ? 
                            parseFloat(window.scrollX || window.pageXOffset || 0) : 
                            parseFloat(container.scrollLeft || 0);
                        const finalDiffX = Math.abs(roundPx(finalCurrentX) - roundPx(targetX));
                        const finalDiffY = Math.abs(roundPx(finalCurrentY) - roundPx(effectiveTargetY));
                        const finalWithinTolerance = finalDiffX <= tolerance && finalDiffY <= tolerance;
                        
                        console.log('✅ 최종보정 완료:', {
                            container: isDocumentContainer ? 'document' : container.tagName,
                            current: [finalCurrentX, finalCurrentY],
                            target: [targetX, effectiveTargetY],
                            diff: [finalDiffX, finalDiffY],
                            tolerance: tolerance,
                            isWithinTolerance: finalWithinTolerance
                        });
                        
                        // ✅ **수정: 실제 복원 성공 여부 정확히 반환**
                        const actualRestoreSuccess = finalDiffY <= tolerance; // 동적 허용치 이내면 성공
                        
                        return {
                            success: actualRestoreSuccess, // ✅ 실제 복원 성공 여부
                            withinTolerance: finalWithinTolerance,
                            finalDiff: [finalDiffX, finalDiffY],
                            actualTarget: [targetX, effectiveTargetY],
                            actualFinal: [finalCurrentX, finalCurrentY],
                            actualRestoreSuccess: actualRestoreSuccess,
                            containerType: isDocumentContainer ? 'document' : 'internal',
                            tolerance: tolerance,
                            dpr: dpr
                        };
                    } catch(e) { 
                        console.error('✅ 최종보정 실패:', e);
                        return {
                            success: false,
                            error: e.message
                        };
                    }
                })()
                """
                
                webView.evaluateJavaScript(finalVerifyJS) { result, error in
                    if let error = error {
                        TabPersistenceManager.debugMessages.append("✅ 2단계 JavaScript 실행 오류: \(error.localizedDescription)")
                    }
                    
                    var success = false
                    if let resultDict = result as? [String: Any] {
                        // ✅ **수정: 실제 복원 성공 여부를 정확히 체크**
                        success = (resultDict["actualRestoreSuccess"] as? Bool) ?? false
                        
                        if let withinTolerance = resultDict["withinTolerance"] as? Bool {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 허용 오차 내: \(withinTolerance)")
                        }
                        if let finalDiff = resultDict["finalDiff"] as? [Double] {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 최종 차이: X=\(String(format: "%.1f", finalDiff[0]))px, Y=\(String(format: "%.1f", finalDiff[1]))px")
                        }
                        if let actualTarget = resultDict["actualTarget"] as? [Double],
                           let actualFinal = resultDict["actualFinal"] as? [Double] {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 실제 복원: 목표=\(String(format: "%.0f", actualTarget[1]))px → 실제=\(String(format: "%.0f", actualFinal[1]))px")
                        }
                        if let actualRestoreSuccess = resultDict["actualRestoreSuccess"] as? Bool {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 실제 복원 성공: \(actualRestoreSuccess)")
                        }
                        if let tolerance = resultDict["tolerance"] as? Double {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 동적 허용치: \(String(format: "%.2f", tolerance))px")
                        }
                        if let dpr = resultDict["dpr"] as? Double {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 DPR: \(String(format: "%.1f", dpr))")
                        }
                        if let containerType = resultDict["containerType"] as? String {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 최종 컨테이너: \(containerType)")
                        }
                        if let errorMsg = resultDict["error"] as? String {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 오류: \(errorMsg)")
                        }
                    } else {
                        success = false
                    }
                    
                    TabPersistenceManager.debugMessages.append("✅ 2단계 최종보정 완료: \(success ? "성공" : "실패")")
                    stepCompletion(success)
                }
            }
        }))
        
        TabPersistenceManager.debugMessages.append("🚫 총 \(restoreSteps.count)단계 브라우저 차단 대응 단계 구성 완료")
        
        // 단계별 실행
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                TabPersistenceManager.debugMessages.append("🚫 \(stepInfo.step)단계 실행 시작")
                
                let stepStart = Date()
                stepInfo.action { success in
                    let stepDuration = Date().timeIntervalSince(stepStart)
                    TabPersistenceManager.debugMessages.append("🚫 단계 \(stepInfo.step) 소요시간: \(String(format: "%.2f", stepDuration))초")
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > 0 // ✅ 수정: 하나라도 성공하면 성공
                
                TabPersistenceManager.debugMessages.append("🚫 브라우저 차단 대응 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                TabPersistenceManager.debugMessages.append("🚫 최종 결과: \(overallSuccess ? "✅ 성공" : "❌ 실패")")
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
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        guard let webView = task.webView else {
            TabPersistenceManager.debugMessages.append("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 특화 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
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
        
        // 📐 **실제 스크롤 범위 기반 상대적 위치 계산 (퍼센트)**
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.height > captureData.viewportSize.height {
            let maxScrollY = captureData.actualScrollableSize.height - captureData.viewportSize.height
            let maxScrollX = captureData.actualScrollableSize.width - captureData.viewportSize.width
            
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
}
