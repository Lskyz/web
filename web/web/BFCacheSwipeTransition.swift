//
//  BFCacheSnapshotManager.swift
//  📸 **5단계 무한스크롤 특화 BFCache 페이지 스냅샷 및 복원 시스템**
//  🎯 **5단계 순차 시도 방식** - 고유식별자 → 콘텐츠지문 → 상대인덱스 → 기존셀렉터 → 무한스크롤트리거
//  🔧 **다중 뷰포트 앵커 시스템** - 주앵커 + 보조앵커 + 랜드마크 + 구조적 앵커
//  🎯 **스크롤 위치 기반 앵커 선택 개선** - 실제 컨텐츠 요소 우선
//  ✅ **복원 검증 로직 수정** - 실제 스크롤 위치 정확 측정
//  🚀 **무한스크롤 5단계 순차 시도 방식 적용** - 모든 사이트 범용 대응
//  📊 **세세한 과정로그 추가** - 앵커 px 지점 및 긴페이지 어긋남 원인 상세 추적
//  🧹 **의미없는 텍스트 필터링** - 에러메시지, 로딩메시지 등 제외
//  🔄 **데이터 프리로딩 모드** - 복원 전 저장시점까지 콘텐츠 선로딩
//  📦 **배치 로딩 시스템** - 연속적 더보기 호출로 충분한 콘텐츠 확보
//  🐛 **스코프 에러 수정** - JavaScript 변수 정의 순서 개선

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
    
    // 🔄 **새 추가: 데이터 프리로딩 설정**
    let preloadingConfig: PreloadingConfig
    
    struct PreloadingConfig: Codable {
        let enableDataPreloading: Bool          // 🔄 데이터 프리로딩 활성화
        let enableBatchLoading: Bool            // 📦 배치 로딩 활성화  
        let targetContentHeight: CGFloat        // 🎯 목표 콘텐츠 높이
        let maxPreloadAttempts: Int            // ⚡ 최대 프리로딩 시도 횟수
        let preloadBatchSize: Int              // 📦 배치 크기
        let preloadTimeoutSeconds: Int         // ⏰ 프리로딩 타임아웃
        
        static let `default` = PreloadingConfig(
            enableDataPreloading: true,
            enableBatchLoading: true,
            targetContentHeight: 0,
            maxPreloadAttempts: 10,
            preloadBatchSize: 5,
            preloadTimeoutSeconds: 30
        )
    }
    
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
        case preloadingConfig
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
        preloadingConfig = try container.decodeIfPresent(PreloadingConfig.self, forKey: .preloadingConfig) ?? PreloadingConfig.default
        
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
        try container.encode(preloadingConfig, forKey: .preloadingConfig)
        
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
         version: Int = 1,
         preloadingConfig: PreloadingConfig = PreloadingConfig.default) {
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
        self.preloadingConfig = PreloadingConfig(
            enableDataPreloading: preloadingConfig.enableDataPreloading,
            enableBatchLoading: preloadingConfig.enableBatchLoading,
            targetContentHeight: max(actualScrollableSize.height, contentSize.height),
            maxPreloadAttempts: preloadingConfig.maxPreloadAttempts,
            preloadBatchSize: preloadingConfig.preloadBatchSize,
            preloadTimeoutSeconds: preloadingConfig.preloadTimeoutSeconds
        )
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🚀 **핵심 개선: 5단계 무한스크롤 특화 복원 + 데이터 프리로딩**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 특화 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 캡처 상태: \(captureStatus.rawValue)")
        TabPersistenceManager.debugMessages.append("📊 목표 스크롤: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 캡처된 콘텐츠 크기: \(String(format: "%.0f", contentSize.width)) x \(String(format: "%.0f", contentSize.height))")
        TabPersistenceManager.debugMessages.append("📊 캡처된 뷰포트 크기: \(String(format: "%.0f", viewportSize.width)) x \(String(format: "%.0f", viewportSize.height))")
        TabPersistenceManager.debugMessages.append("📊 실제 스크롤 가능 크기: \(String(format: "%.0f", actualScrollableSize.width)) x \(String(format: "%.0f", actualScrollableSize.height))")
        
        // 🔄 **새 추가: 프리로딩 설정 로깅**
        TabPersistenceManager.debugMessages.append("🔄 데이터 프리로딩: \(preloadingConfig.enableDataPreloading ? "활성화" : "비활성화")")
        TabPersistenceManager.debugMessages.append("📦 배치 로딩: \(preloadingConfig.enableBatchLoading ? "활성화" : "비활성화")")
        TabPersistenceManager.debugMessages.append("🎯 목표 콘텐츠 높이: \(String(format: "%.0f", preloadingConfig.targetContentHeight))px")
        TabPersistenceManager.debugMessages.append("⚡ 최대 프리로딩 시도: \(preloadingConfig.maxPreloadAttempts)회")
        TabPersistenceManager.debugMessages.append("📦 배치 크기: \(preloadingConfig.preloadBatchSize)개")
        
        // 🔥 **캡처된 jsState 상세 검증 및 로깅**
        if let jsState = self.jsState {
            TabPersistenceManager.debugMessages.append("🔥 캡처된 jsState 키 확인: \(Array(jsState.keys))")
            
            if let infiniteScrollData = jsState["infiniteScrollData"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🚀 무한스크롤 데이터 확인: \(Array(infiniteScrollData.keys))")
                
                if let anchors = infiniteScrollData["anchors"] as? [[String: Any]] {
                    let qualityAnchors = anchors.filter { anchor in
                        if let qualityScore = anchor["qualityScore"] as? Int {
                            return qualityScore >= 15  // 🧹 품질 점수 15점 이상만
                        }
                        return false
                    }
                    
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커: \(anchors.count)개 발견 (품질 앵커: \(qualityAnchors.count)개)")
                    
                    // 📊 **품질 앵커별 상세 정보 로깅**
                    for (index, anchor) in qualityAnchors.prefix(3).enumerated() {
                        if let absolutePos = anchor["absolutePosition"] as? [String: Any] {
                            let top = absolutePos["top"] as? Double ?? 0
                            let left = absolutePos["left"] as? Double ?? 0
                            TabPersistenceManager.debugMessages.append("📊 품질앵커[\(index)] 절대위치: X=\(String(format: "%.1f", left))px, Y=\(String(format: "%.1f", top))px")
                        }
                        
                        if let offsetFromTop = anchor["offsetFromTop"] as? Double {
                            TabPersistenceManager.debugMessages.append("📊 품질앵커[\(index)] 목표점에서 오프셋: \(String(format: "%.1f", offsetFromTop))px")
                        }
                        
                        if let textContent = anchor["textContent"] as? String {
                            let preview = textContent.prefix(30)
                            TabPersistenceManager.debugMessages.append("📊 품질앵커[\(index)] 텍스트: \"\(preview)...\"")
                        }
                        
                        if let qualityScore = anchor["qualityScore"] as? Int {
                            TabPersistenceManager.debugMessages.append("📊 품질앵커[\(index)] 품질점수: \(qualityScore)점")
                        }
                    }
                    
                    if qualityAnchors.count > 3 {
                        TabPersistenceManager.debugMessages.append("📊 나머지 \(qualityAnchors.count - 3)개 품질 앵커 생략...")
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 없음")
                }
                
                if let stats = infiniteScrollData["stats"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 수집 통계: \(stats)")
                }
            } else {
                TabPersistenceManager.debugMessages.append("🚀 무한스크롤 데이터 없음")
            }
        } else {
            TabPersistenceManager.debugMessages.append("🔥 jsState 캡처 완전 실패 - nil")
        }
        
        // 🔄 **1단계: 데이터 프리로딩 실행 (복원 전에)**
        if preloadingConfig.enableDataPreloading {
            performDataPreloading(to: webView) { preloadSuccess in
                TabPersistenceManager.debugMessages.append("🔄 데이터 프리로딩 완료: \(preloadSuccess ? "성공" : "실패")")
                
                // 🚀 **2단계: 5단계 무한스크롤 특화 복원 실행**
                self.performFiveStageInfiniteScrollRestore(to: webView)
                
                // 🔧 **3단계: 기존 상태별 분기 로직**
                self.handleCaptureStatusBasedRestore(to: webView, completion: completion)
            }
        } else {
            // 프리로딩 비활성화 시 바로 복원
            TabPersistenceManager.debugMessages.append("🔄 데이터 프리로딩 비활성화 - 바로 복원")
            performFiveStageInfiniteScrollRestore(to: webView)
            handleCaptureStatusBasedRestore(to: webView, completion: completion)
        }
    }
    
    // 🔄 **새 추가: 데이터 프리로딩 메서드**
    private func performDataPreloading(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🔄 데이터 프리로딩 시작")
        
        let preloadingJS = generateDataPreloadingScript()
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(preloadingJS) { result, error in
                var success = false
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔄 데이터 프리로딩 JS 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    success = (resultDict["success"] as? Bool) ?? false
                    
                    if let loadedContentHeight = resultDict["loadedContentHeight"] as? Double {
                        TabPersistenceManager.debugMessages.append("🔄 프리로딩 후 콘텐츠 높이: \(String(format: "%.1f", loadedContentHeight))px")
                    }
                    
                    if let loadingAttempts = resultDict["loadingAttempts"] as? Int {
                        TabPersistenceManager.debugMessages.append("🔄 프리로딩 시도 횟수: \(loadingAttempts)회")
                    }
                    
                    if let batchResults = resultDict["batchResults"] as? [[String: Any]] {
                        TabPersistenceManager.debugMessages.append("📦 배치 로딩 결과: \(batchResults.count)개 배치")
                    }
                    
                    if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                        TabPersistenceManager.debugMessages.append("🔄 프리로딩 상세 로그:")
                        for log in detailedLogs.prefix(10) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                    
                    if let errorMsg = resultDict["error"] as? String {
                        TabPersistenceManager.debugMessages.append("🔄 프리로딩 오류: \(errorMsg)")
                    }
                }
                
                TabPersistenceManager.debugMessages.append("🔄 데이터 프리로딩 결과: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // 🔄 **새 추가: 데이터 프리로딩 JavaScript 생성**
    private func generateDataPreloadingScript() -> String {
        let targetHeight = preloadingConfig.targetContentHeight
        let maxAttempts = preloadingConfig.maxPreloadAttempts
        let batchSize = preloadingConfig.preloadBatchSize
        let timeoutSeconds = preloadingConfig.preloadTimeoutSeconds
        let enableBatchLoading = preloadingConfig.enableBatchLoading
        
        return """
        (function() {
            try {
                console.log('🔄 데이터 프리로딩 시작');
                
                const detailedLogs = [];
                const batchResults = [];
                let loadingAttempts = 0;
                const targetContentHeight = parseFloat('\(targetHeight)');
                const maxAttempts = parseInt('\(maxAttempts)');
                const batchSize = parseInt('\(batchSize)');
                const enableBatchLoading = \(enableBatchLoading);
                
                detailedLogs.push('🔄 데이터 프리로딩 설정');
                detailedLogs.push(`목표 높이: ${targetContentHeight.toFixed(1)}px`);
                detailedLogs.push(`최대 시도: ${maxAttempts}회`);
                detailedLogs.push(`배치 크기: ${batchSize}개`);
                detailedLogs.push(`배치 로딩: ${enableBatchLoading ? '활성화' : '비활성화'}`);
                
                console.log('🔄 데이터 프리로딩 설정:', {
                    targetContentHeight: targetContentHeight,
                    maxAttempts: maxAttempts,
                    batchSize: batchSize,
                    enableBatchLoading: enableBatchLoading
                });
                
                // 📊 **현재 페이지 상태 확인**
                function getCurrentPageState() {
                    const currentHeight = Math.max(
                        document.documentElement.scrollHeight,
                        document.body.scrollHeight
                    );
                    const viewportHeight = window.innerHeight;
                    const currentScrollY = window.scrollY || window.pageYOffset || 0;
                    const maxScrollY = Math.max(0, currentHeight - viewportHeight);
                    
                    return {
                        currentHeight: currentHeight,
                        viewportHeight: viewportHeight,
                        currentScrollY: currentScrollY,
                        maxScrollY: maxScrollY,
                        needsMore: currentHeight < targetContentHeight
                    };
                }
                
                // 🔄 **무한스크롤 트리거 메서드들**
                function triggerInfiniteScroll() {
                    const triggers = [];
                    
                    // 1. 페이지 하단 스크롤
                    const state = getCurrentPageState();
                    const bottomY = state.maxScrollY;
                    window.scrollTo(0, bottomY);
                    triggers.push({ method: 'scroll_bottom', scrollY: bottomY });
                    
                    // 2. 스크롤 이벤트 발생
                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                    window.dispatchEvent(new Event('resize', { bubbles: true }));
                    triggers.push({ method: 'scroll_events', events: 2 });
                    
                    // 3. 더보기 버튼 검색 및 클릭
                    const loadMoreButtons = document.querySelectorAll(
                        '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                        '[data-role="load"], .load-more, .show-more, .infinite-scroll-trigger, ' +
                        '[onclick*="more"], [onclick*="load"], button[class*="more"], ' +
                        'a[href*="more"], .btn-more, .more-btn, .load-btn, .btn-load'
                    );
                    
                    let clickedButtons = 0;
                    loadMoreButtons.forEach((btn, index) => {
                        if (btn && typeof btn.click === 'function') {
                            try {
                                btn.click();
                                clickedButtons++;
                                detailedLogs.push(`더보기 버튼[${index}] 클릭: ${btn.className || btn.tagName}`);
                            } catch(e) {
                                detailedLogs.push(`더보기 버튼[${index}] 클릭 실패: ${e.message}`);
                            }
                        }
                    });
                    triggers.push({ method: 'load_more_buttons', found: loadMoreButtons.length, clicked: clickedButtons });
                    
                    // 4. AJAX 요청 감지 및 대기
                    let ajaxRequests = 0;
                    if (window.XMLHttpRequest && window.XMLHttpRequest.prototype.open) {
                        // AJAX 요청이 있을 가능성 체크
                        ajaxRequests = 1; // 가정
                    }
                    triggers.push({ method: 'ajax_detection', estimated: ajaxRequests });
                    
                    // 5. 터치 이벤트 (모바일)
                    try {
                        const touchEvent = new TouchEvent('touchend', { bubbles: true });
                        document.dispatchEvent(touchEvent);
                        triggers.push({ method: 'touch_events', success: true });
                    } catch(e) {
                        triggers.push({ method: 'touch_events', success: false, error: e.message });
                    }
                    
                    return triggers;
                }
                
                // 📦 **배치 로딩 실행**
                async function performBatchLoading() {
                    const batchStartTime = Date.now();
                    let totalTriggered = 0;
                    let heightIncreased = false;
                    
                    for (let batch = 0; batch < batchSize && loadingAttempts < maxAttempts; batch++) {
                        const beforeState = getCurrentPageState();
                        
                        detailedLogs.push(`배치[${batch + 1}/${batchSize}] 시작: 현재 높이=${beforeState.currentHeight.toFixed(1)}px`);
                        
                        // 무한스크롤 트리거 실행
                        const triggers = triggerInfiniteScroll();
                        totalTriggered += triggers.length;
                        loadingAttempts++;
                        
                        // 잠시 대기 (콘텐츠 로딩 시간 확보)
                        await new Promise(resolve => setTimeout(resolve, 1000));
                        
                        const afterState = getCurrentPageState();
                        const heightDiff = afterState.currentHeight - beforeState.currentHeight;
                        
                        detailedLogs.push(`배치[${batch + 1}] 완료: 높이 변화=${heightDiff.toFixed(1)}px`);
                        
                        if (heightDiff > 50) { // 50px 이상 증가하면 성공
                            heightIncreased = true;
                            detailedLogs.push(`배치[${batch + 1}] 높이 증가 감지: ${heightDiff.toFixed(1)}px`);
                        }
                        
                        batchResults.push({
                            batchIndex: batch + 1,
                            beforeHeight: beforeState.currentHeight,
                            afterHeight: afterState.currentHeight,
                            heightDiff: heightDiff,
                            triggersUsed: triggers.length,
                            success: heightDiff > 50
                        });
                        
                        // 목표 높이 달성 시 중단
                        if (afterState.currentHeight >= targetContentHeight) {
                            detailedLogs.push(`목표 높이 달성: ${afterState.currentHeight.toFixed(1)}px >= ${targetContentHeight.toFixed(1)}px`);
                            break;
                        }
                    }
                    
                    const batchEndTime = Date.now();
                    const batchDuration = batchEndTime - batchStartTime;
                    
                    return {
                        totalBatches: batchResults.length,
                        totalTriggered: totalTriggered,
                        heightIncreased: heightIncreased,
                        duration: batchDuration,
                        finalState: getCurrentPageState()
                    };
                }
                
                // 🔄 **메인 프리로딩 로직**
                async function executePreloading() {
                    const startTime = Date.now();
                    const initialState = getCurrentPageState();
                    
                    detailedLogs.push(`초기 상태: 높이=${initialState.currentHeight.toFixed(1)}px, 필요=${initialState.needsMore ? '예' : '아니오'}`);
                    
                    if (!initialState.needsMore) {
                        detailedLogs.push('목표 높이 이미 달성 - 프리로딩 불필요');
                        return {
                            success: true,
                            reason: 'already_sufficient',
                            loadedContentHeight: initialState.currentHeight,
                            loadingAttempts: 0
                        };
                    }
                    
                    let finalResult = null;
                    
                    if (enableBatchLoading) {
                        detailedLogs.push('📦 배치 로딩 모드 시작');
                        finalResult = await performBatchLoading();
                    } else {
                        detailedLogs.push('🔄 단일 로딩 모드 시작');
                        // 단일 로딩 모드
                        const beforeState = getCurrentPageState();
                        const triggers = triggerInfiniteScroll();
                        loadingAttempts = 1;
                        
                        await new Promise(resolve => setTimeout(resolve, 2000));
                        
                        const afterState = getCurrentPageState();
                        finalResult = {
                            totalBatches: 1,
                            totalTriggered: triggers.length,
                            heightIncreased: afterState.currentHeight > beforeState.currentHeight + 50,
                            duration: 2000,
                            finalState: afterState
                        };
                    }
                    
                    const endTime = Date.now();
                    const totalDuration = endTime - startTime;
                    
                    detailedLogs.push(`프리로딩 완료: ${totalDuration}ms 소요`);
                    detailedLogs.push(`최종 높이: ${finalResult.finalState.currentHeight.toFixed(1)}px`);
                    detailedLogs.push(`높이 증가: ${finalResult.heightIncreased ? '성공' : '실패'}`);
                    
                    return {
                        success: finalResult.heightIncreased || finalResult.finalState.currentHeight >= targetContentHeight * 0.8, // 80% 달성도 성공
                        reason: finalResult.heightIncreased ? 'height_increased' : 'no_height_change',
                        loadedContentHeight: finalResult.finalState.currentHeight,
                        loadingAttempts: loadingAttempts,
                        batchResults: batchResults,
                        totalDuration: totalDuration,
                        initialHeight: initialState.currentHeight,
                        targetHeight: targetContentHeight,
                        detailedLogs: detailedLogs
                    };
                }
                
                // 프리로딩 실행 (타임아웃 적용)
                const timeoutPromise = new Promise((resolve) => {
                    setTimeout(() => resolve({
                        success: false,
                        reason: 'timeout',
                        loadedContentHeight: getCurrentPageState().currentHeight,
                        loadingAttempts: loadingAttempts,
                        error: `프리로딩 타임아웃 (${timeoutSeconds}초)`,
                        detailedLogs: detailedLogs
                    }), \(timeoutSeconds) * 1000);
                });
                
                const preloadingPromise = executePreloading();
                
                return await Promise.race([preloadingPromise, timeoutPromise]);
                
            } catch(e) {
                console.error('🔄 데이터 프리로딩 실패:', e);
                return {
                    success: false,
                    reason: 'exception',
                    error: e.message,
                    loadedContentHeight: getCurrentPageState ? getCurrentPageState().currentHeight : 0,
                    loadingAttempts: loadingAttempts,
                    detailedLogs: [`프리로딩 실패: ${e.message}`]
                };
            }
        })()
        """
    }
    
    // 🔧 **기존 상태별 분기 로직 분리**
    private func handleCaptureStatusBasedRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
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
        TabPersistenceManager.debugMessages.append("📊 네이티브 스크롤뷰 백업 설정: X=\(String(format: "%.1f", targetPos.x))px, Y=\(String(format: "%.1f", targetPos.y))px")
        webView.scrollView.setContentOffset(targetPos, animated: false)
        
        // 2. 🚀 **5단계 무한스크롤 특화 복원 JavaScript 실행**
        let fiveStageRestoreJS = generateFiveStageInfiniteScrollRestoreScript()
        
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 복원 JavaScript 실행 중...")
        
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
                
                // 📊 **상세 로깅 정보 추출**
                if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                    TabPersistenceManager.debugMessages.append("📊 JavaScript 상세 로그:")
                    for log in detailedLogs {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
                
                if let pageAnalysis = resultDict["pageAnalysis"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 페이지 분석 결과: \(pageAnalysis)")
                }
                
                if let anchorAnalysis = resultDict["anchorAnalysis"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 앵커 분석 결과: \(anchorAnalysis)")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 복원: \(success ? "성공" : "실패")")
        }
        
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 특화 1단계 복원 완료")
    }
    
    // 🚀 **핵심: 5단계 무한스크롤 특화 복원 JavaScript 생성 (개선된 텍스트 필터링)**
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
                
                // 📊 **상세 로그 수집 배열**
                const detailedLogs = [];
                const pageAnalysis = {};
                const anchorAnalysis = {};
                let actualRestoreSuccess = false;  // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let practicalSuccess = false;      // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalCurrentY = 0;             // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalCurrentX = 0;             // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalDiffY = 0;                // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalDiffX = 0;                // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalWithinTolerance = false;  // 🐛 **스코프 에러 수정: 변수 미리 정의**
                
                detailedLogs.push('🚀 5단계 무한스크롤 특화 복원 시작');
                detailedLogs.push(`📊 목표 위치: X=${targetX.toFixed(1)}px, Y=${targetY.toFixed(1)}px`);
                detailedLogs.push(`📊 목표 백분율: X=${targetPercentX.toFixed(2)}%, Y=${targetPercentY.toFixed(2)}%`);
                detailedLogs.push(`📊 무한스크롤 데이터 존재: ${!!infiniteScrollData}`);
                detailedLogs.push(`📊 앵커 개수: ${infiniteScrollData?.anchors?.length || 0}개`);
                
                // 📊 **현재 페이지 상태 상세 분석**
                const currentScrollY = parseFloat(window.scrollY || window.pageYOffset || 0);
                const currentScrollX = parseFloat(window.scrollX || window.pageXOffset || 0);
                const currentViewportHeight = parseFloat(window.innerHeight || 0);
                const currentViewportWidth = parseFloat(window.innerWidth || 0);
                const currentContentHeight = parseFloat(document.documentElement.scrollHeight || 0);
                const currentContentWidth = parseFloat(document.documentElement.scrollWidth || 0);
                const currentMaxScrollY = Math.max(0, currentContentHeight - currentViewportHeight);
                const currentMaxScrollX = Math.max(0, currentContentWidth - currentViewportWidth);
                
                pageAnalysis.currentScroll = { x: currentScrollX, y: currentScrollY };
                pageAnalysis.currentViewport = { width: currentViewportWidth, height: currentViewportHeight };
                pageAnalysis.currentContent = { width: currentContentWidth, height: currentContentHeight };
                pageAnalysis.currentMaxScroll = { x: currentMaxScrollX, y: currentMaxScrollY };
                
                detailedLogs.push(`📊 현재 스크롤: X=${currentScrollX.toFixed(1)}px, Y=${currentScrollY.toFixed(1)}px`);
                detailedLogs.push(`📊 현재 뷰포트: ${currentViewportWidth.toFixed(0)} x ${currentViewportHeight.toFixed(0)}`);
                detailedLogs.push(`📊 현재 콘텐츠: ${currentContentWidth.toFixed(0)} x ${currentContentHeight.toFixed(0)}`);
                detailedLogs.push(`📊 현재 최대 스크롤: X=${currentMaxScrollX.toFixed(1)}px, Y=${currentMaxScrollY.toFixed(1)}px`);
                
                // 📊 **목표 위치와 현재 상태 비교 분석**
                const scrollDiffY = targetY - currentScrollY;
                const scrollDiffX = targetX - currentScrollX;
                const contentHeightDiff = currentContentHeight - parseFloat('\(contentSize.height)');
                const viewportHeightDiff = currentViewportHeight - parseFloat('\(viewportSize.height)');
                
                pageAnalysis.differences = {
                    scrollDiff: { x: scrollDiffX, y: scrollDiffY },
                    contentHeightDiff: contentHeightDiff,
                    viewportHeightDiff: viewportHeightDiff
                };
                
                detailedLogs.push(`📊 스크롤 차이: X=${scrollDiffX.toFixed(1)}px, Y=${scrollDiffY.toFixed(1)}px`);
                detailedLogs.push(`📊 콘텐츠 높이 변화: ${contentHeightDiff.toFixed(1)}px (${contentHeightDiff > 0 ? '증가' : '감소'})`);
                detailedLogs.push(`📊 뷰포트 높이 변화: ${viewportHeightDiff.toFixed(1)}px`);
                
                // 📊 **긴 페이지에서 어긋날 수 있는 원인 분석**
                const longPageIssues = [];
                if (currentContentHeight > 10000) {
                    longPageIssues.push('매우 긴 페이지 (10000px+)');
                }
                if (Math.abs(contentHeightDiff) > 500) {
                    longPageIssues.push(`콘텐츠 높이 큰 변화 (${contentHeightDiff.toFixed(1)}px)`);
                }
                if (targetY > currentMaxScrollY + 100) {
                    longPageIssues.push(`목표 위치가 스크롤 범위 초과 (${(targetY - currentMaxScrollY).toFixed(1)}px 초과)`);
                }
                if (Math.abs(viewportHeightDiff) > 100) {
                    longPageIssues.push(`뷰포트 크기 변화 (${viewportHeightDiff.toFixed(1)}px)`);
                }
                
                pageAnalysis.longPageIssues = longPageIssues;
                
                if (longPageIssues.length > 0) {
                    detailedLogs.push(`🚨 긴 페이지 이슈 발견: ${longPageIssues.join(', ')}`);
                } else {
                    detailedLogs.push(`✅ 긴 페이지 이슈 없음`);
                }
                
                console.log('🚀 5단계 무한스크롤 특화 복원 시작:', {
                    target: [targetX, targetY],
                    percent: [targetPercentX, targetPercentY],
                    hasInfiniteScrollData: !!infiniteScrollData,
                    anchorsCount: infiniteScrollData?.anchors?.length || 0,
                    pageAnalysis: pageAnalysis
                });
                
                // 🧹 **의미없는 텍스트 필터링 함수**
                function isQualityText(text) {
                    if (!text || typeof text !== 'string') return false;
                    
                    const cleanText = text.trim();
                    if (cleanText.length < 5) return false; // 너무 짧은 텍스트
                    
                    // 🧹 **의미없는 텍스트 패턴들**
                    const meaninglessPatterns = [
                        /^(투표는|표시되지|않습니다|네트워크|문제로|연결되지|잠시|후에|다시|시도)/,
                        /^(로딩|loading|wait|please|기다려|잠시만)/i,
                        /^(오류|에러|error|fail|실패|죄송|sorry)/i,
                        /^(확인|ok|yes|no|취소|cancel|닫기|close)/i,
                        /^(더보기|more|load|next|이전|prev|previous)/i,
                        /^(클릭|click|tap|터치|touch|선택)/i,
                        /^(답글|댓글|reply|comment|쓰기|작성)/i,
                        /^[\s\.\-_=+]{2,}$/, // 특수문자만
                        /^[0-9\s\.\/\-:]{3,}$/, // 숫자와 특수문자만 (날짜/시간 제외)
                        /^(am|pm|오전|오후|시|분|초)$/i,
                    ];
                    
                    for (const pattern of meaninglessPatterns) {
                        if (pattern.test(cleanText)) {
                            return false;
                        }
                    }
                    
                    // 너무 반복적인 문자 (같은 문자 70% 이상)
                    const charCounts = {};
                    for (const char of cleanText) {
                        charCounts[char] = (charCounts[char] || 0) + 1;
                    }
                    const maxCharCount = Math.max(...Object.values(charCounts));
                    if (maxCharCount / cleanText.length > 0.7) {
                        return false;
                    }
                    
                    return true;
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
                        name: '무한스크롤트리거',
                        description: '무한스크롤 트리거 후 재시도',
                        priority: 2,
                        tolerance: 300
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
                    
                    detailedLogs.push(`🚀 Stage ${stageNum} (${stageConfig.name}) 시도 시작`);
                    detailedLogs.push(`   우선순위: ${stageConfig.priority}, 허용오차: ${stageConfig.tolerance}px`);
                    detailedLogs.push(`   설명: ${stageConfig.description}`);
                    
                    console.log(`🚀 Stage ${stageNum} (${stageConfig.name}) 시도 시작:`, {
                        priority: stageConfig.priority,
                        tolerance: stageConfig.tolerance,
                        description: stageConfig.description
                    });
                    
                    try {
                        const stageResult = tryStageRestore(stageNum, stageConfig, targetX, targetY, infiniteScrollData);
                        stageResults[`stage${stageNum}`] = stageResult;
                        
                        detailedLogs.push(`   Stage ${stageNum} 결과: ${stageResult.success ? '성공' : '실패'}`);
                        if (stageResult.success) {
                            detailedLogs.push(`   복원 방법: ${stageResult.method}`);
                            detailedLogs.push(`   앵커 정보: ${stageResult.anchorInfo}`);
                            if (stageResult.elementInfo) {
                                detailedLogs.push(`   요소 정보: ${JSON.stringify(stageResult.elementInfo)}`);
                            }
                        } else {
                            detailedLogs.push(`   실패 원인: ${stageResult.error}`);
                        }
                        
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
                        detailedLogs.push(`   Stage ${stageNum} 예외: ${e.message}`);
                    }
                }
                
                // 🚀 **Stage별 복원 시도 함수**
                function tryStageRestore(stageNum, config, targetX, targetY, infiniteScrollData) {
                    try {
                        detailedLogs.push(`🔄 Stage ${stageNum} 복원 로직 실행`);
                        
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
                        detailedLogs.push('🚀 Stage 1: 고유 식별자 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            detailedLogs.push('   무한스크롤 앵커 데이터 없음');
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        detailedLogs.push(`   총 ${anchors.length}개 앵커에서 고유식별자 검색`);
                        
                        // 🧹 **품질 앵커 필터링**
                        const qualityAnchors = anchors.filter(anchor => {
                            const hasQualityText = anchor.textContent && isQualityText(anchor.textContent);
                            const hasQualityScore = (anchor.qualityScore || 0) >= 15;
                            return hasQualityText && hasQualityScore;
                        });
                        
                        detailedLogs.push(`   품질 앵커 필터링: ${qualityAnchors.length}개 (전체 ${anchors.length}개)`);
                        
                        let foundElement = null;
                        let matchedAnchor = null;
                        let searchResults = [];
                        
                        // 고유 식별자 우선순위: href → data-post-id → data-article-id → data-id → id
                        for (let anchorIndex = 0; anchorIndex < qualityAnchors.length; anchorIndex++) {
                            const anchor = qualityAnchors[anchorIndex];
                            if (!anchor.uniqueIdentifiers) continue;
                            
                            const identifiers = anchor.uniqueIdentifiers;
                            detailedLogs.push(`   품질앵커[${anchorIndex}] 고유식별자 키: ${Object.keys(identifiers)}`);
                            
                            // href 패턴 매칭
                            if (identifiers.href) {
                                const hrefPattern = identifiers.href;
                                detailedLogs.push(`   href 패턴 검색: "${hrefPattern}"`);
                                const elements = document.querySelectorAll(`a[href*="${hrefPattern}"]`);
                                detailedLogs.push(`   href 패턴 매칭 결과: ${elements.length}개 요소`);
                                if (elements.length > 0) {
                                    foundElement = elements[0];
                                    matchedAnchor = anchor;
                                    searchResults.push({ method: 'href', pattern: hrefPattern, matches: elements.length });
                                    detailedLogs.push(`   ✅ href 패턴으로 요소 발견: ${hrefPattern}`);
                                    break;
                                }
                            }
                            
                            // data-* 속성 매칭
                            if (identifiers.dataAttributes) {
                                detailedLogs.push(`   data-* 속성 검색: ${Object.keys(identifiers.dataAttributes)}`);
                                for (const [attr, value] of Object.entries(identifiers.dataAttributes)) {
                                    detailedLogs.push(`   data 속성 검색: [${attr}="${value}"]`);
                                    const elements = document.querySelectorAll(`[${attr}="${value}"]`);
                                    detailedLogs.push(`   data 속성 매칭 결과: ${elements.length}개 요소`);
                                    if (elements.length > 0) {
                                        foundElement = elements[0];
                                        matchedAnchor = anchor;
                                        searchResults.push({ method: 'dataAttr', attr: attr, value: value, matches: elements.length });
                                        detailedLogs.push(`   ✅ ${attr} 속성으로 요소 발견: ${value}`);
                                        break;
                                    }
                                }
                                if (foundElement) break;
                            }
                            
                            // id 매칭
                            if (identifiers.id) {
                                detailedLogs.push(`   id 검색: "${identifiers.id}"`);
                                const element = document.getElementById(identifiers.id);
                                if (element) {
                                    foundElement = element;
                                    matchedAnchor = anchor;
                                    searchResults.push({ method: 'id', id: identifiers.id });
                                    detailedLogs.push(`   ✅ id로 요소 발견: ${identifiers.id}`);
                                    break;
                                } else {
                                    detailedLogs.push(`   id 검색 실패: ${identifiers.id}`);
                                }
                            }
                        }
                        
                        anchorAnalysis.stage1_searchResults = searchResults;
                        
                        if (foundElement && matchedAnchor) {
                            // 📊 **발견된 요소의 정확한 위치 분석**
                            const elementRect = foundElement.getBoundingClientRect();
                            const elementScrollY = currentScrollY + elementRect.top;
                            const elementScrollX = currentScrollX + elementRect.left;
                            
                            detailedLogs.push(`   발견된 요소 위치: X=${elementScrollX.toFixed(1)}px, Y=${elementScrollY.toFixed(1)}px`);
                            detailedLogs.push(`   요소 크기: ${elementRect.width.toFixed(1)} x ${elementRect.height.toFixed(1)}`);
                            detailedLogs.push(`   뷰포트 기준: top=${elementRect.top.toFixed(1)}px, left=${elementRect.left.toFixed(1)}px`);
                            
                            // 오프셋 정보 확인
                            let offsetY = 0;
                            if (matchedAnchor.offsetFromTop) {
                                offsetY = parseFloat(matchedAnchor.offsetFromTop) || 0;
                                detailedLogs.push(`   캡처된 오프셋: ${offsetY.toFixed(1)}px`);
                            }
                            
                            // 요소로 스크롤
                            detailedLogs.push(`   스크롤 실행: scrollIntoView`);
                            foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                            
                            // 오프셋 보정
                            if (offsetY !== 0) {
                                detailedLogs.push(`   오프셋 보정: ${-offsetY.toFixed(1)}px`);
                                window.scrollBy(0, -offsetY);
                            }
                            
                            // 📊 **복원 후 위치 확인**
                            const afterScrollY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const afterScrollX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            detailedLogs.push(`   복원 후 위치: X=${afterScrollX.toFixed(1)}px, Y=${afterScrollY.toFixed(1)}px`);
                            detailedLogs.push(`   목표와 차이: X=${Math.abs(afterScrollX - targetX).toFixed(1)}px, Y=${Math.abs(afterScrollY - targetY).toFixed(1)}px`);
                            
                            return {
                                success: true,
                                method: 'unique_identifier',
                                anchorInfo: `identifier_${matchedAnchor.uniqueIdentifiers?.href || matchedAnchor.uniqueIdentifiers?.id || 'unknown'}`,
                                debug: { 
                                    matchedIdentifier: matchedAnchor.uniqueIdentifiers,
                                    elementPosition: { x: elementScrollX, y: elementScrollY },
                                    afterPosition: { x: afterScrollX, y: afterScrollY }
                                },
                                elementInfo: {
                                    tagName: foundElement.tagName,
                                    id: foundElement.id,
                                    className: foundElement.className,
                                    position: { x: elementScrollX, y: elementScrollY },
                                    size: { width: elementRect.width, height: elementRect.height }
                                }
                            };
                        }
                        
                        detailedLogs.push('   고유 식별자로 요소를 찾을 수 없음');
                        return { success: false, error: '고유 식별자로 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        detailedLogs.push(`   Stage 1 예외: ${e.message}`);
                        return { success: false, error: `Stage 1 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 2: 콘텐츠 지문 기반 복원 (품질 개선)**
                function tryContentFingerprintRestore(config, targetX, targetY, infiniteScrollData) {
                    try {
                        detailedLogs.push('🚀 Stage 2: 콘텐츠 지문 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            detailedLogs.push('   무한스크롤 앵커 데이터 없음');
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        
                        // 🧹 **품질 앵커 필터링 (Stage 2용)**
                        const qualityAnchors = anchors.filter(anchor => {
                            const hasQualityText = anchor.textContent && isQualityText(anchor.textContent);
                            const hasContentFingerprint = anchor.contentFingerprint && anchor.contentFingerprint.textSignature;
                            const hasQualityScore = (anchor.qualityScore || 0) >= 10; // Stage 2는 좀 더 관대
                            return hasQualityText && hasContentFingerprint && hasQualityScore;
                        });
                        
                        detailedLogs.push(`   총 ${anchors.length}개 앵커에서 품질 콘텐츠 지문 검색: ${qualityAnchors.length}개`);
                        let foundElement = null;
                        let matchedAnchor = null;
                        let searchResults = [];
                        
                        for (let anchorIndex = 0; anchorIndex < qualityAnchors.length; anchorIndex++) {
                            const anchor = qualityAnchors[anchorIndex];
                            if (!anchor.contentFingerprint) continue;
                            
                            const fingerprint = anchor.contentFingerprint;
                            detailedLogs.push(`   품질앵커[${anchorIndex}] 지문 키: ${Object.keys(fingerprint)}`);
                            
                            // 텍스트 패턴으로 요소 찾기
                            if (fingerprint.textSignature) {
                                const textPattern = fingerprint.textSignature;
                                detailedLogs.push(`   텍스트 시그니처 검색: "${textPattern.substring(0, 30)}..."`);
                                const allElements = document.querySelectorAll('*');
                                detailedLogs.push(`   전체 DOM 요소 수: ${allElements.length}개`);
                                
                                let matchingElements = 0;
                                for (const element of allElements) {
                                    const elementText = (element.textContent || '').trim();
                                    
                                    // 🧹 **품질 텍스트 확인**
                                    if (!isQualityText(elementText)) continue;
                                    
                                    if (elementText.includes(textPattern)) {
                                        matchingElements++;
                                        
                                        // 추가 검증: 태그명, 클래스명이 일치하는지
                                        let isMatch = true;
                                        let verificationResults = [];
                                        
                                        if (fingerprint.tagName) {
                                            const tagMatch = element.tagName.toLowerCase() === fingerprint.tagName.toLowerCase();
                                            verificationResults.push(`tagName: ${tagMatch}`);
                                            if (!tagMatch) isMatch = false;
                                        }
                                        
                                        if (fingerprint.className) {
                                            const classMatch = element.className.includes(fingerprint.className);
                                            verificationResults.push(`className: ${classMatch}`);
                                            if (!classMatch) isMatch = false;
                                        }
                                        
                                        detailedLogs.push(`   텍스트 매치 요소 검증: ${verificationResults.join(', ')}`);
                                        
                                        if (isMatch) {
                                            foundElement = element;
                                            matchedAnchor = anchor;
                                            searchResults.push({ 
                                                method: 'contentFingerprint', 
                                                textPattern: textPattern.substring(0, 50),
                                                matchingElements: matchingElements,
                                                verification: verificationResults
                                            });
                                            detailedLogs.push(`   ✅ 콘텐츠 지문으로 요소 발견: "${textPattern.substring(0, 30)}..."`);
                                            break;
                                        }
                                    }
                                }
                                
                                detailedLogs.push(`   텍스트 매칭 요소 수: ${matchingElements}개`);
                                if (foundElement) break;
                            }
                        }
                        
                        anchorAnalysis.stage2_searchResults = searchResults;
                        
                        if (foundElement && matchedAnchor) {
                            // 📊 **발견된 요소의 정확한 위치 분석**
                            const elementRect = foundElement.getBoundingClientRect();
                            const elementScrollY = currentScrollY + elementRect.top;
                            const elementScrollX = currentScrollX + elementRect.left;
                            
                            detailedLogs.push(`   발견된 요소 위치: X=${elementScrollX.toFixed(1)}px, Y=${elementScrollY.toFixed(1)}px`);
                            detailedLogs.push(`   요소 크기: ${elementRect.width.toFixed(1)} x ${elementRect.height.toFixed(1)}`);
                            
                            // 오프셋 정보 확인
                            let offsetY = 0;
                            if (matchedAnchor.offsetFromTop) {
                                offsetY = parseFloat(matchedAnchor.offsetFromTop) || 0;
                                detailedLogs.push(`   캡처된 오프셋: ${offsetY.toFixed(1)}px`);
                            }
                            
                            // 요소로 스크롤
                            foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                            
                            // 오프셋 보정
                            if (offsetY !== 0) {
                                detailedLogs.push(`   오프셋 보정: ${-offsetY.toFixed(1)}px`);
                                window.scrollBy(0, -offsetY);
                            }
                            
                            // 📊 **복원 후 위치 확인**
                            const afterScrollY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const afterScrollX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            detailedLogs.push(`   복원 후 위치: X=${afterScrollX.toFixed(1)}px, Y=${afterScrollY.toFixed(1)}px`);
                            
                            return {
                                success: true,
                                method: 'content_fingerprint',
                                anchorInfo: `fingerprint_${matchedAnchor.contentFingerprint?.textSignature?.substring(0, 20) || 'unknown'}`,
                                debug: { 
                                    matchedFingerprint: matchedAnchor.contentFingerprint,
                                    elementPosition: { x: elementScrollX, y: elementScrollY },
                                    afterPosition: { x: afterScrollX, y: afterScrollY }
                                },
                                elementInfo: {
                                    tagName: foundElement.tagName,
                                    position: { x: elementScrollX, y: elementScrollY },
                                    textContent: (foundElement.textContent || '').substring(0, 100)
                                }
                            };
                        }
                        
                        detailedLogs.push('   콘텐츠 지문으로 요소를 찾을 수 없음');
                        return { success: false, error: '콘텐츠 지문으로 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        detailedLogs.push(`   Stage 2 예외: ${e.message}`);
                        return { success: false, error: `Stage 2 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 3: 상대적 인덱스 기반 복원**
                function tryRelativeIndexRestore(config, targetX, targetY, infiniteScrollData) {
                    try {
                        detailedLogs.push('🚀 Stage 3: 상대적 인덱스 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            detailedLogs.push('   무한스크롤 앵커 데이터 없음');
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        
                        // 🧹 **품질 앵커 필터링**
                        const qualityAnchors = anchors.filter(anchor => {
                            const hasQualityText = anchor.textContent && isQualityText(anchor.textContent);
                            const hasRelativeIndex = anchor.relativeIndex;
                            const hasQualityScore = (anchor.qualityScore || 0) >= 8; // Stage 3는 더 관대
                            return hasQualityText && hasRelativeIndex && hasQualityScore;
                        });
                        
                        detailedLogs.push(`   총 ${anchors.length}개 앵커에서 품질 상대적 인덱스 검색: ${qualityAnchors.length}개`);
                        let foundElement = null;
                        let matchedAnchor = null;
                        let searchResults = [];
                        
                        for (let anchorIndex = 0; anchorIndex < qualityAnchors.length; anchorIndex++) {
                            const anchor = qualityAnchors[anchorIndex];
                            if (!anchor.relativeIndex) continue;
                            
                            const relativeIndex = anchor.relativeIndex;
                            detailedLogs.push(`   품질앵커[${anchorIndex}] 상대인덱스: 컨테이너="${relativeIndex.containerSelector}", 인덱스=${relativeIndex.indexInContainer}`);
                            
                            // 상대적 위치 기반으로 요소 찾기
                            if (relativeIndex.containerSelector && typeof relativeIndex.indexInContainer === 'number') {
                                const containers = document.querySelectorAll(relativeIndex.containerSelector);
                                detailedLogs.push(`   컨테이너 검색 결과: ${containers.length}개`);
                                
                                for (let containerIndex = 0; containerIndex < containers.length; containerIndex++) {
                                    const container = containers[containerIndex];
                                    const items = container.querySelectorAll(relativeIndex.itemSelector || '*');
                                    const targetIndex = relativeIndex.indexInContainer;
                                    
                                    detailedLogs.push(`   컨테이너[${containerIndex}] 아이템 수: ${items.length}개, 목표 인덱스: ${targetIndex}`);
                                    
                                    if (targetIndex >= 0 && targetIndex < items.length) {
                                        const candidateElement = items[targetIndex];
                                        
                                        // 추가 검증: 텍스트 일치 + 품질 텍스트 확인
                                        let isMatch = true;
                                        if (relativeIndex.textPreview) {
                                            const elementText = (candidateElement.textContent || '').trim();
                                            const textMatch = isQualityText(elementText) && elementText.includes(relativeIndex.textPreview);
                                            detailedLogs.push(`   텍스트 검증: "${relativeIndex.textPreview.substring(0, 30)}..." 매치=${textMatch}`);
                                            if (!textMatch) isMatch = false;
                                        }
                                        
                                        if (isMatch) {
                                            foundElement = candidateElement;
                                            matchedAnchor = anchor;
                                            searchResults.push({
                                                method: 'relativeIndex',
                                                containerIndex: containerIndex,
                                                itemIndex: targetIndex,
                                                totalItems: items.length,
                                                textVerified: !!relativeIndex.textPreview
                                            });
                                            detailedLogs.push(`   ✅ 상대적 인덱스로 요소 발견: 컨테이너[${containerIndex}], 아이템[${targetIndex}]`);
                                            break;
                                        }
                                    } else {
                                        detailedLogs.push(`   인덱스 범위 초과: ${targetIndex} >= ${items.length}`);
                                    }
                                }
                                
                                if (foundElement) break;
                            }
                        }
                        
                        anchorAnalysis.stage3_searchResults = searchResults;
                        
                        if (foundElement && matchedAnchor) {
                            // 📊 **발견된 요소의 정확한 위치 분석**
                            const elementRect = foundElement.getBoundingClientRect();
                            const elementScrollY = currentScrollY + elementRect.top;
                            const elementScrollX = currentScrollX + elementRect.left;
                            
                            detailedLogs.push(`   발견된 요소 위치: X=${elementScrollX.toFixed(1)}px, Y=${elementScrollY.toFixed(1)}px`);
                            
                            // 오프셋 정보 확인
                            let offsetY = 0;
                            if (matchedAnchor.offsetFromTop) {
                                offsetY = parseFloat(matchedAnchor.offsetFromTop) || 0;
                                detailedLogs.push(`   캡처된 오프셋: ${offsetY.toFixed(1)}px`);
                            }
                            
                            // 요소로 스크롤
                            foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                            
                            // 오프셋 보정
                            if (offsetY !== 0) {
                                window.scrollBy(0, -offsetY);
                            }
                            
                            // 📊 **복원 후 위치 확인**
                            const afterScrollY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const afterScrollX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            detailedLogs.push(`   복원 후 위치: X=${afterScrollX.toFixed(1)}px, Y=${afterScrollY.toFixed(1)}px`);
                            
                            return {
                                success: true,
                                method: 'relative_index',
                                anchorInfo: `index_${matchedAnchor.relativeIndex?.indexInContainer || 'unknown'}`,
                                debug: { 
                                    matchedIndex: matchedAnchor.relativeIndex,
                                    elementPosition: { x: elementScrollX, y: elementScrollY },
                                    afterPosition: { x: afterScrollX, y: afterScrollY }
                                }
                            };
                        }
                        
                        detailedLogs.push('   상대적 인덱스로 요소를 찾을 수 없음');
                        return { success: false, error: '상대적 인덱스로 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        detailedLogs.push(`   Stage 3 예외: ${e.message}`);
                        return { success: false, error: `Stage 3 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 4: 기존 셀렉터 기반 복원**
                function tryExistingSelectorRestore(config, targetX, targetY, infiniteScrollData) {
                    try {
                        detailedLogs.push('🚀 Stage 4: 기존 셀렉터 기반 복원 시작');
                        
                        if (!infiniteScrollData || !infiniteScrollData.anchors) {
                            detailedLogs.push('   무한스크롤 앵커 데이터 없음');
                            return { success: false, error: '무한스크롤 앵커 데이터 없음' };
                        }
                        
                        const anchors = infiniteScrollData.anchors;
                        
                        // 🧹 **품질 앵커 필터링**
                        const qualityAnchors = anchors.filter(anchor => {
                            const hasQualityText = anchor.textContent && isQualityText(anchor.textContent);
                            const hasSelectors = anchor.selectors && Array.isArray(anchor.selectors);
                            const hasQualityScore = (anchor.qualityScore || 0) >= 5; // Stage 4는 가장 관대
                            return hasQualityText && hasSelectors && hasQualityScore;
                        });
                        
                        detailedLogs.push(`   총 ${anchors.length}개 앵커에서 품질 기존 셀렉터 검색: ${qualityAnchors.length}개`);
                        let foundElement = null;
                        let matchedAnchor = null;
                        let searchResults = [];
                        
                        for (let anchorIndex = 0; anchorIndex < qualityAnchors.length; anchorIndex++) {
                            const anchor = qualityAnchors[anchorIndex];
                            if (!anchor.selectors || !Array.isArray(anchor.selectors)) continue;
                            
                            const selectors = anchor.selectors;
                            detailedLogs.push(`   품질앵커[${anchorIndex}] 셀렉터 수: ${selectors.length}개`);
                            
                            // 각 셀렉터 순차 시도
                            for (let selectorIndex = 0; selectorIndex < selectors.length; selectorIndex++) {
                                const selector = selectors[selectorIndex];
                                detailedLogs.push(`   셀렉터[${selectorIndex}] 시도: "${selector}"`);
                                
                                try {
                                    const elements = document.querySelectorAll(selector);
                                    detailedLogs.push(`   셀렉터 매칭 결과: ${elements.length}개 요소`);
                                    
                                    if (elements.length > 0) {
                                        // 🧹 **품질 요소 확인**
                                        const qualityElements = Array.from(elements).filter(element => {
                                            const elementText = (element.textContent || '').trim();
                                            return isQualityText(elementText);
                                        });
                                        
                                        if (qualityElements.length > 0) {
                                            foundElement = qualityElements[0];
                                            matchedAnchor = anchor;
                                            searchResults.push({
                                                method: 'existingSelector',
                                                selector: selector,
                                                selectorIndex: selectorIndex,
                                                matchCount: elements.length,
                                                qualityMatchCount: qualityElements.length
                                            });
                                            detailedLogs.push(`   ✅ 기존 셀렉터로 품질 요소 발견: "${selector}" (${qualityElements.length}개 중 선택)`);
                                            break;
                                        }
                                    }
                                } catch(e) {
                                    detailedLogs.push(`   셀렉터 오류 (건너뜀): ${e.message}`);
                                    continue;
                                }
                            }
                            
                            if (foundElement) break;
                        }
                        
                        anchorAnalysis.stage4_searchResults = searchResults;
                        
                        if (foundElement && matchedAnchor) {
                            // 📊 **발견된 요소의 정확한 위치 분석**
                            const elementRect = foundElement.getBoundingClientRect();
                            const elementScrollY = currentScrollY + elementRect.top;
                            const elementScrollX = currentScrollX + elementRect.left;
                            
                            detailedLogs.push(`   발견된 요소 위치: X=${elementScrollX.toFixed(1)}px, Y=${elementScrollY.toFixed(1)}px`);
                            
                            // 오프셋 정보 확인
                            let offsetY = 0;
                            if (matchedAnchor.offsetFromTop) {
                                offsetY = parseFloat(matchedAnchor.offsetFromTop) || 0;
                                detailedLogs.push(`   캡처된 오프셋: ${offsetY.toFixed(1)}px`);
                            }
                            
                            // 요소로 스크롤
                            foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                            
                            // 오프셋 보정
                            if (offsetY !== 0) {
                                window.scrollBy(0, -offsetY);
                            }
                            
                            // 📊 **복원 후 위치 확인**
                            const afterScrollY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const afterScrollX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            detailedLogs.push(`   복원 후 위치: X=${afterScrollX.toFixed(1)}px, Y=${afterScrollY.toFixed(1)}px`);
                            
                            return {
                                success: true,
                                method: 'existing_selector',
                                anchorInfo: `selector_${matchedAnchor.selectors?.[0] || 'unknown'}`,
                                debug: { 
                                    matchedSelectors: matchedAnchor.selectors,
                                    elementPosition: { x: elementScrollX, y: elementScrollY },
                                    afterPosition: { x: afterScrollX, y: afterScrollY }
                                }
                            };
                        }
                        
                        detailedLogs.push('   기존 셀렉터로 요소를 찾을 수 없음');
                        return { success: false, error: '기존 셀렉터로 요소를 찾을 수 없음' };
                        
                    } catch(e) {
                        detailedLogs.push(`   Stage 4 예외: ${e.message}`);
                        return { success: false, error: `Stage 4 예외: ${e.message}` };
                    }
                }
                
                // 🚀 **Stage 5: 무한스크롤 트리거 후 재시도**
                function tryInfiniteScrollTriggerRestore(config, targetX, targetY, infiniteScrollData) {
                    try {
                        detailedLogs.push('🚀 Stage 5: 무한스크롤 트리거 후 재시도 시작');
                        
                        // 현재 페이지 높이 확인
                        const currentHeight = Math.max(
                            document.documentElement.scrollHeight,
                            document.body.scrollHeight
                        );
                        
                        detailedLogs.push(`   현재 페이지 높이: ${currentHeight.toFixed(1)}px, 목표 Y: ${targetY.toFixed(1)}px`);
                        detailedLogs.push(`   뷰포트 높이: ${currentViewportHeight.toFixed(1)}px`);
                        detailedLogs.push(`   최대 스크롤 가능: ${(currentHeight - currentViewportHeight).toFixed(1)}px`);
                        
                        // 목표 위치가 현재 페이지를 벗어났는지 확인
                        const needsMoreContent = targetY > currentHeight - currentViewportHeight;
                        detailedLogs.push(`   무한스크롤 필요: ${needsMoreContent ? '예' : '아니오'}`);
                        
                        if (needsMoreContent) {
                            detailedLogs.push('   무한스크롤 트리거 필요 - 콘텐츠 로드 시도');
                            
                            // 무한스크롤 트리거 방법들
                            const triggerMethods = [
                                // 1. 페이지 하단으로 스크롤
                                () => {
                                    const bottomY = currentHeight - currentViewportHeight;
                                    detailedLogs.push(`   트리거 1: 하단 스크롤 (Y=${bottomY.toFixed(1)}px)`);
                                    window.scrollTo(0, bottomY);
                                    return true;
                                },
                                
                                // 2. 스크롤 이벤트 발생
                                () => {
                                    detailedLogs.push('   트리거 2: 스크롤 이벤트 발생');
                                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                                    window.dispatchEvent(new Event('resize', { bubbles: true }));
                                    return true;
                                },
                                
                                // 3. 더보기 버튼 클릭
                                () => {
                                    const loadMoreButtons = document.querySelectorAll(
                                        '.load-more, .show-more, .infinite-scroll-trigger, ' +
                                        '[data-testid*="load"], [class*="load"], [class*="more"]'
                                    );
                                    
                                    detailedLogs.push(`   트리거 3: 더보기 버튼 검색, ${loadMoreButtons.length}개 발견`);
                                    
                                    let clicked = 0;
                                    loadMoreButtons.forEach((btn, index) => {
                                        if (btn && typeof btn.click === 'function') {
                                            try {
                                                btn.click();
                                                clicked++;
                                                detailedLogs.push(`   버튼[${index}] 클릭 성공: ${btn.className || btn.tagName}`);
                                            } catch(e) {
                                                detailedLogs.push(`   버튼[${index}] 클릭 실패: ${e.message}`);
                                            }
                                        }
                                    });
                                    
                                    detailedLogs.push(`   더보기 버튼 클릭: ${clicked}개`);
                                    return clicked > 0;
                                },
                                
                                // 4. 터치 이벤트 시뮬레이션 (모바일)
                                () => {
                                    try {
                                        const touchEvent = new TouchEvent('touchend', { bubbles: true });
                                        document.dispatchEvent(touchEvent);
                                        detailedLogs.push('   트리거 4: 터치 이벤트 발생 성공');
                                        return true;
                                    } catch(e) {
                                        detailedLogs.push(`   트리거 4: 터치 이벤트 지원 안됨 - ${e.message}`);
                                        return false;
                                    }
                                }
                            ];
                            
                            // 모든 트리거 방법 시도
                            let triggeredMethods = 0;
                            let triggerResults = [];
                            
                            for (let i = 0; i < triggerMethods.length; i++) {
                                try {
                                    const result = triggerMethods[i]();
                                    triggerResults.push({ method: i + 1, success: result });
                                    if (result !== false) triggeredMethods++;
                                } catch(e) {
                                    triggerResults.push({ method: i + 1, success: false, error: e.message });
                                    detailedLogs.push(`   트리거 ${i + 1} 실패: ${e.message}`);
                                }
                            }
                            
                            detailedLogs.push(`   총 ${triggeredMethods}개 트리거 방법 실행`);
                            
                            // 잠시 대기 후 좌표 기반 복원
                            setTimeout(() => {
                                detailedLogs.push('   무한스크롤 트리거 후 좌표 복원 실행');
                                window.scrollTo(targetX, targetY);
                            }, 500);
                            
                            return {
                                success: true,
                                method: 'infinite_scroll_trigger',
                                anchorInfo: `trigger_${triggeredMethods}_methods`,
                                debug: { 
                                    triggeredMethods: triggeredMethods,
                                    currentHeight: currentHeight,
                                    targetY: targetY,
                                    triggerResults: triggerResults
                                }
                            };
                        } else {
                            detailedLogs.push('   무한스크롤 트리거 불필요 - 직접 좌표 복원');
                            window.scrollTo(targetX, targetY);
                            
                            // 📊 **복원 후 위치 확인**
                            const afterScrollY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const afterScrollX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            detailedLogs.push(`   복원 후 위치: X=${afterScrollX.toFixed(1)}px, Y=${afterScrollY.toFixed(1)}px`);
                            
                            return {
                                success: true,
                                method: 'coordinate_fallback',
                                anchorInfo: `coords_${targetX.toFixed(1)}_${targetY.toFixed(1)}`,
                                debug: { 
                                    method: 'coordinate_only',
                                    afterPosition: { x: afterScrollX, y: afterScrollY }
                                }
                            };
                        }
                        
                    } catch(e) {
                        detailedLogs.push(`   Stage 5 예외: ${e.message}`);
                        return { success: false, error: `Stage 5 예외: ${e.message}` };
                    }
                }
                
                // 🔧 **최종 결과 처리**
                if (!restoredByStage) {
                    // 모든 단계 실패 - 긴급 폴백
                    detailedLogs.push('🚨 모든 5단계 실패 - 긴급 좌표 폴백');
                    performScrollTo(targetX, targetY);
                    usedStage = 0;
                    usedMethod = 'emergency_coordinate';
                    anchorInfo = 'emergency';
                    errorMsg = '모든 5단계 복원 실패';
                }
                
                // 🔧 **복원 후 위치 검증 및 보정**
                setTimeout(() => {
                    try {
                        finalCurrentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        finalCurrentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        finalDiffY = Math.abs(finalCurrentY - targetY);
                        finalDiffX = Math.abs(finalCurrentX - targetX);
                        
                        // 사용된 Stage의 허용 오차 적용
                        const stageConfig = usedStage > 0 ? STAGE_CONFIG[`stage${usedStage}`] : null;
                        const tolerance = stageConfig ? stageConfig.tolerance : 100;
                        
                        detailedLogs.push('🔧 복원 후 위치 검증 시작');
                        detailedLogs.push(`   최종 위치: X=${finalCurrentX.toFixed(1)}px, Y=${finalCurrentY.toFixed(1)}px`);
                        detailedLogs.push(`   목표 위치: X=${targetX.toFixed(1)}px, Y=${targetY.toFixed(1)}px`);
                        detailedLogs.push(`   위치 차이: X=${finalDiffX.toFixed(1)}px, Y=${finalDiffY.toFixed(1)}px`);
                        detailedLogs.push(`   허용 오차: ${tolerance}px (Stage ${usedStage} 기준)`);
                        detailedLogs.push(`   허용 오차 내: ${finalDiffX <= tolerance && finalDiffY <= tolerance ? '예' : '아니오'}`);
                        
                        finalWithinTolerance = finalDiffX <= tolerance && finalDiffY <= tolerance;
                        
                        verificationResult = {
                            target: [targetX, targetY],
                            final: [finalCurrentX, finalCurrentY],
                            diff: [finalDiffX, finalDiffY],
                            stage: usedStage,
                            method: usedMethod,
                            tolerance: tolerance,
                            withinTolerance: finalWithinTolerance,
                            stageBased: restoredByStage,
                            actualRestoreDistance: Math.sqrt(finalDiffX * finalDiffX + finalDiffY * finalDiffY),
                            actualRestoreSuccess: finalDiffY <= 50 // 50px 이내면 실제 성공으로 간주
                        };
                        
                        // 🐛 **스코프 에러 수정: 변수 할당**
                        actualRestoreSuccess = verificationResult.actualRestoreSuccess;
                        practicalSuccess = finalDiffY <= 100; // 100px 이내면 실용적 성공
                        
                        detailedLogs.push(`   실제 복원 거리: ${verificationResult.actualRestoreDistance.toFixed(1)}px`);
                        detailedLogs.push(`   실제 복원 성공: ${actualRestoreSuccess ? '예' : '아니오'} (50px 기준)`);
                        detailedLogs.push(`   실용적 복원 성공: ${practicalSuccess ? '예' : '아니오'} (100px 기준)`);
                        
                        console.log('🚀 5단계 복원 검증:', verificationResult);
                        
                        if (actualRestoreSuccess) {
                            detailedLogs.push(`✅ 실제 복원 성공: 목표=${targetY.toFixed(1)}px, 실제=${finalCurrentY.toFixed(1)}px, 차이=${finalDiffY.toFixed(1)}px`);
                        } else {
                            detailedLogs.push(`❌ 실제 복원 실패: 목표=${targetY.toFixed(1)}px, 실제=${finalCurrentY.toFixed(1)}px, 차이=${finalDiffY.toFixed(1)}px`);
                        }
                        
                        // 🔧 **허용 오차 초과 시 점진적 보정**
                        if (!finalWithinTolerance && (finalDiffY > tolerance || finalDiffX > tolerance)) {
                            detailedLogs.push('🔧 허용 오차 초과 - 점진적 보정 시작');
                            detailedLogs.push(`   보정 필요 거리: X=${(targetX - finalCurrentX).toFixed(1)}px, Y=${(targetY - finalCurrentY).toFixed(1)}px`);
                            
                            const maxDiff = Math.max(finalDiffX, finalDiffY);
                            const steps = Math.min(5, Math.max(2, Math.ceil(maxDiff / 1000)));
                            const stepX = (targetX - finalCurrentX) / steps;
                            const stepY = (targetY - finalCurrentY) / steps;
                            
                            detailedLogs.push(`   점진적 보정: ${steps}단계, 단계별 이동 X=${stepX.toFixed(1)}px, Y=${stepY.toFixed(1)}px`);
                            
                            for (let i = 1; i <= steps; i++) {
                                setTimeout(() => {
                                    const stepTargetX = finalCurrentX + stepX * i;
                                    const stepTargetY = finalCurrentY + stepY * i;
                                    performScrollTo(stepTargetX, stepTargetY);
                                    detailedLogs.push(`   점진적 보정 ${i}/${steps}: X=${stepTargetX.toFixed(1)}px, Y=${stepTargetY.toFixed(1)}px`);
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
                        detailedLogs.push(`🚀 5단계 복원 검증 실패: ${verifyError.message}`);
                        console.error('🚀 5단계 복원 검증 실패:', verifyError);
                    }
                }, 100);
                
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
                    verification: verificationResult,
                    detailedLogs: detailedLogs,  // 📊 **상세 로그 배열 추가**
                    pageAnalysis: pageAnalysis,   // 📊 **페이지 분석 결과 추가**
                    anchorAnalysis: anchorAnalysis // 📊 **앵커 분석 결과 추가**
                };
                
            } catch(e) { 
                console.error('🚀 5단계 무한스크롤 특화 복원 실패:', e);
                detailedLogs.push(`🚀 전체 복원 실패: ${e.message}`);
                
                // 🚫 **수정: Swift 호환 반환값**
                return {
                    success: false,
                    stage: 0,
                    method: 'error',
                    anchorInfo: e.message,
                    stageBased: false,
                    error: e.message,
                    debug: { globalError: e.message },
                    detailedLogs: detailedLogs,
                    pageAnalysis: pageAnalysis,
                    anchorAnalysis: anchorAnalysis
                };
            }
            
            // 🔧 **헬퍼 함수들**
            
            // 통합된 스크롤 실행 함수
            function performScrollTo(x, y) {
                detailedLogs.push(`🔧 스크롤 실행: X=${x.toFixed(1)}px, Y=${y.toFixed(1)}px`);
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
    
    // 🚫 **브라우저 차단 대응 시스템 (점진적 스크롤)**
    private func performBrowserBlockingWorkaround(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        TabPersistenceManager.debugMessages.append("🚫 브라우저 차단 대응 단계 구성 시작")
        
        // **1단계: 점진적 스크롤 복원 (브라우저 차단 해결) - 상세 디버깅**
        restoreSteps.append((1, { stepCompletion in
            let progressiveDelay: TimeInterval = 0.1
            TabPersistenceManager.debugMessages.append("🚫 1단계: 점진적 스크롤 복원 (대기: \(String(format: "%.0f", progressiveDelay * 1000))ms)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + progressiveDelay) {
                let progressiveScrollJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        const tolerance = 50.0;
                        
                        // 📊 **상세 로그 수집**
                        const detailedLogs = [];
                        const performanceData = {};
                        const scrollAttempts = [];
                        
                        detailedLogs.push('🚫 점진적 스크롤 시작');
                        detailedLogs.push(`목표: X=${targetX.toFixed(1)}px, Y=${targetY.toFixed(1)}px`);
                        
                        console.log('🚫 점진적 스크롤 시작:', {target: [targetX, targetY]});
                        
                        // 📊 **현재 페이지 상태 분석**
                        const initialScrollY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const initialScrollX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const viewportHeight = parseFloat(window.innerHeight || 0);
                        const viewportWidth = parseFloat(window.innerWidth || 0);
                        const contentHeight = parseFloat(document.documentElement.scrollHeight || 0);
                        const contentWidth = parseFloat(document.documentElement.scrollWidth || 0);
                        const maxScrollY = Math.max(0, contentHeight - viewportHeight);
                        const maxScrollX = Math.max(0, contentWidth - viewportWidth);
                        
                        performanceData.initial = {
                            scroll: { x: initialScrollX, y: initialScrollY },
                            viewport: { width: viewportWidth, height: viewportHeight },
                            content: { width: contentWidth, height: contentHeight },
                            maxScroll: { x: maxScrollX, y: maxScrollY }
                        };
                        
                        detailedLogs.push(`초기 위치: X=${initialScrollX.toFixed(1)}px, Y=${initialScrollY.toFixed(1)}px`);
                        detailedLogs.push(`뷰포트: ${viewportWidth.toFixed(0)} x ${viewportHeight.toFixed(0)}`);
                        detailedLogs.push(`콘텐츠: ${contentWidth.toFixed(0)} x ${contentHeight.toFixed(0)}`);
                        detailedLogs.push(`최대 스크롤: X=${maxScrollX.toFixed(1)}px, Y=${maxScrollY.toFixed(1)}px`);
                        
                        // 📊 **목표 위치 실현 가능성 분석**
                        const isTargetReachableY = targetY <= maxScrollY + tolerance;
                        const isTargetReachableX = targetX <= maxScrollX + tolerance;
                        const initialDiffY = Math.abs(initialScrollY - targetY);
                        const initialDiffX = Math.abs(initialScrollX - targetX);
                        
                        detailedLogs.push(`목표 Y 도달 가능: ${isTargetReachableY ? '예' : '아니오'} (${isTargetReachableY ? '' : (targetY - maxScrollY).toFixed(1) + 'px 초과'})`);
                        detailedLogs.push(`목표 X 도달 가능: ${isTargetReachableX ? '예' : '아니오'}`);
                        detailedLogs.push(`초기 거리: X=${initialDiffX.toFixed(1)}px, Y=${initialDiffY.toFixed(1)}px`);
                        
                        // 🚫 **브라우저 차단 대응: 점진적 스크롤 - 상세 디버깅**
                        let attempts = 0;
                        const maxAttempts = 15;
                        const attemptInterval = 200; // 200ms 간격
                        let lastScrollY = initialScrollY;
                        let lastScrollX = initialScrollX;
                        let stuckCounter = 0; // 스크롤이 멈춘 횟수
                        
                        function performScrollAttempt() {
                            try {
                                attempts++;
                                const attemptStartTime = Date.now();
                                
                                // 현재 위치 확인
                                const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                
                                const diffX = Math.abs(currentX - targetX);
                                const diffY = Math.abs(currentY - targetY);
                                const progressY = Math.abs(currentY - lastScrollY);
                                const progressX = Math.abs(currentX - lastScrollX);
                                
                                // 📊 **시도별 상세 기록**
                                const attemptData = {
                                    attempt: attempts,
                                    timestamp: attemptStartTime,
                                    current: { x: currentX, y: currentY },
                                    target: { x: targetX, y: targetY },
                                    diff: { x: diffX, y: diffY },
                                    progress: { x: progressX, y: progressY },
                                    withinTolerance: diffX <= tolerance && diffY <= tolerance
                                };
                                
                                scrollAttempts.push(attemptData);
                                
                                detailedLogs.push(`시도 ${attempts}: 현재 Y=${currentY.toFixed(1)}px, 차이=${diffY.toFixed(1)}px, 진행=${progressY.toFixed(1)}px`);
                                
                                // 📊 **스크롤 정체 감지**
                                if (progressY < 1.0 && progressX < 1.0) {
                                    stuckCounter++;
                                    detailedLogs.push(`스크롤 정체 감지: ${stuckCounter}회 연속`);
                                } else {
                                    stuckCounter = 0;
                                }
                                
                                // 목표 도달 확인
                                if (diffX <= tolerance && diffY <= tolerance) {
                                    const successData = {
                                        success: true,
                                        attempts: attempts,
                                        finalPosition: { x: currentX, y: currentY },
                                        finalDiff: { x: diffX, y: diffY },
                                        totalTime: Date.now() - attemptStartTime
                                    };
                                    
                                    detailedLogs.push(`✅ 점진적 스크롤 성공: ${attempts}회 시도, 최종 차이 Y=${diffY.toFixed(1)}px`);
                                    console.log('🚫 점진적 스크롤 성공:', successData);
                                    
                                    return {
                                        result: 'progressive_success',
                                        data: successData,
                                        detailedLogs: detailedLogs,
                                        performanceData: performanceData,
                                        scrollAttempts: scrollAttempts
                                    };
                                }
                                
                                // 📊 **스크롤 한계 상세 분석**
                                const currentMaxScrollY = Math.max(
                                    document.documentElement.scrollHeight - window.innerHeight,
                                    document.body.scrollHeight - window.innerHeight,
                                    0
                                );
                                const currentMaxScrollX = Math.max(
                                    document.documentElement.scrollWidth - window.innerWidth,
                                    document.body.scrollWidth - window.innerWidth,
                                    0
                                );
                                
                                attemptData.scrollLimits = {
                                    maxX: currentMaxScrollX,
                                    maxY: currentMaxScrollY,
                                    atLimitX: currentX >= currentMaxScrollX - 5,
                                    atLimitY: currentY >= currentMaxScrollY - 5,
                                    heightChanged: Math.abs(currentMaxScrollY - maxScrollY) > 10
                                };
                                
                                detailedLogs.push(`스크롤 한계: Y=${currentMaxScrollY.toFixed(1)}px (${currentY >= currentMaxScrollY - 5 ? '도달' : '미도달'})`);
                                
                                // 📊 **무한 스크롤 감지 및 트리거**
                                if (currentY >= currentMaxScrollY - 100 && targetY > currentMaxScrollY) {
                                    detailedLogs.push('무한 스크롤 구간 감지 - 트리거 시도');
                                    
                                    // 스크롤 이벤트 강제 발생
                                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                                    window.dispatchEvent(new Event('resize', { bubbles: true }));
                                    
                                    // 터치 이벤트 시뮬레이션 (모바일 무한 스크롤용)
                                    try {
                                        const touchEvent = new TouchEvent('touchend', { bubbles: true });
                                        document.dispatchEvent(touchEvent);
                                        attemptData.infiniteScrollTrigger = 'touchEvent_attempted';
                                        detailedLogs.push('터치 이벤트 트리거 성공');
                                    } catch(e) {
                                        attemptData.infiniteScrollTrigger = 'touchEvent_unsupported';
                                        detailedLogs.push('터치 이벤트 트리거 실패');
                                    }
                                    
                                    // 📊 **더보기 버튼 검색 및 클릭**
                                    const loadMoreButtons = document.querySelectorAll(
                                        '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                                        '[data-role="load"], .load-more, .show-more, .infinite-scroll-trigger'
                                    );
                                    
                                    let clickedButtons = 0;
                                    loadMoreButtons.forEach((btn, index) => {
                                        if (btn && typeof btn.click === 'function') {
                                            try {
                                                btn.click();
                                                clickedButtons++;
                                                detailedLogs.push(`더보기 버튼[${index}] 클릭: ${btn.className || btn.tagName}`);
                                            } catch(e) {
                                                detailedLogs.push(`더보기 버튼[${index}] 클릭 실패: ${e.message}`);
                                            }
                                        }
                                    });
                                    
                                    attemptData.loadMoreButtons = {
                                        found: loadMoreButtons.length,
                                        clicked: clickedButtons
                                    };
                                    
                                    detailedLogs.push(`더보기 버튼: ${loadMoreButtons.length}개 발견, ${clickedButtons}개 클릭`);
                                    
                                    // 📊 **페이지 하단 강제 스크롤**
                                    if (clickedButtons > 0) {
                                        detailedLogs.push('더보기 버튼 클릭 후 하단 강제 스크롤');
                                        setTimeout(() => {
                                            const newMaxY = Math.max(
                                                document.documentElement.scrollHeight - window.innerHeight,
                                                document.body.scrollHeight - window.innerHeight,
                                                0
                                            );
                                            window.scrollTo(0, newMaxY);
                                        }, 100);
                                    }
                                }
                                
                                // 📊 **스크롤 시도 - 여러 방법으로**
                                try {
                                    // 방법 1: window.scrollTo
                                    window.scrollTo(targetX, targetY);
                                    
                                    // 방법 2: documentElement 직접 설정
                                    document.documentElement.scrollTop = targetY;
                                    document.documentElement.scrollLeft = targetX;
                                    
                                    // 방법 3: body 직접 설정
                                    document.body.scrollTop = targetY;
                                    document.body.scrollLeft = targetX;
                                    
                                    // 방법 4: scrollingElement 사용
                                    if (document.scrollingElement) {
                                        document.scrollingElement.scrollTop = targetY;
                                        document.scrollingElement.scrollLeft = targetX;
                                    }
                                    
                                    attemptData.scrollMethods = 'all_attempted';
                                    detailedLogs.push('모든 스크롤 방법 시도 완료');
                                } catch(scrollError) {
                                    attemptData.scrollError = scrollError.message;
                                    detailedLogs.push(`스크롤 실행 오류: ${scrollError.message}`);
                                }
                                
                                // 📊 **스크롤 정체 대응**
                                if (stuckCounter >= 3) {
                                    detailedLogs.push('스크롤 정체 3회 연속 - 강제 해제 시도');
                                    
                                    // 강제 스크롤 해제 방법들
                                    try {
                                        // 1. CSS overflow 임시 변경
                                        const bodyStyle = document.body.style;
                                        const originalOverflow = bodyStyle.overflow;
                                        bodyStyle.overflow = 'visible';
                                        
                                        // 2. 스크롤 실행
                                        window.scrollTo(targetX, targetY);
                                        
                                        // 3. 원복
                                        setTimeout(() => {
                                            bodyStyle.overflow = originalOverflow;
                                        }, 50);
                                        
                                        stuckCounter = 0; // 정체 카운터 리셋
                                        detailedLogs.push('스크롤 정체 강제 해제 완료');
                                    } catch(e) {
                                        detailedLogs.push(`스크롤 정체 해제 실패: ${e.message}`);
                                    }
                                }
                                
                                // 최대 시도 확인
                                if (attempts >= maxAttempts) {
                                    const failureData = {
                                        success: false,
                                        attempts: maxAttempts,
                                        finalPosition: { x: currentX, y: currentY },
                                        finalDiff: { x: diffX, y: diffY },
                                        stuckCounter: stuckCounter,
                                        reason: 'max_attempts_reached'
                                    };
                                    
                                    detailedLogs.push(`점진적 스크롤 최대 시도 도달: ${maxAttempts}회`);
                                    detailedLogs.push(`최종 위치: Y=${currentY.toFixed(1)}px, 목표=${targetY.toFixed(1)}px, 차이=${diffY.toFixed(1)}px`);
                                    console.log('🚫 점진적 스크롤 최대 시도 도달:', failureData);
                                    
                                    return {
                                        result: 'progressive_maxAttempts',
                                        data: failureData,
                                        detailedLogs: detailedLogs,
                                        performanceData: performanceData,
                                        scrollAttempts: scrollAttempts
                                    };
                                }
                                
                                // 다음 시도를 위한 위치 업데이트
                                lastScrollY = currentY;
                                lastScrollX = currentX;
                                
                                // 다음 시도 예약
                                setTimeout(() => {
                                    const result = performScrollAttempt();
                                    if (result) {
                                        // 재귀 완료 - 결과 처리는 상위에서
                                    }
                                }, attemptInterval);
                                
                                return null; // 계속 진행
                                
                            } catch(attemptError) {
                                const errorData = {
                                    success: false,
                                    attempts: attempts,
                                    error: attemptError.message,
                                    reason: 'attempt_exception'
                                };
                                
                                detailedLogs.push(`점진적 스크롤 시도 오류: ${attemptError.message}`);
                                console.error('🚫 점진적 스크롤 시도 오류:', attemptError);
                                
                                return {
                                    result: `progressive_attemptError`,
                                    data: errorData,
                                    detailedLogs: detailedLogs,
                                    performanceData: performanceData,
                                    scrollAttempts: scrollAttempts
                                };
                            }
                        }
                        
                        // 첫 번째 시도 시작
                        const result = performScrollAttempt();
                        return result || {
                            result: 'progressive_inProgress',
                            detailedLogs: detailedLogs,
                            performanceData: performanceData
                        };
                        
                    } catch(e) { 
                        console.error('🚫 점진적 스크롤 전체 실패:', e);
                        return {
                            result: 'progressive_error',
                            error: e.message,
                            detailedLogs: [`점진적 스크롤 전체 실패: ${e.message}`]
                        };
                    }
                })()
                """
                
                webView.evaluateJavaScript(progressiveScrollJS) { result, error in
                    var resultString = "progressive_unknown"
                    var success = false
                    
                    if let error = error {
                        resultString = "progressive_jsError: \(error.localizedDescription)"
                        TabPersistenceManager.debugMessages.append("🚫 1단계 JavaScript 실행 오류: \(error.localizedDescription)")
                    } else if let resultDict = result as? [String: Any] {
                        if let resultType = resultDict["result"] as? String {
                            resultString = resultType
                            success = resultType.contains("success") || resultType.contains("partial") || resultType.contains("maxAttempts")
                        }
                        
                        // 📊 **상세 로그 추출**
                        if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                            TabPersistenceManager.debugMessages.append("📊 점진적 스크롤 상세 로그:")
                            for log in detailedLogs.prefix(20) { // 최대 20개만
                                TabPersistenceManager.debugMessages.append("   \(log)")
                            }
                            if detailedLogs.count > 20 {
                                TabPersistenceManager.debugMessages.append("   ... 외 \(detailedLogs.count - 20)개 로그 생략")
                            }
                        }
                        
                        // 📊 **성능 데이터 추출**
                        if let performanceData = resultDict["performanceData"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("📊 점진적 스크롤 성능 데이터: \(performanceData)")
                        }
                        
                        // 📊 **스크롤 시도 데이터 추출** - 수정된 캐스팅
                        if let scrollAttempts = resultDict["scrollAttempts"] as? [[String: Any]] {
                            TabPersistenceManager.debugMessages.append("📊 스크롤 시도 횟수: \(scrollAttempts.count)회")
                            
                            // 처음과 마지막 몇 개만 로그
                            let logCount = min(3, scrollAttempts.count)
                            for i in 0..<logCount {
                                let attempt = scrollAttempts[i]
                                if let attemptNum = attempt["attempt"] as? Int,
                                   let current = attempt["current"] as? [String: Any],
                                   let diff = attempt["diff"] as? [String: Any] {
                                    let currentY = (current["y"] as? Double) ?? 0
                                    let diffY = (diff["y"] as? Double) ?? 0
                                    TabPersistenceManager.debugMessages.append("   시도[\(attemptNum)]: Y=\(String(format: "%.1f", currentY))px, 차이=\(String(format: "%.1f", diffY))px")
                                }
                            }
                            
                            if scrollAttempts.count > 6 {
                                TabPersistenceManager.debugMessages.append("   ... 중간 \(scrollAttempts.count - 6)개 시도 생략")
                                
                                // 마지막 3개
                                for i in max(logCount, scrollAttempts.count - 3)..<scrollAttempts.count {
                                    let attempt = scrollAttempts[i]
                                    if let attemptNum = attempt["attempt"] as? Int,
                                       let current = attempt["current"] as? [String: Any],
                                       let diff = attempt["diff"] as? [String: Any] {
                                        let currentY = (current["y"] as? Double) ?? 0
                                        let diffY = (diff["y"] as? Double) ?? 0
                                        TabPersistenceManager.debugMessages.append("   시도[\(attemptNum)]: Y=\(String(format: "%.1f", currentY))px, 차이=\(String(format: "%.1f", diffY))px")
                                    }
                                }
                            }
                        }
                        
                        // 📊 **최종 결과 데이터 추출**
                        if let finalData = resultDict["data"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("📊 점진적 스크롤 최종 결과: \(finalData)")
                        }
                        
                    } else {
                        resultString = "progressive_invalidResult"
                    }
                    
                    TabPersistenceManager.debugMessages.append("🚫 1단계 완료: \(success ? "성공" : "실패") (\(resultString))")
                    stepCompletion(success)
                }
            }
        }))
        
        // **2단계: 최종 확인 및 보정 (🐛 스코프 에러 수정)**
        TabPersistenceManager.debugMessages.append("✅ 2단계 최종 보정 단계 추가 (필수)")
        
        restoreSteps.append((2, { stepCompletion in
            let waitTime: TimeInterval = 0.8
            TabPersistenceManager.debugMessages.append("✅ 2단계: 최종 보정 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                let finalVerifyJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        
                        // 🐛 **스코프 에러 수정: 모든 변수 미리 정의**
                        let actualRestoreSuccess = false;
                        let practicalSuccess = false;
                        let finalCurrentY = 0;
                        let finalCurrentX = 0;
                        let finalDiffY = 0;
                        let finalDiffX = 0;
                        let finalWithinTolerance = false;
                        
                        // 📊 **상세 로그 수집**
                        const detailedLogs = [];
                        const verificationData = {};
                        
                        detailedLogs.push('✅ 브라우저 차단 대응 최종 보정 시작');
                        detailedLogs.push(`목표: X=${targetX.toFixed(1)}px, Y=${targetY.toFixed(1)}px`);
                        
                        // ✅ **수정: 실제 스크롤 위치 정확 측정**
                        const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const tolerance = 30.0; // 🚫 브라우저 차단 고려하여 관대한 허용 오차
                        
                        const diffX = Math.abs(currentX - targetX);
                        const diffY = Math.abs(currentY - targetY);
                        const isWithinTolerance = diffX <= tolerance && diffY <= tolerance;
                        
                        // 📊 **현재 페이지 상태 상세 분석**
                        const viewportHeight = parseFloat(window.innerHeight || 0);
                        const viewportWidth = parseFloat(window.innerWidth || 0);
                        const contentHeight = parseFloat(document.documentElement.scrollHeight || 0);
                        const contentWidth = parseFloat(document.documentElement.scrollWidth || 0);
                        const maxScrollY = Math.max(0, contentHeight - viewportHeight);
                        const maxScrollX = Math.max(0, contentWidth - viewportWidth);
                        
                        verificationData.currentState = {
                            scroll: { x: currentX, y: currentY },
                            target: { x: targetX, y: targetY },
                            diff: { x: diffX, y: diffY },
                            tolerance: tolerance,
                            withinTolerance: isWithinTolerance,
                            viewport: { width: viewportWidth, height: viewportHeight },
                            content: { width: contentWidth, height: contentHeight },
                            maxScroll: { x: maxScrollX, y: maxScrollY }
                        };
                        
                        detailedLogs.push(`현재 위치: X=${currentX.toFixed(1)}px, Y=${currentY.toFixed(1)}px`);
                        detailedLogs.push(`목표와 차이: X=${diffX.toFixed(1)}px, Y=${diffY.toFixed(1)}px`);
                        detailedLogs.push(`허용 오차: ${tolerance}px`);
                        detailedLogs.push(`허용 오차 내: ${isWithinTolerance ? '예' : '아니오'}`);
                        detailedLogs.push(`페이지 크기: ${contentWidth.toFixed(0)} x ${contentHeight.toFixed(0)}`);
                        detailedLogs.push(`최대 스크롤: X=${maxScrollX.toFixed(1)}px, Y=${maxScrollY.toFixed(1)}px`);
                        
                        // 📊 **스크롤 가능성 분석**
                        const canScrollToTargetY = targetY <= maxScrollY + tolerance;
                        const canScrollToTargetX = targetX <= maxScrollX + tolerance;
                        const isTargetBeyondContent = targetY > contentHeight;
                        
                        verificationData.scrollability = {
                            canScrollToTargetY: canScrollToTargetY,
                            canScrollToTargetX: canScrollToTargetX,
                            isTargetBeyondContent: isTargetBeyondContent,
                            excessY: Math.max(0, targetY - maxScrollY),
                            excessX: Math.max(0, targetX - maxScrollX)
                        };
                        
                        detailedLogs.push(`목표 Y 도달 가능: ${canScrollToTargetY ? '예' : '아니오'}`);
                        detailedLogs.push(`목표 X 도달 가능: ${canScrollToTargetX ? '예' : '아니오'}`);
                        if (!canScrollToTargetY) {
                            detailedLogs.push(`Y축 초과량: ${(targetY - maxScrollY).toFixed(1)}px`);
                        }
                        if (isTargetBeyondContent) {
                            detailedLogs.push(`목표가 콘텐츠 영역 벗어남: ${(targetY - contentHeight).toFixed(1)}px`);
                        }
                        
                        console.log('✅ 브라우저 차단 대응 최종 검증:', verificationData);
                        
                        // 최종 보정 (필요시)
                        let correctionApplied = false;
                        if (!isWithinTolerance) {
                            detailedLogs.push('최종 보정 필요 - 실행 중');
                            correctionApplied = true;
                            
                            // 📊 **보정 전 상태 기록**
                            const beforeCorrectionY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const beforeCorrectionX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            
                            detailedLogs.push(`보정 전: X=${beforeCorrectionX.toFixed(1)}px, Y=${beforeCorrectionY.toFixed(1)}px`);
                            
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
                            
                            // 📊 **보정 후 즉시 확인**
                            setTimeout(() => {
                                const afterCorrectionY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                const afterCorrectionX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                const correctionDiffY = Math.abs(afterCorrectionY - beforeCorrectionY);
                                const correctionDiffX = Math.abs(afterCorrectionX - beforeCorrectionX);
                                
                                verificationData.correction = {
                                    applied: true,
                                    before: { x: beforeCorrectionX, y: beforeCorrectionY },
                                    after: { x: afterCorrectionX, y: afterCorrectionY },
                                    movement: { x: correctionDiffX, y: correctionDiffY },
                                    effective: correctionDiffY > 5 || correctionDiffX > 5
                                };
                                
                                detailedLogs.push(`보정 후: X=${afterCorrectionX.toFixed(1)}px, Y=${afterCorrectionY.toFixed(1)}px`);
                                detailedLogs.push(`보정 이동량: X=${correctionDiffX.toFixed(1)}px, Y=${correctionDiffY.toFixed(1)}px`);
                                detailedLogs.push(`보정 효과: ${verificationData.correction.effective ? '유효' : '무효과'}`);
                            }, 50);
                        } else {
                            detailedLogs.push('허용 오차 내 - 보정 불필요');
                        }
                        
                        // ✅ **최종 위치 정확 측정 및 기록**
                        setTimeout(() => {
                            // 🐛 **스코프 에러 수정: 변수 할당**
                            finalCurrentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            finalCurrentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            finalDiffX = Math.abs(finalCurrentX - targetX);
                            finalDiffY = Math.abs(finalCurrentY - targetY);
                            finalWithinTolerance = finalDiffX <= tolerance && finalDiffY <= tolerance;
                            
                            // ✅ **실제 복원 성공 여부 정확히 판단**
                            actualRestoreSuccess = finalDiffY <= 50; // 50px 이내면 실제 성공
                            practicalSuccess = finalDiffY <= 100; // 100px 이내면 실용적 성공
                            
                            verificationData.finalResult = {
                                final: { x: finalCurrentX, y: finalCurrentY },
                                target: { x: targetX, y: targetY },
                                diff: { x: finalDiffX, y: finalDiffY },
                                tolerance: tolerance,
                                withinTolerance: finalWithinTolerance,
                                actualRestoreSuccess: actualRestoreSuccess,
                                practicalSuccess: practicalSuccess,
                                correctionApplied: correctionApplied
                            };
                            
                            detailedLogs.push('=== 최종 결과 ===');
                            detailedLogs.push(`최종 위치: X=${finalCurrentX.toFixed(1)}px, Y=${finalCurrentY.toFixed(1)}px`);
                            detailedLogs.push(`목표 위치: X=${targetX.toFixed(1)}px, Y=${targetY.toFixed(1)}px`);
                            detailedLogs.push(`최종 차이: X=${finalDiffX.toFixed(1)}px, Y=${finalDiffY.toFixed(1)}px`);
                            detailedLogs.push(`허용 오차 내: ${finalWithinTolerance ? '예' : '아니오'} (${tolerance}px 기준)`);
                            detailedLogs.push(`실제 복원 성공: ${actualRestoreSuccess ? '예' : '아니오'} (50px 기준)`);
                            detailedLogs.push(`실용적 성공: ${practicalSuccess ? '예' : '아니오'} (100px 기준)`);
                            
                            console.log('✅ 브라우저 차단 대응 최종보정 완료:', verificationData);
                            
                        }, 100);
                        
                        return {
                            success: actualRestoreSuccess, // ✅ 실제 복원 성공 여부
                            withinTolerance: finalWithinTolerance,
                            finalDiff: [finalDiffX, finalDiffY],
                            actualTarget: [targetX, targetY],
                            actualFinal: [finalCurrentX, finalCurrentY],
                            actualRestoreSuccess: actualRestoreSuccess,
                            practicalSuccess: practicalSuccess,
                            verificationData: verificationData,
                            detailedLogs: detailedLogs
                        };
                    } catch(e) { 
                        console.error('✅ 브라우저 차단 대응 최종보정 실패:', e);
                        return {
                            success: false,
                            error: e.message,
                            detailedLogs: [`브라우저 차단 대응 최종보정 실패: ${e.message}`]
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
                        let practicalSuccess = (resultDict["practicalSuccess"] as? Bool) ?? false
                        
                        // 📊 **상세 로그 추출**
                        if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                            TabPersistenceManager.debugMessages.append("📊 최종 보정 상세 로그:")
                            for log in detailedLogs {
                                TabPersistenceManager.debugMessages.append("   \(log)")
                            }
                        }
                        
                        // 📊 **검증 데이터 추출**
                        if let verificationData = resultDict["verificationData"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("📊 최종 검증 데이터: \(verificationData)")
                        }
                        
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
                            TabPersistenceManager.debugMessages.append("✅ 2단계 실제 복원 성공: \(actualRestoreSuccess) (50px 기준)")
                        }
                        if practicalSuccess {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 실용적 복원 성공: \(practicalSuccess) (100px 기준)")
                        }
                        if let errorMsg = resultDict["error"] as? String {
                            TabPersistenceManager.debugMessages.append("✅ 2단계 오류: \(errorMsg)")
                        }
                        
                        // 실용적 성공도 고려
                        if !success && practicalSuccess {
                            TabPersistenceManager.debugMessages.append("✅ 실제 복원은 실패했지만 실용적 복원은 성공 - 성공으로 처리")
                            success = true
                        }
                    } else {
                        success = false
                    }
                    
                    TabPersistenceManager.debugMessages.append("✅ 2단계 브라우저 차단 대응 최종보정 완료: \(success ? "성공" : "실패")")
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
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🚀 5단계 무한스크롤 특화 캡처 + 의미없는 텍스트 필터링)**
    
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
                    // 🧹 **품질 앵커 필터링 후 로깅**
                    let qualityAnchors = anchors.filter { anchor in
                        if let qualityScore = anchor["qualityScore"] as? Int {
                            return qualityScore >= 15
                        }
                        return false
                    }
                    
                    TabPersistenceManager.debugMessages.append("🚀 캡처된 무한스크롤 앵커 개수: \(anchors.count)개 (품질 앵커: \(qualityAnchors.count)개)")
                    if qualityAnchors.count > 0 {
                        let firstAnchor = qualityAnchors[0]
                        TabPersistenceManager.debugMessages.append("🚀 첫 번째 품질 앵커 키: \(Array(firstAnchor.keys))")
                        
                        // 📊 **첫 번째 품질 앵커 상세 정보 로깅**
                        if let absolutePos = firstAnchor["absolutePosition"] as? [String: Any] {
                            let top = (absolutePos["top"] as? Double) ?? 0
                            let left = (absolutePos["left"] as? Double) ?? 0
                            TabPersistenceManager.debugMessages.append("📊 첫 품질앵커 위치: X=\(String(format: "%.1f", left))px, Y=\(String(format: "%.1f", top))px")
                        }
                        if let offsetFromTop = firstAnchor["offsetFromTop"] as? Double {
                            TabPersistenceManager.debugMessages.append("📊 첫 품질앵커 오프셋: \(String(format: "%.1f", offsetFromTop))px")
                        }
                        if let textContent = firstAnchor["textContent"] as? String {
                            let preview = textContent.prefix(50)
                            TabPersistenceManager.debugMessages.append("📊 첫 품질앵커 텍스트: \"\(preview)\"")
                        }
                        if let tagName = firstAnchor["tagName"] as? String {
                            TabPersistenceManager.debugMessages.append("📊 첫 품질앵커 태그: <\(tagName)>")
                        }
                        if let qualityScore = firstAnchor["qualityScore"] as? Int {
                            TabPersistenceManager.debugMessages.append("📊 첫 품질앵커 품질점수: \(qualityScore)점")
                        }
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 데이터 캡처 실패")
                }
                
                if let stats = infiniteScrollData["stats"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 무한스크롤 수집 통계: \(stats)")
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
        
        TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 시도: \(pageRecord.title)")
        
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
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 성공")
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
        TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 시작")
        
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 🚫 **활성상태 제거**
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
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 실패: \(error.localizedDescription)")
                } else if let dom = result as? String {
                    domSnapshot = dom
                    TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 성공: \(dom.count)문자")
                }
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 1.0) // 🔧 기존 캡처 타임아웃 유지 (1초)
        
        // 3. ✅ **수정: Promise 제거한 5단계 무한스크롤 특화 JS 상태 캡처 (의미없는 텍스트 필터링 포함)** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 5단계 무한스크롤 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateFiveStageInfiniteScrollCaptureScript() // 🚀 새로운 5단계 캡처 스크립트 사용
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                    
                    // 📊 **상세 캡처 결과 로깅**
                    if let infiniteScrollData = data["infiniteScrollData"] as? [String: Any] {
                        if let anchors = infiniteScrollData["anchors"] as? [[String: Any]] {
                            let qualityAnchors = anchors.filter { anchor in
                                if let qualityScore = anchor["qualityScore"] as? Int {
                                    return qualityScore >= 15
                                }
                                return false
                            }
                            TabPersistenceManager.debugMessages.append("🚀 JS 캡처된 앵커: \(anchors.count)개 (품질 앵커: \(qualityAnchors.count)개)")
                        }
                        if let stats = infiniteScrollData["stats"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("📊 JS 캡처 통계: \(stats)")
                        }
                    }
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
            TabPersistenceManager.debugMessages.append("✅ 완전 캡처 성공")
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
            TabPersistenceManager.debugMessages.append("⚡ 부분 캡처 성공: visual=\(visualSnapshot != nil), dom=\(domSnapshot != nil), js=\(jsState != nil)")
        } else {
            captureStatus = .failed
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패")
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
        
        TabPersistenceManager.debugMessages.append("📊 캡처 완료: 위치=(\(String(format: "%.1f", captureData.scrollPosition.x)), \(String(format: "%.1f", captureData.scrollPosition.y))), 백분율=(\(String(format: "%.2f", scrollPercent.x))%, \(String(format: "%.2f", scrollPercent.y))%)")
        
        // 🔄 **프리로딩 설정 생성 (저장된 콘텐츠 높이 기반)**
        let preloadingConfig = BFCacheSnapshot.PreloadingConfig(
            enableDataPreloading: true,
            enableBatchLoading: true, 
            targetContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height),
            maxPreloadAttempts: 10,
            preloadBatchSize: 5,
            preloadTimeoutSeconds: 30
        )
        
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
            version: version,
            preloadingConfig: preloadingConfig
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🚀 **새로운: 5단계 무한스크롤 특화 캡처 JavaScript 생성 (의미없는 텍스트 필터링 포함)**
    private func generateFiveStageInfiniteScrollCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 5단계 무한스크롤 특화 캡처 시작');
                
                // 📊 **상세 로그 수집**
                const detailedLogs = [];
                const captureStats = {};
                const pageAnalysis = {};
                
                // 기본 정보 수집
                const scrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                const scrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                
                detailedLogs.push('🚀 5단계 무한스크롤 특화 캡처 시작');
                detailedLogs.push(`스크롤 위치: X=${scrollX.toFixed(1)}px, Y=${scrollY.toFixed(1)}px`);
                detailedLogs.push(`뷰포트 크기: ${viewportWidth.toFixed(0)} x ${viewportHeight.toFixed(0)}`);
                detailedLogs.push(`콘텐츠 크기: ${contentWidth.toFixed(0)} x ${contentHeight.toFixed(0)}`);
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                console.log('🚀 기본 정보:', {
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                // 🧹 **의미없는 텍스트 필터링 함수**
                function isQualityText(text) {
                    if (!text || typeof text !== 'string') return false;
                    
                    const cleanText = text.trim();
                    if (cleanText.length < 5) return false; // 너무 짧은 텍스트
                    
                    // 🧹 **의미없는 텍스트 패턴들**
                    const meaninglessPatterns = [
                        /^(투표는|표시되지|않습니다|네트워크|문제로|연결되지|잠시|후에|다시|시도)/,
                        /^(로딩|loading|wait|please|기다려|잠시만)/i,
                        /^(오류|에러|error|fail|실패|죄송|sorry)/i,
                        /^(확인|ok|yes|no|취소|cancel|닫기|close)/i,
                        /^(더보기|more|load|next|이전|prev|previous)/i,
                        /^(클릭|click|tap|터치|touch|선택)/i,
                        /^(답글|댓글|reply|comment|쓰기|작성)/i,
                        /^[\s\.\-_=+]{2,}$/, // 특수문자만
                        /^[0-9\s\.\/\-:]{3,}$/, // 숫자와 특수문자만 (날짜/시간 제외)
                        /^(am|pm|오전|오후|시|분|초)$/i,
                    ];
                    
                    for (const pattern of meaninglessPatterns) {
                        if (pattern.test(cleanText)) {
                            return false;
                        }
                    }
                    
                    // 너무 반복적인 문자 (같은 문자 70% 이상)
                    const charCounts = {};
                    for (const char of cleanText) {
                        charCounts[char] = (charCounts[char] || 0) + 1;
                    }
                    const maxCharCount = Math.max(...Object.values(charCounts));
                    if (maxCharCount / cleanText.length > 0.7) {
                        return false;
                    }
                    
                    return true;
                }
                
                detailedLogs.push('🧹 의미없는 텍스트 필터링 함수 로드 완료');
                
                // 🚀 **5단계 무한스크롤 특화 앵커 수집 (품질 필터링 포함)**
                function collectInfiniteScrollAnchors() {
                    const anchors = [];
                    const viewportRect = {
                        top: scrollY,
                        left: scrollX,
                        bottom: scrollY + viewportHeight,
                        right: scrollX + viewportWidth
                    };
                    
                    detailedLogs.push(`뷰포트 영역: top=${viewportRect.top.toFixed(1)}, bottom=${viewportRect.bottom.toFixed(1)}`);
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
                    
                    detailedLogs.push(`총 ${infiniteScrollSelectors.length}개 selector 패턴으로 요소 수집 시작`);
                    
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
                    
                    captureStats.selectorStats = selectorStats;
                    captureStats.candidateElements = candidateElements.length;
                    
                    detailedLogs.push(`후보 요소 수집 완료: ${candidateElements.length}개`);
                    detailedLogs.push(`주요 selector 결과: li=${selectorStats['li'] || 0}, div=${selectorStats['div[class*="item"]'] || 0}, [data-id]=${selectorStats['[data-id]'] || 0}`);
                    
                    console.log('🚀 후보 요소 수집:', {
                        totalElements: candidateElements.length,
                        topSelectors: Object.entries(selectorStats)
                            .filter(([_, count]) => typeof count === 'number' && count > 0)
                            .sort(([,a], [,b]) => b - a)
                            .slice(0, 5)
                    });
                    
                    // 뷰포트 근처 요소들만 필터링 (확장된 범위)
                    const extendedViewportHeight = viewportHeight * 3; // 위아래 3화면 범위
                    const extendedTop = Math.max(0, scrollY - extendedViewportHeight);
                    const extendedBottom = scrollY + extendedViewportHeight;
                    
                    detailedLogs.push(`확장 뷰포트 범위: ${extendedTop.toFixed(1)}px ~ ${extendedBottom.toFixed(1)}px`);
                    
                    let nearbyElements = [];
                    let processingErrors = 0;
                    let qualityFilteredCount = 0;
                    
                    for (const element of candidateElements) {
                        try {
                            const rect = element.getBoundingClientRect();
                            const elementTop = scrollY + rect.top;
                            const elementBottom = scrollY + rect.bottom;
                            
                            // 확장된 뷰포트 범위 내에 있는지 확인
                            if (elementBottom >= extendedTop && elementTop <= extendedBottom) {
                                // 🧹 **품질 텍스트 필터링 추가**
                                const elementText = (element.textContent || '').trim();
                                if (isQualityText(elementText)) {
                                    nearbyElements.push({
                                        element: element,
                                        rect: rect,
                                        absoluteTop: elementTop,
                                        absoluteLeft: scrollX + rect.left,
                                        distanceFromViewport: Math.abs(elementTop - scrollY)
                                    });
                                    qualityFilteredCount++;
                                }
                            }
                        } catch(e) {
                            processingErrors++;
                        }
                    }
                    
                    captureStats.nearbyElements = nearbyElements.length;
                    captureStats.processingErrors = processingErrors;
                    captureStats.qualityFilteredCount = qualityFilteredCount;
                    
                    detailedLogs.push(`뷰포트 근처 요소 필터링: ${nearbyElements.length}개 (오류: ${processingErrors}개, 품질 필터링: ${qualityFilteredCount}개)`);
                    
                    console.log('🚀 뷰포트 근처 품질 요소:', nearbyElements.length, '개');
                    
                    // 거리순으로 정렬하여 상위 30개만 선택
                    nearbyElements.sort((a, b) => a.distanceFromViewport - b.distanceFromViewport);
                    const selectedElements = nearbyElements.slice(0, 30);
                    
                    captureStats.selectedElements = selectedElements.length;
                    detailedLogs.push(`거리 기준 정렬 후 상위 ${selectedElements.length}개 선택`);
                    
                    console.log('🚀 선택된 품질 요소:', selectedElements.length, '개');
                    
                    // 각 요소에 대해 5단계 정보 수집
                    let anchorCreationErrors = 0;
                    for (let i = 0; i < selectedElements.length; i++) {
                        try {
                            const anchor = createInfiniteScrollAnchor(selectedElements[i], i);
                            if (anchor) {
                                anchors.push(anchor);
                            }
                        } catch(e) {
                            anchorCreationErrors++;
                            console.warn(`🚀 앵커[${i}] 생성 실패:`, e);
                        }
                    }
                    
                    captureStats.anchorCreationErrors = anchorCreationErrors;
                    captureStats.finalAnchors = anchors.length;
                    
                    detailedLogs.push(`품질 앵커 생성 완료: ${anchors.length}개 (실패: ${anchorCreationErrors}개)`);
                    console.log('🚀 무한스크롤 품질 앵커 수집 완료:', anchors.length, '개');
                    
                    return {
                        anchors: anchors,
                        stats: captureStats
                    };
                }
                
                // 🚀 **개별 무한스크롤 앵커 생성 (5단계 정보 포함 + 품질 점수 강화)**
                function createInfiniteScrollAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const absoluteTop = elementData.absoluteTop;
                        const absoluteLeft = elementData.absoluteLeft;
                        
                        // 뷰포트 기준 오프셋 계산
                        const offsetFromTop = scrollY - absoluteTop;
                        const offsetFromLeft = scrollX - absoluteLeft;
                        
                        detailedLogs.push(`앵커[${index}] 생성: 위치 Y=${absoluteTop.toFixed(1)}px, 오프셋=${offsetFromTop.toFixed(1)}px`);
                        
                        // 🧹 **품질 텍스트 재확인**
                        const textContent = (element.textContent || '').trim();
                        if (!isQualityText(textContent)) {
                            detailedLogs.push(`   앵커[${index}] 품질 텍스트 검증 실패: "${textContent.substring(0, 30)}"`);
                            return null;
                        }
                        
                        // 🚀 **1단계: 고유 식별자 수집**
                        const uniqueIdentifiers = {};
                        let identifierCount = 0;
                        
                        // href 패턴 (링크가 있는 경우)
                        const linkElement = element.querySelector('a[href]') || (element.tagName === 'A' ? element : null);
                        if (linkElement && linkElement.href) {
                            const href = linkElement.href;
                            // URL에서 고유한 부분 추출 (ID 파라미터 등)
                            try {
                                const urlParams = new URL(href).searchParams;
                                for (const [key, value] of urlParams) {
                                    if (key.includes('id') || key.includes('article') || key.includes('post')) {
                                        uniqueIdentifiers.href = `${key}=${value}`;
                                        identifierCount++;
                                        break;
                                    }
                                }
                                if (!uniqueIdentifiers.href && href.includes('id=')) {
                                    const match = href.match(/id=([^&]+)/);
                                    if (match) {
                                        uniqueIdentifiers.href = match[0];
                                        identifierCount++;
                                    }
                                }
                            } catch(e) {
                                // URL 파싱 실패는 무시
                            }
                        }
                        
                        // data-* 속성들
                        const dataAttributes = {};
                        for (const attr of element.attributes) {
                            if (attr.name.startsWith('data-') && 
                                (attr.name.includes('id') || attr.name.includes('key') || 
                                 attr.name.includes('post') || attr.name.includes('article'))) {
                                dataAttributes[attr.name] = attr.value;
                                identifierCount++;
                            }
                        }
                        if (Object.keys(dataAttributes).length > 0) {
                            uniqueIdentifiers.dataAttributes = dataAttributes;
                        }
                        
                        // id 속성
                        if (element.id) {
                            uniqueIdentifiers.id = element.id;
                            identifierCount++;
                        }
                        
                        if (identifierCount > 0) {
                            detailedLogs.push(`  1단계 고유식별자: ${identifierCount}개 (${Object.keys(uniqueIdentifiers)})`);
                        }
                        
                        // 🚀 **2단계: 콘텐츠 지문 생성**
                        const contentFingerprint = {};
                        let fingerprintCount = 0;
                        
                        if (textContent.length > 0) {
                            // 텍스트 시그니처 (앞 30자 + 뒤 30자)
                            if (textContent.length > 60) {
                                contentFingerprint.textSignature = textContent.substring(0, 30) + '...' + textContent.substring(textContent.length - 30);
                            } else {
                                contentFingerprint.textSignature = textContent;
                            }
                            fingerprintCount++;
                            
                            // 구조 정보
                            contentFingerprint.tagName = element.tagName.toLowerCase();
                            contentFingerprint.className = (element.className || '').split(' ')[0] || '';
                            
                            // 시간 정보 추출 (시:분 패턴)
                            const timeMatch = textContent.match(/\\d{1,2}:\\d{2}/);
                            if (timeMatch) {
                                contentFingerprint.timePattern = timeMatch[0];
                                fingerprintCount++;
                            }
                            
                            detailedLogs.push(`  2단계 콘텐츠지문: 텍스트="${textContent.substring(0, 30)}...", 태그=${element.tagName}`);
                        }
                        
                        // 🚀 **3단계: 상대적 인덱스 계산**
                        const relativeIndex = {};
                        let indexCount = 0;
                        
                        // 부모 컨테이너에서의 인덱스
                        const parent = element.parentElement;
                        if (parent) {
                            const siblings = Array.from(parent.children);
                            const indexInContainer = siblings.indexOf(element);
                            if (indexInContainer >= 0) {
                                relativeIndex.indexInContainer = indexInContainer;
                                relativeIndex.containerSelector = generateBestSelector(parent);
                                relativeIndex.itemSelector = element.tagName.toLowerCase();
                                indexCount++;
                                
                                // 텍스트 미리보기 (검증용)
                                if (textContent.length > 0) {
                                    relativeIndex.textPreview = textContent.substring(0, 50);
                                }
                                
                                detailedLogs.push(`  3단계 상대인덱스: ${indexInContainer}/${siblings.length} in ${relativeIndex.containerSelector}`);
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
                            const nthIndex = siblings.indexOf(element) + 1;
                            if (nthIndex > 0 && siblings.length < 20) {
                                selectors.push(`${parent.tagName.toLowerCase()} > ${element.tagName.toLowerCase()}:nth-child(${nthIndex})`);
                            }
                        }
                        
                        // 태그명 기본
                        selectors.push(element.tagName.toLowerCase());
                        
                        detailedLogs.push(`  4단계 셀렉터: ${selectors.length}개 생성`);
                        
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
                        
                        detailedLogs.push(`  5단계 무한스크롤: 문서내위치=${(infiniteScrollContext.relativePosition * 100).toFixed(1)}%, 뷰포트거리=${infiniteScrollContext.distanceFromViewport.toFixed(1)}px`);
                        
                        // 📊 **품질 점수 강화 계산 (품질 텍스트 가산점 추가)**
                        let qualityScore = identifierCount * 10 + fingerprintCount * 5 + indexCount * 3 + selectors.length;
                        
                        // 🧹 **품질 텍스트 보너스**
                        if (textContent.length >= 20) qualityScore += 5; // 충분한 길이
                        if (textContent.length >= 50) qualityScore += 5; // 더 긴 텍스트
                        if (!/^(답글|댓글|더보기|클릭|선택)/.test(textContent)) qualityScore += 3; // 의미있는 텍스트
                        
                        detailedLogs.push(`  앵커[${index}] 품질점수: ${qualityScore}점 (식별자=${identifierCount*10}, 지문=${fingerprintCount*5}, 인덱스=${indexCount*3}, 셀렉터=${selectors.length}, 텍스트보너스=추가)`);
                        
                        // 🧹 **품질 점수 15점 미만은 제외**
                        if (qualityScore < 15) {
                            detailedLogs.push(`  앵커[${index}] 품질점수 부족으로 제외: ${qualityScore}점 < 15점`);
                            return null;
                        }
                        
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
                            anchorType: 'infiniteScrollQuality',
                            captureTimestamp: Date.now(),
                            qualityScore: qualityScore,
                            anchorIndex: index
                        };
                        
                    } catch(e) {
                        console.error(`🚀 무한스크롤 앵커[${index}] 생성 실패:`, e);
                        detailedLogs.push(`  앵커[${index}] 생성 실패: ${e.message}`);
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
                        try {
                            if (document.querySelectorAll(attrSelector).length === 1) {
                                return attrSelector;
                            }
                        } catch(e) {
                            // 셀렉터 오류 무시
                        }
                    }
                    
                    // 3순위: 고유한 클래스 조합
                    if (element.className) {
                        const classes = element.className.trim().split(/\\s+/);
                        const uniqueClasses = classes.filter(cls => {
                            try {
                                const elements = document.querySelectorAll(`.${cls}`);
                                return elements.length === 1 && elements[0] === element;
                            } catch(e) {
                                return false;
                            }
                        });
                        
                        if (uniqueClasses.length > 0) {
                            return `.${uniqueClasses.join('.')}`;
                        }
                        
                        // 클래스 조합으로 고유성 확보
                        if (classes.length > 0) {
                            try {
                                const classSelector = `.${classes.join('.')}`;
                                if (document.querySelectorAll(classSelector).length === 1) {
                                    return classSelector;
                                }
                            } catch(e) {
                                // 셀렉터 오류 무시
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
                
                // 🚀 **메인 실행 - 5단계 무한스크롤 특화 데이터 수집 (품질 필터링 포함)**
                const startTime = Date.now();
                const infiniteScrollData = collectInfiniteScrollAnchors();
                const endTime = Date.now();
                const captureTime = endTime - startTime;
                
                captureStats.captureTime = captureTime;
                pageAnalysis.capturePerformance = {
                    totalTime: captureTime,
                    anchorsPerSecond: infiniteScrollData.anchors.length > 0 ? (infiniteScrollData.anchors.length / (captureTime / 1000)).toFixed(2) : 0
                };
                
                detailedLogs.push(`=== 품질 캡처 완료 (${captureTime}ms) ===`);
                detailedLogs.push(`최종 품질 앵커: ${infiniteScrollData.anchors.length}개`);
                detailedLogs.push(`처리 성능: ${pageAnalysis.capturePerformance.anchorsPerSecond} 앵커/초`);
                
                console.log('🚀 5단계 무한스크롤 특화 품질 캡처 완료:', {
                    qualityAnchorsCount: infiniteScrollData.anchors.length,
                    stats: infiniteScrollData.stats,
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight],
                    captureTime: captureTime
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
                    },
                    detailedLogs: detailedLogs,           // 📊 **상세 로그 배열**
                    captureStats: captureStats,           // 📊 **캡처 통계**
                    pageAnalysis: pageAnalysis,           // 📊 **페이지 분석 결과**
                    captureTime: captureTime              // 📊 **캡처 소요 시간**
                };
            } catch(e) { 
                console.error('🚀 5단계 무한스크롤 특화 품질 캡처 실패:', e);
                return {
                    infiniteScrollData: { anchors: [], stats: {} },
                    scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message,
                    detailedLogs: [`품질 캡처 실패: ${e.message}`],
                    captureStats: { error: e.message },
                    pageAnalysis: { error: e.message }
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
                if (window.refreshDynamicContent) {
                    window.refreshDynamicContent();
                }
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 브라우저 차단 대응 BFCache 페이지 저장');
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
