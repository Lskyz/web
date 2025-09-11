//
//  BFCacheSnapshotManager.swift
//  📸 **4요소 패키지 조합 BFCache 페이지 스냅샷 및 복원 시스템**
//  🎯 **4요소 패키지 구조** - {id, type, ts, kw} 패키지를 앵커마다 동시 포함
//  🔧 **패키지 기반 복원** - 단계별 시도가 아닌 4요소 패키지 통합 매칭
//  🐛 **디버깅 강화** - 실패 원인 정확한 추적과 로깅
//  🌐 **무한스크롤 특화** - 동적 콘텐츠 로드 대응 복원 지원
//  🔧 **범용 selector 확장** - 모든 사이트 호환 selector 패턴
//  🚫 **JavaScript 반환값 타입 오류 수정** - Swift 호환성 보장
//  ✅ **selector 문법 오류 수정** - 유효한 CSS selector만 사용
//  🎯 **패키지 복원 로직** - 선택자 처리 및 허용 오차 개선
//  🔥 **4요소 패키지 우선** - 고유식별자+타입+타임스탬프+키워드 통합
//  ✅ **Promise 제거** - 직접 실행으로 jsState 캡처 수정
//  🎯 **스크롤 위치 기반 앵커 선택 개선** - 실제 컨텐츠 요소 우선
//  🔧 **iframe 복원 제거** - 불필요한 단계 제거
//  ✅ **복원 검증 로직 수정** - 실제 스크롤 위치 정확 측정
//  🚀 **4요소 패키지 앵커** - 모든 사이트 범용 대응
//  📊 **세세한 과정로그 추가** - 앵커 px 지점 및 긴페이지 어긋남 원인 상세 추적
//  🧹 **의미없는 텍스트 필터링** - 에러메시지, 로딩메시지 등 제외
//  🔄 **데이터 프리로딩 모드** - 복원 전 저장시점까지 콘텐츠 선로딩
//  📦 **배치 로딩 시스템** - 연속적 더보기 호출로 충분한 콘텐츠 확보
//  🐛 **스코프 에러 수정** - JavaScript 변수 정의 순서 개선
//  🎯 **4요소 패키지 앵커** - id+type+ts+kw 패키지로 정확한 복원
//  👁️ **보이는 요소만 캡처** - 실제 표시되는 활성 요소만 선별 캡처
//  🚫 **JS 타입 오류 수정** - Swift 호환 기본 타입만 반환

import UIKit
import WebKit
import SwiftUI

// MARK: - 📸 **4요소 패키지 조합 BFCache 페이지 스냅샷**
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
    
    // 🚀 **핵심 개선: 4요소 패키지 조합 복원 + 데이터 프리로딩**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🚀 4요소 패키지 조합 BFCache 복원 시작")
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
            
            if let packageAnchors = jsState["fourElementPackageAnchors"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🎯 4요소 패키지 앵커 데이터 확인: \(Array(packageAnchors.keys))")
                
                if let anchors = packageAnchors["anchors"] as? [[String: Any]] {
                    let validPackageAnchors = anchors.filter { anchor in
                        if let package = anchor["fourElementPackage"] as? [String: Any] {
                            let hasId = package["id"] != nil
                            let hasType = package["type"] != nil
                            let hasTs = package["ts"] != nil
                            let hasKw = package["kw"] != nil
                            return hasId && hasType && hasTs && hasKw
                        }
                        return false
                    }
                    
                    TabPersistenceManager.debugMessages.append("🎯 4요소 패키지 앵커: \(anchors.count)개 발견 (완전 패키지: \(validPackageAnchors.count)개)")
                    
                    // 📊 **완전 패키지 앵커별 상세 정보 로깅**
                    for (index, anchor) in validPackageAnchors.prefix(3).enumerated() {
                        if let package = anchor["fourElementPackage"] as? [String: Any] {
                            let id = package["id"] as? String ?? "unknown"
                            let type = package["type"] as? String ?? "unknown"
                            let ts = package["ts"] as? String ?? "unknown"
                            let kw = package["kw"] as? String ?? "unknown"
                            TabPersistenceManager.debugMessages.append("📊 완전패키지앵커[\(index)] 4요소: id=\(id), type=\(type), ts=\(ts), kw=\(kw)")
                        }
                        
                        if let absolutePos = anchor["absolutePosition"] as? [String: Any] {
                            let top = absolutePos["top"] as? Double ?? 0
                            let left = absolutePos["left"] as? Double ?? 0
                            TabPersistenceManager.debugMessages.append("📊 완전패키지앵커[\(index)] 절대위치: X=\(String(format: "%.1f", left))px, Y=\(String(format: "%.1f", top))px")
                        }
                        
                        if let qualityScore = anchor["qualityScore"] as? Int {
                            TabPersistenceManager.debugMessages.append("📊 완전패키지앵커[\(index)] 품질점수: \(qualityScore)점")
                        }
                    }
                    
                    if validPackageAnchors.count > 3 {
                        TabPersistenceManager.debugMessages.append("📊 나머지 \(validPackageAnchors.count - 3)개 완전 패키지 앵커 생략...")
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🎯 4요소 패키지 앵커 없음")
                }
                
                if let stats = packageAnchors["stats"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 수집 통계: \(stats)")
                }
            } else {
                TabPersistenceManager.debugMessages.append("🎯 4요소 패키지 데이터 없음")
            }
        } else {
            TabPersistenceManager.debugMessages.append("🔥 jsState 캡처 완전 실패 - nil")
        }
        
        // 🔄 **1단계: 데이터 프리로딩 실행 (복원 전에)**
        if preloadingConfig.enableDataPreloading {
            performDataPreloading(to: webView) { preloadSuccess in
                TabPersistenceManager.debugMessages.append("🔄 데이터 프리로딩 완료: \(preloadSuccess ? "성공" : "실패")")
                
                // 🚀 **2단계: 4요소 패키지 복원 실행**
                self.performFourElementPackageRestore(to: webView)
                
                // 🔧 **3단계: 기존 상태별 분기 로직**
                self.handleCaptureStatusBasedRestore(to: webView, completion: completion)
            }
        } else {
            // 프리로딩 비활성화 시 바로 복원
            TabPersistenceManager.debugMessages.append("🔄 데이터 프리로딩 비활성화 - 바로 복원")
            performFourElementPackageRestore(to: webView)
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
    
    // 🔄 **🚫 수정: Swift 호환 데이터 프리로딩 JavaScript 생성**
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
                const timeoutSeconds = parseInt('\(timeoutSeconds)');
                
                detailedLogs.push('🔄 데이터 프리로딩 설정');
                detailedLogs.push('목표 높이: ' + targetContentHeight.toFixed(1) + 'px');
                detailedLogs.push('최대 시도: ' + maxAttempts + '회');
                detailedLogs.push('배치 크기: ' + batchSize + '개');
                detailedLogs.push('배치 로딩: ' + (enableBatchLoading ? '활성화' : '비활성화'));
                
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
                    
                    // 🚫 **Swift 호환 기본 타입만 반환**
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
                    for (let i = 0; i < loadMoreButtons.length; i++) {
                        const btn = loadMoreButtons[i];
                        if (btn && typeof btn.click === 'function') {
                            try {
                                btn.click();
                                clickedButtons++;
                                detailedLogs.push('더보기 버튼[' + i + '] 클릭: ' + (btn.className || btn.tagName));
                            } catch(e) {
                                detailedLogs.push('더보기 버튼[' + i + '] 클릭 실패: ' + e.message);
                            }
                        }
                    }
                    triggers.push({ method: 'load_more_buttons', found: loadMoreButtons.length, clicked: clickedButtons });
                    
                    // 4. AJAX 요청 감지 및 대기
                    let ajaxRequests = 0;
                    if (window.XMLHttpRequest && window.XMLHttpRequest.prototype.open) {
                        // AJAX 요청이 있을 가능성 체크
                        ajaxRequests = 1; // 가정
                    }
                    triggers.push({ method: 'ajax_detection', estimated: ajaxRequests });
                    
                    // 5. 터치 이벤트 (모바일) - 🚫 try-catch로 안전 처리
                    try {
                        if (typeof TouchEvent !== 'undefined') {
                            const touchEvent = new TouchEvent('touchend', { bubbles: true });
                            document.dispatchEvent(touchEvent);
                            triggers.push({ method: 'touch_events', success: true });
                        } else {
                            triggers.push({ method: 'touch_events', success: false, error: 'TouchEvent not supported' });
                        }
                    } catch(e) {
                        triggers.push({ method: 'touch_events', success: false, error: e.message });
                    }
                    
                    return triggers;
                }
                
                // 📊 **동기적 처리로 변경 - Promise 제거**
                let totalBatches = 0;
                let totalTriggered = 0;
                let heightIncreased = false;
                let batchProcessingLogs = [];
                
                const initialState = getCurrentPageState();
                detailedLogs.push('초기 상태: 높이=' + initialState.currentHeight.toFixed(1) + 'px, 필요=' + (initialState.needsMore ? '예' : '아니오'));
                
                if (!initialState.needsMore) {
                    detailedLogs.push('목표 높이 이미 달성 - 프리로딩 불필요');
                    
                    // 🚫 **Swift 호환 기본 타입으로 반환**
                    return {
                        success: true,
                        reason: 'already_sufficient',
                        loadedContentHeight: initialState.currentHeight,
                        loadingAttempts: 0,
                        batchResults: [],
                        detailedLogs: detailedLogs
                    };
                }
                
                // 📦 **배치 로딩 실행 (동기적)**
                if (enableBatchLoading) {
                    detailedLogs.push('📦 배치 로딩 모드 시작');
                    
                    for (let batch = 0; batch < batchSize && loadingAttempts < maxAttempts; batch++) {
                        const beforeState = getCurrentPageState();
                        
                        detailedLogs.push('배치[' + (batch + 1) + '/' + batchSize + '] 시작: 현재 높이=' + beforeState.currentHeight.toFixed(1) + 'px');
                        
                        // 무한스크롤 트리거 실행
                        const triggers = triggerInfiniteScroll();
                        totalTriggered += triggers.length;
                        loadingAttempts++;
                        
                        // 🚫 **동기적 대기 처리 (Promise 대신 로그만)**
                        detailedLogs.push('배치[' + (batch + 1) + '] 트리거 완료: ' + triggers.length + '개 방법 시도');
                        
                        // 즉시 높이 변화 확인
                        const afterState = getCurrentPageState();
                        const heightDiff = afterState.currentHeight - beforeState.currentHeight;
                        
                        detailedLogs.push('배치[' + (batch + 1) + '] 완료: 높이 변화=' + heightDiff.toFixed(1) + 'px');
                        
                        if (heightDiff > 50) { // 50px 이상 증가하면 성공
                            heightIncreased = true;
                            detailedLogs.push('배치[' + (batch + 1) + '] 높이 증가 감지: ' + heightDiff.toFixed(1) + 'px');
                        }
                        
                        // 🚫 **기본 타입으로 배치 결과 저장**
                        batchResults.push({
                            batchIndex: batch + 1,
                            beforeHeight: beforeState.currentHeight,
                            afterHeight: afterState.currentHeight,
                            heightDiff: heightDiff,
                            triggersUsed: triggers.length,
                            success: heightDiff > 50
                        });
                        
                        totalBatches++;
                        
                        // 목표 높이 달성 시 중단
                        if (afterState.currentHeight >= targetContentHeight) {
                            detailedLogs.push('목표 높이 달성: ' + afterState.currentHeight.toFixed(1) + 'px >= ' + targetContentHeight.toFixed(1) + 'px');
                            break;
                        }
                    }
                } else {
                    detailedLogs.push('🔄 단일 로딩 모드 시작');
                    // 단일 로딩 모드
                    const beforeState = getCurrentPageState();
                    const triggers = triggerInfiniteScroll();
                    loadingAttempts = 1;
                    totalTriggered = triggers.length;
                    totalBatches = 1;
                    
                    const afterState = getCurrentPageState();
                    heightIncreased = afterState.currentHeight > beforeState.currentHeight + 50;
                    
                    batchResults.push({
                        batchIndex: 1,
                        beforeHeight: beforeState.currentHeight,
                        afterHeight: afterState.currentHeight,
                        heightDiff: afterState.currentHeight - beforeState.currentHeight,
                        triggersUsed: triggers.length,
                        success: heightIncreased
                    });
                }
                
                const finalState = getCurrentPageState();
                detailedLogs.push('프리로딩 완료');
                detailedLogs.push('최종 높이: ' + finalState.currentHeight.toFixed(1) + 'px');
                detailedLogs.push('높이 증가: ' + (heightIncreased ? '성공' : '실패'));
                
                // 🚫 **Swift 호환 기본 타입만 반환**
                return {
                    success: heightIncreased || finalState.currentHeight >= targetContentHeight * 0.8,
                    reason: heightIncreased ? 'height_increased' : 'no_height_change',
                    loadedContentHeight: finalState.currentHeight,
                    loadingAttempts: loadingAttempts,
                    batchResults: batchResults,
                    totalBatches: totalBatches,
                    totalTriggered: totalTriggered,
                    heightIncreased: heightIncreased,
                    initialHeight: initialState.currentHeight,
                    targetHeight: targetContentHeight,
                    detailedLogs: detailedLogs
                };
                
            } catch(e) {
                console.error('🔄 데이터 프리로딩 실패:', e);
                
                // 🚫 **에러 시에도 Swift 호환 기본 타입만 반환**
                return {
                    success: false,
                    reason: 'exception',
                    error: e.message,
                    loadedContentHeight: 0,
                    loadingAttempts: 0,
                    batchResults: [],
                    detailedLogs: ['프리로딩 실패: ' + e.message]
                };
            }
        })()
        """
    }
    
    // 🔧 **기존 상태별 분기 로직 분리**
    private func handleCaptureStatusBasedRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        switch captureStatus {
        case .failed:
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패 상태 - 4요소 패키지 복원만 수행")
            completion(true)
            return
            
        case .visualOnly:
            TabPersistenceManager.debugMessages.append("🖼️ 이미지만 캡처된 상태 - 4요소 패키지 복원 + 최종보정")
            
        case .partial:
            TabPersistenceManager.debugMessages.append("⚡ 부분 캡처 상태 - 4요소 패키지 복원 + 브라우저 차단 대응")
            
        case .complete:
            TabPersistenceManager.debugMessages.append("✅ 완전 캡처 상태 - 4요소 패키지 복원 + 브라우저 차단 대응")
        }
        
        TabPersistenceManager.debugMessages.append("🌐 4요소 패키지 복원 후 브라우저 차단 대응 시작")
        
        // 🔧 **4요소 패키지 복원 후 브라우저 차단 대응 단계 실행**
        DispatchQueue.main.async {
            self.performBrowserBlockingWorkaround(to: webView, completion: completion)
        }
    }
    
    // 🚀 **새로 추가: 4요소 패키지 1단계 복원 메서드**
    private func performFourElementPackageRestore(to webView: WKWebView) {
        TabPersistenceManager.debugMessages.append("🚀 4요소 패키지 1단계 복원 시작")
        
        // 1. 네이티브 스크롤뷰 기본 설정 (백업용)
        let targetPos = self.scrollPosition
        TabPersistenceManager.debugMessages.append("📊 네이티브 스크롤뷰 백업 설정: X=\(String(format: "%.1f", targetPos.x))px, Y=\(String(format: "%.1f", targetPos.y))px")
        webView.scrollView.setContentOffset(targetPos, animated: false)
        
        // 2. 🚀 **4요소 패키지 복원 JavaScript 실행**
        let fourElementPackageRestoreJS = generateFourElementPackageRestoreScript()
        
        TabPersistenceManager.debugMessages.append("🚀 4요소 패키지 복원 JavaScript 실행 중...")
        
        // 동기적 JavaScript 실행 (즉시)
        webView.evaluateJavaScript(fourElementPackageRestoreJS) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("🚀 4요소 패키지 복원 JS 실행 오류: \(error.localizedDescription)")
                return
            }
            
            // 🚫 **수정: 안전한 타입 체크로 변경**
            var success = false
            if let resultDict = result as? [String: Any] {
                success = (resultDict["success"] as? Bool) ?? false
                
                if let method = resultDict["method"] as? String {
                    TabPersistenceManager.debugMessages.append("🚀 사용된 복원 방법: \(method)")
                }
                if let anchorInfo = resultDict["anchorInfo"] as? String {
                    TabPersistenceManager.debugMessages.append("🚀 앵커 정보: \(anchorInfo)")
                }
                if let errorMsg = resultDict["error"] as? String {
                    TabPersistenceManager.debugMessages.append("🚀 4요소 패키지 복원 오류: \(errorMsg)")
                }
                if let debugInfo = resultDict["debug"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🚀 4요소 패키지 복원 디버그: \(debugInfo)")
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
                
                if let packageAnalysis = resultDict["packageAnalysis"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 패키지 분석 결과: \(packageAnalysis)")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🚀 4요소 패키지 복원: \(success ? "성공" : "실패")")
        }
        
        TabPersistenceManager.debugMessages.append("🚀 4요소 패키지 1단계 복원 완료")
    }
    
    // 🚀 **핵심: 4요소 패키지 복원 JavaScript 생성**
    private func generateFourElementPackageRestoreScript() -> String {
        let targetPos = self.scrollPosition
        let targetPercent = self.scrollPositionPercent
        
        // jsState에서 4요소 패키지 데이터 추출
        var fourElementPackageDataJSON = "null"
        
        if let jsState = self.jsState,
           let fourElementPackageData = jsState["fourElementPackageAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(fourElementPackageData) {
            fourElementPackageDataJSON = dataJSON
        }
        
        return """
        (function() {
            try {
                const targetX = parseFloat('\(targetPos.x)');
                const targetY = parseFloat('\(targetPos.y)');
                const targetPercentX = parseFloat('\(targetPercent.x)');
                const targetPercentY = parseFloat('\(targetPercent.y)');
                const fourElementPackageData = \(fourElementPackageDataJSON);
                
                // 📊 **상세 로그 수집 배열**
                const detailedLogs = [];
                const pageAnalysis = {};
                const packageAnalysis = {};
                let actualRestoreSuccess = false;  // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let practicalSuccess = false;      // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalCurrentY = 0;             // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalCurrentX = 0;             // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalDiffY = 0;                // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalDiffX = 0;                // 🐛 **스코프 에러 수정: 변수 미리 정의**
                let finalWithinTolerance = false;  // 🐛 **스코프 에러 수정: 변수 미리 정의**
                
                detailedLogs.push('🚀 4요소 패키지 복원 시작');
                detailedLogs.push('📊 목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                detailedLogs.push('📊 목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                detailedLogs.push('📊 4요소 패키지 데이터 존재: ' + (!!fourElementPackageData));
                detailedLogs.push('📊 앵커 개수: ' + (fourElementPackageData?.anchors?.length || 0) + '개');
                
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
                
                detailedLogs.push('📊 현재 스크롤: X=' + currentScrollX.toFixed(1) + 'px, Y=' + currentScrollY.toFixed(1) + 'px');
                detailedLogs.push('📊 현재 뷰포트: ' + currentViewportWidth.toFixed(0) + ' x ' + currentViewportHeight.toFixed(0));
                detailedLogs.push('📊 현재 콘텐츠: ' + currentContentWidth.toFixed(0) + ' x ' + currentContentHeight.toFixed(0));
                detailedLogs.push('📊 현재 최대 스크롤: X=' + currentMaxScrollX.toFixed(1) + 'px, Y=' + currentMaxScrollY.toFixed(1) + 'px');
                
                console.log('🚀 4요소 패키지 복원 시작:', {
                    target: [targetX, targetY],
                    percent: [targetPercentX, targetPercentY],
                    hasFourElementPackageData: !!fourElementPackageData,
                    anchorsCount: fourElementPackageData?.anchors?.length || 0,
                    pageAnalysis: pageAnalysis
                });
                
                // 🧹 **의미없는 텍스트 필터링 함수**
                function isQualityText(text) {
                    if (!text || typeof text !== 'string') return false;
                    
                    const cleanText = text.trim();
                    if (cleanText.length < 5) return false; // 너무 짧은 텍스트
                    
                    // 🧹 **의미없는 텍스트 패턴들** - 수정된 이스케이프 시퀀스
                    const meaninglessPatterns = [
                        /^(투표는|표시되지|않습니다|네트워크|문제로|연결되지|잠시|후에|다시|시도)/,
                        /^(로딩|loading|wait|please|기다려|잠시만)/i,
                        /^(오류|에러|error|fail|실패|죄송|sorry)/i,
                        /^(확인|ok|yes|no|취소|cancel|닫기|close)/i,
                        /^(더보기|more|load|next|이전|prev|previous)/i,
                        /^(클릭|click|tap|터치|touch|선택)/i,
                        /^(답글|댓글|reply|comment|쓰기|작성)/i,
                        /^[\\s\\.\\-_=+]{2,}$/, // 특수문자만 - 수정된 이스케이프
                        /^[0-9\\s\\.\\/\\-:]{3,}$/, // 숫자와 특수문자만 - 수정된 이스케이프
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
                
                // 🎯 **4요소 패키지 기반 복원 시스템**
                let restoredByPackage = false;
                let usedMethod = 'fallback';
                let anchorInfo = 'none';
                let debugInfo = {};
                let errorMsg = null;
                let verificationResult = {};
                
                // 4요소 패키지 앵커 데이터가 있는 경우 우선 시도
                if (fourElementPackageData && fourElementPackageData.anchors && fourElementPackageData.anchors.length > 0) {
                    detailedLogs.push('🎯 4요소 패키지 앵커 복원 시도 시작');
                    
                    const anchors = fourElementPackageData.anchors;
                    
                    // 🧹 **완전한 4요소 패키지 앵커 필터링**
                    const completePackageAnchors = anchors.filter(function(anchor) {
                        if (!anchor.fourElementPackage) return false;
                        const pkg = anchor.fourElementPackage;
                        const hasCompletePackage = pkg.id && pkg.type && pkg.ts && pkg.kw;
                        const hasQualityText = anchor.textContent && isQualityText(anchor.textContent);
                        const hasQualityScore = (anchor.qualityScore || 0) >= 40; // 4요소 패키지는 40점 이상
                        return hasCompletePackage && hasQualityText && hasQualityScore;
                    });
                    
                    detailedLogs.push('   완전한 4요소 패키지 앵커: ' + completePackageAnchors.length + '개 (전체 ' + anchors.length + '개)');
                    packageAnalysis.completePackageAnchors = completePackageAnchors.length;
                    packageAnalysis.totalAnchors = anchors.length;
                    
                    // 완전한 패키지 앵커부터 시도
                    for (let anchorIndex = 0; anchorIndex < completePackageAnchors.length; anchorIndex++) {
                        const anchor = completePackageAnchors[anchorIndex];
                        const pkg = anchor.fourElementPackage; // 4요소 패키지: {id, type, ts, kw}
                        
                        detailedLogs.push('🎯 완전패키지앵커[' + anchorIndex + '] 4요소 패키지 시도');
                        detailedLogs.push('   패키지: id="' + pkg.id + '", type="' + pkg.type + '", ts="' + pkg.ts + '", kw="' + pkg.kw + '"');
                        detailedLogs.push('   품질점수: ' + anchor.qualityScore + '점');
                        
                        let foundElement = null;
                        let matchMethod = null;
                        let matchDetails = {};
                        
                        // 🎯 **4요소 패키지 통합 매칭 (동시에 활용)**
                        detailedLogs.push('   4요소 패키지 통합 매칭 시작: id+type+ts+kw');
                        
                        // ① **고유 ID 기반 DOM 검색 (최우선)**
                        if (pkg.id && pkg.id !== 'unknown') {
                            detailedLogs.push('   1순위: 고유ID 검색 "' + pkg.id + '"');
                            
                            // ID 속성 검색
                            const elementById = document.getElementById(pkg.id);
                            if (elementById) {
                                foundElement = elementById;
                                matchMethod = 'package_id_element';
                                matchDetails.method = 'getElementById';
                                matchDetails.selector = '#' + pkg.id;
                                detailedLogs.push('   ✅ ID 요소로 발견: #' + pkg.id);
                            }
                            
                            // data-* 속성 검색 (타입 고려)
                            if (!foundElement) {
                                const dataSelectors = [
                                    '[data-id="' + pkg.id + '"]',
                                    '[data-' + pkg.type + '-id="' + pkg.id + '"]', // 타입별 특화
                                    '[data-item-id="' + pkg.id + '"]',
                                    '[data-post-id="' + pkg.id + '"]',
                                    '[data-comment-id="' + pkg.id + '"]',
                                    '[data-article-id="' + pkg.id + '"]',
                                    '[data-review-id="' + pkg.id + '"]',
                                    '[data-key="' + pkg.id + '"]'
                                ];
                                
                                for (let i = 0; i < dataSelectors.length; i++) {
                                    const selector = dataSelectors[i];
                                    try {
                                        const elements = document.querySelectorAll(selector);
                                        if (elements.length > 0) {
                                            foundElement = elements[0];
                                            matchMethod = 'package_id_data_attr';
                                            matchDetails.method = 'data_attribute';
                                            matchDetails.selector = selector;
                                            detailedLogs.push('   ✅ 데이터 속성으로 발견: ' + selector);
                                            break;
                                        }
                                    } catch(e) {
                                        detailedLogs.push('   셀렉터 오류: ' + selector + ' - ' + e.message);
                                    }
                                }
                            }
                            
                            // href 패턴 검색
                            if (!foundElement && /^[0-9]+$/.test(pkg.id)) {
                                try {
                                    const hrefElements = document.querySelectorAll('a[href*="' + pkg.id + '"]');
                                    if (hrefElements.length > 0) {
                                        foundElement = hrefElements[0];
                                        matchMethod = 'package_id_href';
                                        matchDetails.method = 'href_pattern';
                                        matchDetails.pattern = pkg.id;
                                        detailedLogs.push('   ✅ href 패턴으로 발견: href*="' + pkg.id + '"');
                                    }
                                } catch(e) {
                                    detailedLogs.push('   href 검색 오류: ' + e.message);
                                }
                            }
                        }
                        
                        // ② **타입+키워드 조합 검증 (ID로 찾은 경우 확인용, 못 찾은 경우 대체 검색)**
                        if (foundElement && pkg.type && pkg.kw) {
                            detailedLogs.push('   2순위: 타입+키워드 검증 "' + pkg.type + '" + "' + pkg.kw + '"');
                            
                            // 찾은 요소에 키워드가 포함되어 있는지 확인
                            const elementText = (foundElement.textContent || '').trim();
                            const keywordMatch = elementText.includes(pkg.kw);
                            const typeTagMatch = foundElement.tagName.toLowerCase() === getPreferredTag(pkg.type);
                            
                            detailedLogs.push('   타입 태그 매칭: ' + typeTagMatch + ' (기대: ' + getPreferredTag(pkg.type) + ', 실제: ' + foundElement.tagName.toLowerCase() + ')');
                            detailedLogs.push('   키워드 매칭: ' + keywordMatch + ' ("' + pkg.kw + '" in 텍스트)');
                            
                            if (!keywordMatch && !typeTagMatch) {
                                detailedLogs.push('   ⚠️ ID로 찾았지만 타입+키워드 검증 실패 - 다른 요소 탐색');
                                foundElement = null; // 무효화하고 다른 방법 시도
                                matchMethod = null;
                                matchDetails = {};
                            } else {
                                matchDetails.typeVerified = typeTagMatch;
                                matchDetails.keywordVerified = keywordMatch;
                                detailedLogs.push('   ✅ 타입+키워드 검증 통과');
                            }
                        }
                        
                        // ID로 못 찾은 경우 타입+키워드 조합으로 검색
                        if (!foundElement && pkg.type && pkg.kw) {
                            detailedLogs.push('   2순위 대체: 타입+키워드 조합 검색 "' + pkg.type + '" + "' + pkg.kw + '"');
                            
                            const preferredTags = getPreferredTags(pkg.type);
                            detailedLogs.push('   타입 "' + pkg.type + '" 선호 태그: [' + preferredTags.join(', ') + ']');
                            
                            // 키워드 포함 요소들 찾기
                            const allElements = document.querySelectorAll('*');
                            const keywordElements = [];
                            for (let i = 0; i < allElements.length; i++) {
                                const el = allElements[i];
                                const text = (el.textContent || '').trim();
                                if (isQualityText(text) && text.includes(pkg.kw)) {
                                    keywordElements.push(el);
                                }
                            }
                            
                            detailedLogs.push('   키워드 "' + pkg.kw + '" 포함 요소: ' + keywordElements.length + '개');
                            
                            // 선호 태그 우선순위로 찾기
                            for (let j = 0; j < preferredTags.length; j++) {
                                const tag = preferredTags[j];
                                const tagMatchElements = keywordElements.filter(function(el) {
                                    return el.tagName.toLowerCase() === tag;
                                });
                                if (tagMatchElements.length > 0) {
                                    foundElement = tagMatchElements[0];
                                    matchMethod = 'package_type_keyword';
                                    matchDetails.method = 'type_keyword_combo';
                                    matchDetails.preferredTag = tag;
                                    matchDetails.keywordMatched = true;
                                    detailedLogs.push('   ✅ 타입+키워드로 발견: <' + tag + '> with "' + pkg.kw + '"');
                                    break;
                                }
                            }
                            
                            // 태그 관계없이 키워드 매칭 요소 중 첫 번째
                            if (!foundElement && keywordElements.length > 0) {
                                foundElement = keywordElements[0];
                                matchMethod = 'package_keyword_only';
                                matchDetails.method = 'keyword_only';
                                matchDetails.foundTag = foundElement.tagName.toLowerCase();
                                detailedLogs.push('   ✅ 키워드만으로 발견: <' + foundElement.tagName.toLowerCase() + '> with "' + pkg.kw + '"');
                            }
                        }
                        
                        // ③ **타임스탬프 추가 검증 (시간 정보 일치 확인)**
                        if (foundElement && pkg.ts) {
                            detailedLogs.push('   3순위: 타임스탬프 검증 "' + pkg.ts + '"');
                            
                            const elementText = (foundElement.textContent || '').trim();
                            const tsPattern = pkg.ts.split('T')[0]; // 날짜 부분 (2025-09-09)
                            const timeMatch = elementText.includes(tsPattern) || elementText.includes(pkg.ts);
                            
                            matchDetails.timestampVerified = timeMatch;
                            detailedLogs.push('   타임스탬프 검증: ' + timeMatch + ' ("' + tsPattern + '" in 텍스트)');
                            
                            if (!timeMatch) {
                                detailedLogs.push('   ⚠️ 타임스탬프 불일치 - 경고만 (계속 진행)');
                            }
                        }
                        
                        // 요소를 찾았으면 스크롤 실행
                        if (foundElement) {
                            detailedLogs.push('🎯 4요소 패키지 앵커 발견 - 스크롤 실행');
                            detailedLogs.push('   매칭 방법: ' + matchMethod);
                            detailedLogs.push('   매칭 상세: ' + JSON.stringify(matchDetails));
                            
                            // 📊 **발견된 요소의 정확한 위치 분석**
                            const elementRect = foundElement.getBoundingClientRect();
                            const elementScrollY = currentScrollY + elementRect.top;
                            const elementScrollX = currentScrollX + elementRect.left;
                            
                            detailedLogs.push('   발견된 요소 위치: X=' + elementScrollX.toFixed(1) + 'px, Y=' + elementScrollY.toFixed(1) + 'px');
                            detailedLogs.push('   요소 크기: ' + elementRect.width.toFixed(1) + ' x ' + elementRect.height.toFixed(1));
                            detailedLogs.push('   요소 태그: <' + foundElement.tagName.toLowerCase() + '>');
                            
                            // 오프셋 정보 확인 (기존 앵커 데이터에서)
                            let offsetY = 0;
                            if (anchor.offsetFromTop) {
                                offsetY = parseFloat(anchor.offsetFromTop) || 0;
                                detailedLogs.push('   캡처된 오프셋: ' + offsetY.toFixed(1) + 'px');
                            }
                            
                            // 요소로 스크롤
                            detailedLogs.push('   스크롤 실행: scrollIntoView');
                            foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                            
                            // 오프셋 보정
                            if (offsetY !== 0) {
                                detailedLogs.push('   오프셋 보정: ' + (-offsetY).toFixed(1) + 'px');
                                window.scrollBy(0, -offsetY);
                            }
                            
                            // 📊 **복원 후 위치 확인**
                            const afterScrollY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const afterScrollX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            detailedLogs.push('   복원 후 위치: X=' + afterScrollX.toFixed(1) + 'px, Y=' + afterScrollY.toFixed(1) + 'px');
                            detailedLogs.push('   목표와 차이: X=' + Math.abs(afterScrollX - targetX).toFixed(1) + 'px, Y=' + Math.abs(afterScrollY - targetY).toFixed(1) + 'px');
                            
                            restoredByPackage = true;
                            usedMethod = matchMethod;
                            anchorInfo = 'package_' + pkg.id + '_' + pkg.type + '_' + pkg.kw;
                            debugInfo.matchedPackage = pkg;
                            debugInfo.matchDetails = matchDetails;
                            debugInfo.elementPosition = { x: elementScrollX, y: elementScrollY };
                            debugInfo.afterPosition = { x: afterScrollX, y: afterScrollY };
                            
                            packageAnalysis.successfulAnchor = {
                                index: anchorIndex,
                                package: pkg,
                                matchMethod: matchMethod,
                                matchDetails: matchDetails
                            };
                            
                            break; // 성공했으므로 더 이상 시도하지 않음
                        } else {
                            detailedLogs.push('   완전패키지앵커[' + anchorIndex + '] 4요소 패키지 매칭 실패');
                            detailedLogs.push('   실패 원인: ID="' + pkg.id + '" 검색 실패, 타입+키워드 대체 검색도 실패');
                        }
                    }
                    
                    packageAnalysis.restoredByPackage = restoredByPackage;
                } else {
                    detailedLogs.push('🎯 4요소 패키지 데이터 없음 - 패키지 복원 스킵');
                    packageAnalysis.noPackageData = true;
                }
                
                // 4요소 패키지 복원 실패 시 좌표 기반 폴백
                if (!restoredByPackage) {
                    detailedLogs.push('🚨 4요소 패키지 복원 실패 - 좌표 기반 폴백');
                    performScrollTo(targetX, targetY);
                    usedMethod = 'coordinate_fallback';
                    anchorInfo = 'fallback';
                    errorMsg = '4요소 패키지 복원 실패';
                    packageAnalysis.fallbackUsed = true;
                }
                
                // 🔧 **복원 후 위치 검증 및 보정** - 🚫 setTimeout을 동기적 처리로 변경
                finalCurrentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                finalCurrentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                finalDiffY = Math.abs(finalCurrentY - targetY);
                finalDiffX = Math.abs(finalCurrentX - targetX);
                
                // 4요소 패키지는 더 엄격한 허용 오차 (25px)
                const tolerance = 25;
                finalWithinTolerance = finalDiffX <= tolerance && finalDiffY <= tolerance;
                
                detailedLogs.push('🔧 복원 후 위치 검증 시작');
                detailedLogs.push('   최종 위치: X=' + finalCurrentX.toFixed(1) + 'px, Y=' + finalCurrentY.toFixed(1) + 'px');
                detailedLogs.push('   목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                detailedLogs.push('   위치 차이: X=' + finalDiffX.toFixed(1) + 'px, Y=' + finalDiffY.toFixed(1) + 'px');
                detailedLogs.push('   허용 오차: ' + tolerance + 'px (4요소 패키지 기준)');
                detailedLogs.push('   허용 오차 내: ' + (finalWithinTolerance ? '예' : '아니오'));
                
                verificationResult = {
                    target: [targetX, targetY],
                    final: [finalCurrentX, finalCurrentY],
                    diff: [finalDiffX, finalDiffY],
                    method: usedMethod,
                    tolerance: tolerance,
                    withinTolerance: finalWithinTolerance,
                    packageBased: restoredByPackage,
                    actualRestoreDistance: Math.sqrt(finalDiffX * finalDiffX + finalDiffY * finalDiffY),
                    actualRestoreSuccess: finalDiffY <= 25 // 25px 이내면 실제 성공으로 간주
                };
                
                // 🐛 **스코프 에러 수정: 변수 할당**
                actualRestoreSuccess = verificationResult.actualRestoreSuccess;
                practicalSuccess = finalDiffY <= 40; // 40px 이내면 실용적 성공
                
                detailedLogs.push('   실제 복원 거리: ' + verificationResult.actualRestoreDistance.toFixed(1) + 'px');
                detailedLogs.push('   실제 복원 성공: ' + (actualRestoreSuccess ? '예' : '아니오') + ' (25px 기준)');
                detailedLogs.push('   실용적 복원 성공: ' + (practicalSuccess ? '예' : '아니오') + ' (40px 기준)');
                
                console.log('🚀 4요소 패키지 복원 검증:', verificationResult);
                
                if (actualRestoreSuccess) {
                    detailedLogs.push('✅ 실제 복원 성공: 목표=' + targetY.toFixed(1) + 'px, 실제=' + finalCurrentY.toFixed(1) + 'px, 차이=' + finalDiffY.toFixed(1) + 'px');
                } else {
                    detailedLogs.push('❌ 실제 복원 실패: 목표=' + targetY.toFixed(1) + 'px, 실제=' + finalCurrentY.toFixed(1) + 'px, 차이=' + finalDiffY.toFixed(1) + 'px');
                }
                
                // 🔧 **허용 오차 초과 시 점진적 보정**
                if (!finalWithinTolerance && (finalDiffY > tolerance || finalDiffX > tolerance)) {
                    detailedLogs.push('🔧 허용 오차 초과 - 점진적 보정 시작');
                    detailedLogs.push('   보정 필요 거리: X=' + (targetX - finalCurrentX).toFixed(1) + 'px, Y=' + (targetY - finalCurrentY).toFixed(1) + 'px');
                    
                    const maxDiff = Math.max(finalDiffX, finalDiffY);
                    const steps = Math.min(5, Math.max(2, Math.ceil(maxDiff / 1000)));
                    const stepX = (targetX - finalCurrentX) / steps;
                    const stepY = (targetY - finalCurrentY) / steps;
                    
                    detailedLogs.push('   점진적 보정: ' + steps + '단계, 단계별 이동 X=' + stepX.toFixed(1) + 'px, Y=' + stepY.toFixed(1) + 'px');
                    
                    // 🚫 **동기적 점진적 보정 (setTimeout 제거)**
                    for (let i = 1; i <= steps; i++) {
                        const stepTargetX = finalCurrentX + stepX * i;
                        const stepTargetY = finalCurrentY + stepY * i;
                        performScrollTo(stepTargetX, stepTargetY);
                        detailedLogs.push('   점진적 보정 ' + i + '/' + steps + ': X=' + stepTargetX.toFixed(1) + 'px, Y=' + stepTargetY.toFixed(1) + 'px');
                    }
                    
                    verificationResult.progressiveCorrection = {
                        steps: steps,
                        stepSize: [stepX, stepY],
                        reason: 'tolerance_exceeded'
                    };
                }
                
                // 🚫 **Swift 호환 반환값 (기본 타입만)**
                return {
                    success: true,
                    method: usedMethod,
                    anchorInfo: anchorInfo,
                    packageBased: restoredByPackage,
                    debug: debugInfo,
                    error: errorMsg,
                    verification: verificationResult,
                    detailedLogs: detailedLogs,       // 📊 **상세 로그 배열 추가**
                    pageAnalysis: pageAnalysis,       // 📊 **페이지 분석 결과 추가**
                    packageAnalysis: packageAnalysis  // 📊 **패키지 분석 결과 추가**
                };
                
            } catch(e) { 
                console.error('🚀 4요소 패키지 복원 실패:', e);
                detailedLogs.push('🚀 전체 복원 실패: ' + e.message);
                
                // 🚫 **수정: Swift 호환 반환값**
                return {
                    success: false,
                    method: 'error',
                    anchorInfo: e.message,
                    packageBased: false,
                    error: e.message,
                    debug: { globalError: e.message },
                    detailedLogs: detailedLogs,
                    pageAnalysis: pageAnalysis,
                    packageAnalysis: packageAnalysis
                };
            }
            
            // 🔧 **헬퍼 함수들**
            
            // 통합된 스크롤 실행 함수
            function performScrollTo(x, y) {
                detailedLogs.push('🔧 스크롤 실행: X=' + x.toFixed(1) + 'px, Y=' + y.toFixed(1) + 'px');
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
            
            // 콘텐츠 타입별 선호 태그 반환
            function getPreferredTag(contentType) {
                const typeTagMap = {
                    'article': 'article',
                    'post': 'div',
                    'comment': 'div',
                    'reply': 'div',
                    'review': 'div',
                    'news': 'article',
                    'blog': 'article'
                };
                return typeTagMap[contentType] || 'div';
            }
            
            // 콘텐츠 타입별 선호 태그들 반환 (우선순위 배열)
            function getPreferredTags(contentType) {
                const typeTagsMap = {
                    'article': ['article', 'div', 'section'],
                    'post': ['div', 'article', 'section'],
                    'comment': ['div', 'li', 'section'],
                    'reply': ['div', 'li', 'p'],
                    'review': ['div', 'li', 'article'],
                    'news': ['article', 'div', 'section'],
                    'blog': ['article', 'div', 'section']
                };
                return typeTagsMap[contentType] || ['div', 'section', 'article'];
            }
        })()
        """
    }
    
    // 🚫 **브라우저 차단 대응 시스템 (점진적 스크롤) - ✅ iframe 복원 제거**
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
                        detailedLogs.push('목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                        
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
                        
                        detailedLogs.push('초기 위치: X=' + initialScrollX.toFixed(1) + 'px, Y=' + initialScrollY.toFixed(1) + 'px');
                        detailedLogs.push('뷰포트: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                        detailedLogs.push('콘텐츠: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                        detailedLogs.push('최대 스크롤: X=' + maxScrollX.toFixed(1) + 'px, Y=' + maxScrollY.toFixed(1) + 'px');
                        
                        // 📊 **목표 위치 실현 가능성 분석**
                        const isTargetReachableY = targetY <= maxScrollY + tolerance;
                        const isTargetReachableX = targetX <= maxScrollX + tolerance;
                        const initialDiffY = Math.abs(initialScrollY - targetY);
                        const initialDiffX = Math.abs(initialScrollX - targetX);
                        
                        detailedLogs.push('목표 Y 도달 가능: ' + (isTargetReachableY ? '예' : '아니오') + (isTargetReachableY ? '' : ' (' + (targetY - maxScrollY).toFixed(1) + 'px 초과)'));
                        detailedLogs.push('목표 X 도달 가능: ' + (isTargetReachableX ? '예' : '아니오'));
                        detailedLogs.push('초기 거리: X=' + initialDiffX.toFixed(1) + 'px, Y=' + initialDiffY.toFixed(1) + 'px');
                        
                        // 🚫 **브라우저 차단 대응: 점진적 스크롤 - 상세 디버깅**
                        let attempts = 0;
                        const maxAttempts = 15;
                        let lastScrollY = initialScrollY;
                        let lastScrollX = initialScrollX;
                        let stuckCounter = 0; // 스크롤이 멈춘 횟수
                        
                        // 🚫 **동기적 점진적 스크롤 처리**
                        let finalResult = null;
                        
                        for (let attempt = 0; attempt < maxAttempts; attempt++) {
                            attempts = attempt + 1;
                            
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
                                current: { x: currentX, y: currentY },
                                target: { x: targetX, y: targetY },
                                diff: { x: diffX, y: diffY },
                                progress: { x: progressX, y: progressY },
                                withinTolerance: diffX <= tolerance && diffY <= tolerance
                            };
                            
                            scrollAttempts.push(attemptData);
                            
                            detailedLogs.push('시도 ' + attempts + ': 현재 Y=' + currentY.toFixed(1) + 'px, 차이=' + diffY.toFixed(1) + 'px, 진행=' + progressY.toFixed(1) + 'px');
                            
                            // 📊 **스크롤 정체 감지**
                            if (progressY < 1.0 && progressX < 1.0) {
                                stuckCounter++;
                                detailedLogs.push('스크롤 정체 감지: ' + stuckCounter + '회 연속');
                            } else {
                                stuckCounter = 0;
                            }
                            
                            // 목표 도달 확인
                            if (diffX <= tolerance && diffY <= tolerance) {
                                finalResult = {
                                    result: 'progressive_success',
                                    data: {
                                        success: true,
                                        attempts: attempts,
                                        finalPosition: { x: currentX, y: currentY },
                                        finalDiff: { x: diffX, y: diffY }
                                    }
                                };
                                
                                detailedLogs.push('✅ 점진적 스크롤 성공: ' + attempts + '회 시도, 최종 차이 Y=' + diffY.toFixed(1) + 'px');
                                console.log('🚫 점진적 스크롤 성공:', finalResult.data);
                                break;
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
                            
                            detailedLogs.push('스크롤 한계: Y=' + currentMaxScrollY.toFixed(1) + 'px (' + (currentY >= currentMaxScrollY - 5 ? '도달' : '미도달') + ')');
                            
                            // 📊 **무한 스크롤 감지 및 트리거**
                            if (currentY >= currentMaxScrollY - 100 && targetY > currentMaxScrollY) {
                                detailedLogs.push('무한 스크롤 구간 감지 - 트리거 시도');
                                
                                // 스크롤 이벤트 강제 발생
                                window.dispatchEvent(new Event('scroll', { bubbles: true }));
                                window.dispatchEvent(new Event('resize', { bubbles: true }));
                                
                                // 터치 이벤트 시뮬레이션 (모바일 무한 스크롤용) - 🚫 안전 처리
                                try {
                                    if (typeof TouchEvent !== 'undefined') {
                                        const touchEvent = new TouchEvent('touchend', { bubbles: true });
                                        document.dispatchEvent(touchEvent);
                                        attemptData.infiniteScrollTrigger = 'touchEvent_attempted';
                                        detailedLogs.push('터치 이벤트 트리거 성공');
                                    } else {
                                        attemptData.infiniteScrollTrigger = 'touchEvent_unsupported';
                                        detailedLogs.push('터치 이벤트 미지원');
                                    }
                                } catch(e) {
                                    attemptData.infiniteScrollTrigger = 'touchEvent_failed';
                                    detailedLogs.push('터치 이벤트 트리거 실패');
                                }
                                
                                // 📊 **더보기 버튼 검색 및 클릭**
                                const loadMoreButtons = document.querySelectorAll(
                                    '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                                    '[data-role="load"], .load-more, .show-more, .infinite-scroll-trigger'
                                );
                                
                                let clickedButtons = 0;
                                for (let i = 0; i < loadMoreButtons.length; i++) {
                                    const btn = loadMoreButtons[i];
                                    if (btn && typeof btn.click === 'function') {
                                        try {
                                            btn.click();
                                            clickedButtons++;
                                            detailedLogs.push('더보기 버튼[' + i + '] 클릭: ' + (btn.className || btn.tagName));
                                        } catch(e) {
                                            detailedLogs.push('더보기 버튼[' + i + '] 클릭 실패: ' + e.message);
                                        }
                                    }
                                }
                                
                                attemptData.loadMoreButtons = {
                                    found: loadMoreButtons.length,
                                    clicked: clickedButtons
                                };
                                
                                detailedLogs.push('더보기 버튼: ' + loadMoreButtons.length + '개 발견, ' + clickedButtons + '개 클릭');
                                
                                // 📊 **페이지 하단 강제 스크롤**
                                if (clickedButtons > 0) {
                                    detailedLogs.push('더보기 버튼 클릭 후 하단 강제 스크롤');
                                    const newMaxY = Math.max(
                                        document.documentElement.scrollHeight - window.innerHeight,
                                        document.body.scrollHeight - window.innerHeight,
                                        0
                                    );
                                    window.scrollTo(0, newMaxY);
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
                                detailedLogs.push('스크롤 실행 오류: ' + scrollError.message);
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
                                    
                                    // 3. 원복 - 🚫 동기적 처리
                                    bodyStyle.overflow = originalOverflow;
                                    
                                    stuckCounter = 0; // 정체 카운터 리셋
                                    detailedLogs.push('스크롤 정체 강제 해제 완료');
                                } catch(e) {
                                    detailedLogs.push('스크롤 정체 해제 실패: ' + e.message);
                                }
                            }
                            
                            // 다음 시도를 위한 위치 업데이트
                            lastScrollY = currentY;
                            lastScrollX = currentX;
                        }
                        
                        // 최대 시도 도달 시 결과 설정
                        if (!finalResult) {
                            const finalCurrentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const finalCurrentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            const finalDiffY = Math.abs(finalCurrentY - targetY);
                            const finalDiffX = Math.abs(finalCurrentX - targetX);
                            
                            finalResult = {
                                result: 'progressive_maxAttempts',
                                data: {
                                    success: false,
                                    attempts: maxAttempts,
                                    finalPosition: { x: finalCurrentX, y: finalCurrentY },
                                    finalDiff: { x: finalDiffX, y: finalDiffY },
                                    stuckCounter: stuckCounter,
                                    reason: 'max_attempts_reached'
                                }
                            };
                            
                            detailedLogs.push('점진적 스크롤 최대 시도 도달: ' + maxAttempts + '회');
                            detailedLogs.push('최종 위치: Y=' + finalCurrentY.toFixed(1) + 'px, 목표=' + targetY.toFixed(1) + 'px, 차이=' + finalDiffY.toFixed(1) + 'px');
                            console.log('🚫 점진적 스크롤 최대 시도 도달:', finalResult.data);
                        }
                        
                        // 🚫 **Swift 호환 최종 반환값**
                        return {
                            result: finalResult.result,
                            data: finalResult.data,
                            detailedLogs: detailedLogs,
                            performanceData: performanceData,
                            scrollAttempts: scrollAttempts
                        };
                        
                    } catch(e) { 
                        console.error('🚫 점진적 스크롤 전체 실패:', e);
                        return {
                            result: 'progressive_error',
                            error: e.message,
                            detailedLogs: ['점진적 스크롤 전체 실패: ' + e.message]
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
                        
                        // 📊 **스크롤 시도 데이터 추출** - 수정: 불필요한 캐스팅 제거
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
        
        // ✅ **iframe 복원 단계 제거됨**
        
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
                        detailedLogs.push('목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                        
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
                        
                        detailedLogs.push('현재 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                        detailedLogs.push('목표와 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                        detailedLogs.push('허용 오차: ' + tolerance + 'px');
                        detailedLogs.push('허용 오차 내: ' + (isWithinTolerance ? '예' : '아니오'));
                        detailedLogs.push('페이지 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                        detailedLogs.push('최대 스크롤: X=' + maxScrollX.toFixed(1) + 'px, Y=' + maxScrollY.toFixed(1) + 'px');
                        
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
                        
                        detailedLogs.push('목표 Y 도달 가능: ' + (canScrollToTargetY ? '예' : '아니오'));
                        detailedLogs.push('목표 X 도달 가능: ' + (canScrollToTargetX ? '예' : '아니오'));
                        if (!canScrollToTargetY) {
                            detailedLogs.push('Y축 초과량: ' + (targetY - maxScrollY).toFixed(1) + 'px');
                        }
                        if (isTargetBeyondContent) {
                            detailedLogs.push('목표가 콘텐츠 영역 벗어남: ' + (targetY - contentHeight).toFixed(1) + 'px');
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
                            
                            detailedLogs.push('보정 전: X=' + beforeCorrectionX.toFixed(1) + 'px, Y=' + beforeCorrectionY.toFixed(1) + 'px');
                            
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
                            
                            detailedLogs.push('보정 후: X=' + afterCorrectionX.toFixed(1) + 'px, Y=' + afterCorrectionY.toFixed(1) + 'px');
                            detailedLogs.push('보정 이동량: X=' + correctionDiffX.toFixed(1) + 'px, Y=' + correctionDiffY.toFixed(1) + 'px');
                            detailedLogs.push('보정 효과: ' + (verificationData.correction.effective ? '유효' : '무효과'));
                        } else {
                            detailedLogs.push('허용 오차 내 - 보정 불필요');
                        }
                        
                        // ✅ **최종 위치 정확 측정 및 기록** - 🚫 동기적 처리
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
                        detailedLogs.push('최종 위치: X=' + finalCurrentX.toFixed(1) + 'px, Y=' + finalCurrentY.toFixed(1) + 'px');
                        detailedLogs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                        detailedLogs.push('최종 차이: X=' + finalDiffX.toFixed(1) + 'px, Y=' + finalDiffY.toFixed(1) + 'px');
                        detailedLogs.push('허용 오차 내: ' + (finalWithinTolerance ? '예' : '아니오') + ' (' + tolerance + 'px 기준)');
                        detailedLogs.push('실제 복원 성공: ' + (actualRestoreSuccess ? '예' : '아니오') + ' (50px 기준)');
                        detailedLogs.push('실용적 성공: ' + (practicalSuccess ? '예' : '아니오') + ' (100px 기준)');
                        
                        console.log('✅ 브라우저 차단 대응 최종보정 완료:', verificationData);
                        
                        // 🚫 **Swift 호환 반환값**
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
                            detailedLogs: ['브라우저 차단 대응 최종보정 실패: ' + e.message]
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
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🚀 4요소 패키지 캡처 + 의미없는 텍스트 필터링)**
    
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
        TabPersistenceManager.debugMessages.append("👁️ 보이는 요소만 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
        
        TabPersistenceManager.debugMessages.append("👁️ 보이는 요소만 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
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
            
            if let packageAnchors = jsState["fourElementPackageAnchors"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🎯 캡처된 4요소 패키지 데이터 키: \(Array(packageAnchors.keys))")
                
                if let anchors = packageAnchors["anchors"] as? [[String: Any]] {
                    // 🧹 **완전 패키지 필터링 후 로깅**
                    let completePackageAnchors = anchors.filter { anchor in
                        if let pkg = anchor["fourElementPackage"] as? [String: Any] {
                            let hasId = pkg["id"] != nil
                            let hasType = pkg["type"] != nil
                            let hasTs = pkg["ts"] != nil
                            let hasKw = pkg["kw"] != nil
                            return hasId && hasType && hasTs && hasKw
                        }
                        return false
                    }
                    
                    TabPersistenceManager.debugMessages.append("👁️ 보이는 요소 캡처 앵커: \(anchors.count)개 (완전 패키지: \(completePackageAnchors.count)개)")
                    
                    if completePackageAnchors.count > 0 {
                        let firstPackageAnchor = completePackageAnchors[0]
                        TabPersistenceManager.debugMessages.append("👁️ 첫 번째 보이는 완전 패키지 앵커 키: \(Array(firstPackageAnchor.keys))")
                        
                        // 📊 **첫 번째 완전 패키지 앵커 상세 정보 로깅**
                        if let pkg = firstPackageAnchor["fourElementPackage"] as? [String: Any] {
                            let id = pkg["id"] as? String ?? "unknown"
                            let type = pkg["type"] as? String ?? "unknown"
                            let ts = pkg["ts"] as? String ?? "unknown"
                            let kw = pkg["kw"] as? String ?? "unknown"
                            TabPersistenceManager.debugMessages.append("📊 첫 보이는 완전패키지 4요소: id=\(id), type=\(type), ts=\(ts), kw=\(kw)")
                        }
                        if let absolutePos = firstPackageAnchor["absolutePosition"] as? [String: Any] {
                            let top = (absolutePos["top"] as? Double) ?? 0
                            let left = (absolutePos["left"] as? Double) ?? 0
                            TabPersistenceManager.debugMessages.append("📊 첫 보이는 완전패키지 위치: X=\(String(format: "%.1f", left))px, Y=\(String(format: "%.1f", top))px")
                        }
                        if let offsetFromTop = firstPackageAnchor["offsetFromTop"] as? Double {
                            TabPersistenceManager.debugMessages.append("📊 첫 보이는 완전패키지 오프셋: \(String(format: "%.1f", offsetFromTop))px")
                        }
                        if let textContent = firstPackageAnchor["textContent"] as? String {
                            let preview = textContent.prefix(50)
                            TabPersistenceManager.debugMessages.append("📊 첫 보이는 완전패키지 텍스트: \"\(preview)\"")
                        }
                        if let qualityScore = firstPackageAnchor["qualityScore"] as? Int {
                            TabPersistenceManager.debugMessages.append("📊 첫 보이는 완전패키지 품질점수: \(qualityScore)점")
                        }
                        if let isVisible = firstPackageAnchor["isVisible"] as? Bool {
                            TabPersistenceManager.debugMessages.append("📊 첫 보이는 완전패키지 가시성: \(isVisible)")
                        }
                        if let visibilityReason = firstPackageAnchor["visibilityReason"] as? String {
                            TabPersistenceManager.debugMessages.append("📊 첫 보이는 완전패키지 가시성 근거: \(visibilityReason)")
                        }
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🎯 4요소 패키지 앵커 데이터 캡처 실패")
                }
                
                if let stats = packageAnchors["stats"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 보이는 요소 수집 통계: \(stats)")
                }
            } else {
                TabPersistenceManager.debugMessages.append("🎯 4요소 패키지 데이터 캡처 실패")
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
        
        TabPersistenceManager.debugMessages.append("✅ 보이는 요소만 직렬 캡처 완료: \(task.pageRecord.title)")
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
                    
                    // 🚫 **눌린 상태/활성 상태 모두 제거**
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(function(el) {
                        var classList = Array.from(el.classList);
                        var classesToRemove = classList.filter(function(c) {
                            return c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus');
                        });
                        for (var i = 0; i < classesToRemove.length; i++) {
                            el.classList.remove(classesToRemove[i]);
                        }
                    });
                    
                    // input focus 제거
                    document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(function(el) {
                        el.blur();
                    });
                    
                    var html = document.documentElement.outerHTML;
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
        
        // 3. ✅ **수정: 보이는 요소만 캡처하는 4요소 패키지 JS 상태 캡처** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("👁️ 보이는 요소만 4요소 패키지 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateVisibleOnlyFourElementPackageCaptureScript() // 👁️ **새로운: 보이는 요소만 캡처**
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                    
                    // 📊 **상세 캡처 결과 로깅**
                    if let packageAnchors = data["fourElementPackageAnchors"] as? [String: Any] {
                        if let anchors = packageAnchors["anchors"] as? [[String: Any]] {
                            let completePackageAnchors = anchors.filter { anchor in
                                if let pkg = anchor["fourElementPackage"] as? [String: Any] {
                                    let hasId = pkg["id"] != nil
                                    let hasType = pkg["type"] != nil
                                    let hasTs = pkg["ts"] != nil
                                    let hasKw = pkg["kw"] != nil
                                    return hasId && hasType && hasTs && hasKw
                                }
                                return false
                            }
                            let visibleAnchors = anchors.filter { anchor in
                                (anchor["isVisible"] as? Bool) ?? false
                            }
                            TabPersistenceManager.debugMessages.append("👁️ JS 캡처된 앵커: \(anchors.count)개 (완전 패키지: \(completePackageAnchors.count)개, 보이는 것: \(visibleAnchors.count)개)")
                        }
                        if let stats = packageAnchors["stats"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("📊 보이는 요소 JS 캡처 통계: \(stats)")
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
    
    // 👁️ **새로운: 보이는 요소만 캡처하는 4요소 패키지 JavaScript 생성**
    private func generateVisibleOnlyFourElementPackageCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('👁️ 보이는 요소만 4요소 패키지 캡처 시작');
                
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
                
                detailedLogs.push('👁️ 보이는 요소만 4요소 패키지 캡처 시작');
                detailedLogs.push('스크롤 위치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포트 크기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                console.log('👁️ 기본 정보:', {
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                // 👁️ **핵심: 실제 보이는 영역 계산 (정확한 뷰포트)**
                const actualViewportRect = {
                    top: scrollY,
                    left: scrollX,
                    bottom: scrollY + viewportHeight,
                    right: scrollX + viewportWidth,
                    width: viewportWidth,
                    height: viewportHeight
                };
                
                detailedLogs.push('실제 보이는 영역: top=' + actualViewportRect.top.toFixed(1) + ', bottom=' + actualViewportRect.bottom.toFixed(1));
                detailedLogs.push('영역 크기: ' + actualViewportRect.width.toFixed(0) + ' x ' + actualViewportRect.height.toFixed(0));
                
                // 👁️ **요소 가시성 정확 판단 함수**
                function isElementActuallyVisible(element, strictMode) {
                    if (strictMode === undefined) strictMode = true;
                    
                    try {
                        // 1. 기본 DOM 연결 확인
                        if (!element || !element.getBoundingClientRect) return { visible: false, reason: 'invalid_element' };
                        
                        // 2. DOM 트리 연결 확인
                        if (!document.contains(element)) return { visible: false, reason: 'not_in_dom' };
                        
                        // 3. 요소 크기 확인
                        const rect = element.getBoundingClientRect();
                        if (rect.width === 0 || rect.height === 0) return { visible: false, reason: 'zero_size' };
                        
                        // 4. 뷰포트와 겹침 확인 (정확한 계산)
                        const elementTop = scrollY + rect.top;
                        const elementBottom = scrollY + rect.bottom;
                        const elementLeft = scrollX + rect.left;
                        const elementRight = scrollX + rect.right;
                        
                        // 👁️ **엄격한 뷰포트 겹침 판단**
                        const isInViewportVertically = elementBottom > actualViewportRect.top && elementTop < actualViewportRect.bottom;
                        const isInViewportHorizontally = elementRight > actualViewportRect.left && elementLeft < actualViewportRect.right;
                        
                        if (strictMode && (!isInViewportVertically || !isInViewportHorizontally)) {
                            return { visible: false, reason: 'outside_viewport', rect: rect };
                        }
                        
                        // 5. CSS visibility, display 확인
                        const computedStyle = window.getComputedStyle(element);
                        if (computedStyle.display === 'none') return { visible: false, reason: 'display_none' };
                        if (computedStyle.visibility === 'hidden') return { visible: false, reason: 'visibility_hidden' };
                        if (computedStyle.opacity === '0') return { visible: false, reason: 'opacity_zero' };
                        
                        // 6. 부모 요소의 overflow hidden 확인
                        let parent = element.parentElement;
                        while (parent && parent !== document.body) {
                            const parentStyle = window.getComputedStyle(parent);
                            const parentRect = parent.getBoundingClientRect();
                            
                            if (parentStyle.overflow === 'hidden' || parentStyle.overflowY === 'hidden') {
                                const parentTop = scrollY + parentRect.top;
                                const parentBottom = scrollY + parentRect.bottom;
                                
                                // 요소가 부모의 overflow 영역을 벗어났는지 확인
                                if (elementTop >= parentBottom || elementBottom <= parentTop) {
                                    return { visible: false, reason: 'parent_overflow_hidden' };
                                }
                            }
                            parent = parent.parentElement;
                        }
                        
                        // 👁️ **특별 케이스: 숨겨진 콘텐츠 영역 확인**
                        // 탭이나 아코디언 등의 숨겨진 콘텐츠
                        const hiddenContentSelectors = [
                            '[style*="display: none"]',
                            '[style*="visibility: hidden"]',
                            '.hidden', '.collapse', '.collapsed',
                            '[aria-hidden="true"]',
                            '.tab-content:not(.active)',
                            '.panel:not(.active)',
                            '.accordion-content:not(.open)'
                        ];
                        
                        for (let i = 0; i < hiddenContentSelectors.length; i++) {
                            const selector = hiddenContentSelectors[i];
                            try {
                                if (element.matches(selector) || element.closest(selector)) {
                                    return { visible: false, reason: 'hidden_content_area' };
                                }
                            } catch(e) {
                                // selector 오류는 무시
                            }
                        }
                        
                        return { 
                            visible: true, 
                            reason: 'fully_visible',
                            rect: rect,
                            inViewport: { vertical: isInViewportVertically, horizontal: isInViewportHorizontally }
                        };
                        
                    } catch(e) {
                        return { visible: false, reason: 'visibility_check_error: ' + e.message };
                    }
                }
                
                // 🧹 **의미없는 텍스트 필터링 함수**
                function isQualityText(text) {
                    if (!text || typeof text !== 'string') return false;
                    
                    const cleanText = text.trim();
                    if (cleanText.length < 5) return false; // 너무 짧은 텍스트
                    
                    // 🧹 **의미없는 텍스트 패턴들** - 수정된 이스케이프 시퀀스
                    const meaninglessPatterns = [
                        /^(투표는|표시되지|않습니다|네트워크|문제로|연결되지|잠시|후에|다시|시도)/,
                        /^(로딩|loading|wait|please|기다려|잠시만)/i,
                        /^(오류|에러|error|fail|실패|죄송|sorry)/i,
                        /^(확인|ok|yes|no|취소|cancel|닫기|close)/i,
                        /^(더보기|more|load|next|이전|prev|previous)/i,
                        /^(클릭|click|tap|터치|touch|선택)/i,
                        /^(답글|댓글|reply|comment|쓰기|작성)/i,
                        /^[\\s\\.\\-_=+]{2,}$/, // 특수문자만 - 수정된 이스케이프
                        /^[0-9\\s\\.\\/\\-:]{3,}$/, // 숫자와 특수문자만 - 수정된 이스케이프
                        /^(am|pm|오전|오후|시|분|초)$/i,
                    ];
                    
                    for (let i = 0; i < meaninglessPatterns.length; i++) {
                        const pattern = meaninglessPatterns[i];
                        if (pattern.test(cleanText)) {
                            return false;
                        }
                    }
                    
                    // 너무 반복적인 문자 (같은 문자 70% 이상)
                    const charCounts = {};
                    for (let i = 0; i < cleanText.length; i++) {
                        const char = cleanText[i];
                        charCounts[char] = (charCounts[char] || 0) + 1;
                    }
                    const counts = Object.values(charCounts);
                    const maxCharCount = Math.max.apply(Math, counts);
                    if (maxCharCount / cleanText.length > 0.7) {
                        return false;
                    }
                    
                    return true;
                }
                
                detailedLogs.push('🧹 의미없는 텍스트 필터링 함수 로드 완료');
                
                // 👁️ **핵심 개선: 보이는 요소만 4요소 패키지 앵커 수집**
                function collectVisibleFourElementPackageAnchors() {
                    const anchors = [];
                    const visibilityStats = {
                        totalCandidates: 0,
                        visibilityChecked: 0,
                        actuallyVisible: 0,
                        qualityFiltered: 0,
                        finalAnchors: 0
                    };
                    
                    detailedLogs.push('👁️ 보이는 뷰포트 영역: ' + actualViewportRect.top.toFixed(1) + ' ~ ' + actualViewportRect.bottom.toFixed(1) + 'px');
                    console.log('👁️ 실제 뷰포트 영역:', actualViewportRect);
                    
                    // 👁️ **범용 콘텐츠 요소 패턴 (보이는 것만 선별)**
                    const contentSelectors = [
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
                    
                    detailedLogs.push('총 ' + contentSelectors.length + '개 selector 패턴으로 후보 요소 수집 시작');
                    
                    // 모든 selector에서 요소 수집
                    for (let i = 0; i < contentSelectors.length; i++) {
                        const selector = contentSelectors[i];
                        try {
                            const elements = document.querySelectorAll(selector);
                            if (elements.length > 0) {
                                selectorStats[selector] = elements.length;
                                for (let j = 0; j < elements.length; j++) {
                                    candidateElements.push(elements[j]);
                                }
                            }
                        } catch(e) {
                            selectorStats[selector] = 'error: ' + e.message;
                        }
                    }
                    
                    visibilityStats.totalCandidates = candidateElements.length;
                    captureStats.selectorStats = selectorStats;
                    
                    detailedLogs.push('후보 요소 수집 완료: ' + candidateElements.length + '개');
                    detailedLogs.push('주요 selector 결과: li=' + (selectorStats['li'] || 0) + ', div=' + (selectorStats['div[class*="item"]'] || 0) + ', [data-id]=' + (selectorStats['[data-id]'] || 0));
                    
                    console.log('👁️ 후보 요소 수집:', {
                        totalElements: candidateElements.length,
                        topSelectors: Object.entries(selectorStats)
                            .filter(function(entry) {
                                return typeof entry[1] === 'number' && entry[1] > 0;
                            })
                            .sort(function(a, b) {
                                return b[1] - a[1];
                            })
                            .slice(0, 5)
                    });
                    
                    // 👁️ **핵심 개선: 실제로 보이는 요소만 필터링 (엄격 모드)**
                    let visibleElements = [];
                    let processingErrors = 0;
                    
                    for (let i = 0; i < candidateElements.length; i++) {
                        const element = candidateElements[i];
                        try {
                            const visibilityResult = isElementActuallyVisible(element, true); // 엄격 모드
                            visibilityStats.visibilityChecked++;
                            
                            if (visibilityResult.visible) {
                                // 👁️ **품질 텍스트 추가 검증**
                                const elementText = (element.textContent || '').trim();
                                if (isQualityText(elementText)) {
                                    visibleElements.push({
                                        element: element,
                                        rect: visibilityResult.rect,
                                        absoluteTop: scrollY + visibilityResult.rect.top,
                                        absoluteLeft: scrollX + visibilityResult.rect.left,
                                        visibilityResult: visibilityResult,
                                        textContent: elementText
                                    });
                                    visibilityStats.actuallyVisible++;
                                    visibilityStats.qualityFiltered++;
                                } else {
                                    // 보이지만 품질 텍스트가 아님
                                    visibilityStats.actuallyVisible++;
                                }
                            }
                        } catch(e) {
                            processingErrors++;
                        }
                    }
                    
                    captureStats.visibilityStats = visibilityStats;
                    captureStats.processingErrors = processingErrors;
                    
                    detailedLogs.push('가시성 검사 완료: ' + visibilityStats.visibilityChecked + '개 검사, ' + visibilityStats.actuallyVisible + '개 실제 보임');
                    detailedLogs.push('품질 필터링 후 최종: ' + visibleElements.length + '개 (오류: ' + processingErrors + '개)');
                    
                    console.log('👁️ 보이는 품질 요소 필터링 완료:', {
                        totalCandidates: visibilityStats.totalCandidates,
                        visibilityChecked: visibilityStats.visibilityChecked,
                        actuallyVisible: visibilityStats.actuallyVisible,
                        qualityFiltered: visibilityStats.qualityFiltered,
                        processingErrors: processingErrors
                    });
                    
                    // 👁️ **뷰포트 중심에서 가까운 순으로 정렬하여 상위 20개 선택 (범위 축소)**
                    const viewportCenterY = scrollY + (viewportHeight / 2);
                    const viewportCenterX = scrollX + (viewportWidth / 2);
                    
                    visibleElements.sort(function(a, b) {
                        const aCenterY = a.absoluteTop + (a.rect.height / 2);
                        const aCenterX = a.absoluteLeft + (a.rect.width / 2);
                        const bCenterY = b.absoluteTop + (b.rect.height / 2);
                        const bCenterX = b.absoluteLeft + (b.rect.width / 2);
                        
                        const aDistance = Math.sqrt(Math.pow(aCenterX - viewportCenterX, 2) + Math.pow(aCenterY - viewportCenterY, 2));
                        const bDistance = Math.sqrt(Math.pow(bCenterX - viewportCenterX, 2) + Math.pow(bCenterY - viewportCenterY, 2));
                        
                        return aDistance - bDistance;
                    });
                    
                    const selectedElements = visibleElements.slice(0, 20); // 👁️ 20개로 제한 (기존 30개에서 축소)
                    visibilityStats.finalAnchors = selectedElements.length;
                    
                    detailedLogs.push('뷰포트 중심 기준 정렬 후 상위 ' + selectedElements.length + '개 선택');
                    detailedLogs.push('뷰포트 중심: X=' + viewportCenterX.toFixed(1) + 'px, Y=' + viewportCenterY.toFixed(1) + 'px');
                    
                    console.log('👁️ 뷰포트 중심 기준 선택 완료:', {
                        viewportCenter: [viewportCenterX, viewportCenterY],
                        selectedCount: selectedElements.length
                    });
                    
                    // 각 선택된 요소에 대해 4요소 패키지 정보 수집
                    let anchorCreationErrors = 0;
                    for (let i = 0; i < selectedElements.length; i++) {
                        try {
                            const anchor = createFourElementPackageAnchor(selectedElements[i], i, true); // 👁️ 가시성 정보 포함
                            if (anchor) {
                                anchors.push(anchor);
                            }
                        } catch(e) {
                            anchorCreationErrors++;
                            console.warn('👁️ 보이는 앵커[' + i + '] 생성 실패:', e);
                        }
                    }
                    
                    captureStats.anchorCreationErrors = anchorCreationErrors;
                    captureStats.finalAnchors = anchors.length;
                    visibilityStats.finalAnchors = anchors.length;
                    
                    detailedLogs.push('보이는 4요소 패키지 앵커 생성 완료: ' + anchors.length + '개 (실패: ' + anchorCreationErrors + '개)');
                    console.log('👁️ 보이는 4요소 패키지 앵커 수집 완료:', anchors.length, '개');
                    
                    return {
                        anchors: anchors,
                        stats: captureStats
                    };
                }
                
                // 👁️ **개별 보이는 4요소 패키지 앵커 생성 (가시성 정보 포함)**
                function createFourElementPackageAnchor(elementData, index, includeVisibility) {
                    if (includeVisibility === undefined) includeVisibility = true;
                    
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const absoluteTop = elementData.absoluteTop;
                        const absoluteLeft = elementData.absoluteLeft;
                        const textContent = elementData.textContent;
                        const visibilityResult = elementData.visibilityResult;
                        
                        // 뷰포트 기준 오프셋 계산
                        const offsetFromTop = scrollY - absoluteTop;
                        const offsetFromLeft = scrollX - absoluteLeft;
                        
                        detailedLogs.push('👁️ 보이는 앵커[' + index + '] 생성: 위치 Y=' + absoluteTop.toFixed(1) + 'px, 오프셋=' + offsetFromTop.toFixed(1) + 'px');
                        
                        // 🧹 **품질 텍스트 재확인**
                        if (!isQualityText(textContent)) {
                            detailedLogs.push('   👁️ 앵커[' + index + '] 품질 텍스트 검증 실패: "' + textContent.substring(0, 30) + '"');
                            return null;
                        }
                        
                        // 🎯 **4요소 패키지 생성: {id, type, ts, kw}**
                        const fourElementPackage = {};
                        let packageScore = 0; // 패키지 완성도 점수
                        
                        // ① **고유 식별자 (id) - 최우선**
                        let uniqueId = null;
                        
                        // ID 속성
                        if (element.id) {
                            uniqueId = element.id;
                            packageScore += 20;
                            detailedLogs.push('   👁️ 4요소[id]: ID 속성="' + element.id + '"');
                        }
                        
                        // data-* 속성들 (고유 식별자용)
                        if (!uniqueId) {
                            const dataAttrs = ['data-id', 'data-post-id', 'data-article-id', 
                                             'data-comment-id', 'data-item-id', 'data-key', 
                                             'data-user-id', 'data-thread-id'];
                            for (let i = 0; i < dataAttrs.length; i++) {
                                const attr = dataAttrs[i];
                                const value = element.getAttribute(attr);
                                if (value) {
                                    uniqueId = value;
                                    packageScore += 18;
                                    detailedLogs.push('   👁️ 4요소[id]: ' + attr + '="' + value + '"');
                                    break;
                                }
                            }
                        }
                        
                        // href에서 ID 추출
                        if (!uniqueId) {
                            const linkElement = element.querySelector('a[href]') || (element.tagName === 'A' ? element : null);
                            if (linkElement && linkElement.href) {
                                try {
                                    const url = new URL(linkElement.href);
                                    const urlParams = url.searchParams;
                                    const paramEntries = Array.from(urlParams.entries());
                                    for (let i = 0; i < paramEntries.length; i++) {
                                        const key = paramEntries[i][0];
                                        const value = paramEntries[i][1];
                                        if (key.includes('id') || key.includes('post') || key.includes('article')) {
                                            uniqueId = value;
                                            packageScore += 15;
                                            detailedLogs.push('   👁️ 4요소[id]: URL 파라미터="' + key + '=' + value + '"');
                                            break;
                                        }
                                    }
                                    // 직접 ID 패턴 추출
                                    if (!uniqueId && linkElement.href.includes('id=')) {
                                        const match = linkElement.href.match(/id=([^&]+)/);
                                        if (match) {
                                            uniqueId = match[1];
                                            packageScore += 12;
                                            detailedLogs.push('   👁️ 4요소[id]: URL 패턴 id="' + match[1] + '"');
                                        }
                                    }
                                } catch(e) {
                                    // URL 파싱 실패는 무시
                                }
                            }
                        }
                        
                        // UUID 생성 (최후 수단)
                        if (!uniqueId) {
                            uniqueId = 'auto_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
                            packageScore += 5;
                            detailedLogs.push('   👁️ 4요소[id]: 자동 생성 UUID="' + uniqueId + '"');
                        }
                        
                        fourElementPackage.id = uniqueId;
                        
                        // ② **콘텐츠 타입 (type)**
                        let contentType = 'unknown';
                        const tagName = element.tagName.toLowerCase();
                        const className = (element.className || '').toLowerCase();
                        const parentClassName = (element.parentElement && element.parentElement.className || '').toLowerCase();
                        
                        // 클래스명/태그명 기반 타입 추론
                        if (className.includes('comment') || className.includes('reply')) {
                            contentType = 'comment';
                            packageScore += 15;
                        } else if (className.includes('post') || className.includes('article')) {
                            contentType = 'post';
                            packageScore += 15;
                        } else if (className.includes('review') || className.includes('rating')) {
                            contentType = 'review'; 
                            packageScore += 15;
                        } else if (tagName === 'article') {
                            contentType = 'article';
                            packageScore += 12;
                        } else if (tagName === 'li' && (parentClassName.includes('list') || parentClassName.includes('feed'))) {
                            contentType = 'item';
                            packageScore += 10;
                        } else if (className.includes('card') || className.includes('item')) {
                            contentType = 'item';
                            packageScore += 8;
                        } else {
                            contentType = tagName; // 태그명을 타입으로
                            packageScore += 3;
                        }
                        
                        fourElementPackage.type = contentType;
                        detailedLogs.push('   👁️ 4요소[type]: "' + contentType + '"');
                        
                        // ③ **타임스탬프 (ts)**
                        let timestamp = null;
                        
                        // 시간 정보 추출 시도
                        const timeElement = element.querySelector('time') || 
                                          element.querySelector('[datetime]') ||
                                          element.querySelector('.time, .date, .timestamp');
                        
                        if (timeElement) {
                            const datetime = timeElement.getAttribute('datetime') || timeElement.textContent;
                            if (datetime) {
                                timestamp = datetime.trim();
                                packageScore += 15;
                                detailedLogs.push('   👁️ 4요소[ts]: 시간 요소="' + timestamp + '"');
                            }
                        }
                        
                        // 텍스트에서 시간 패턴 추출
                        if (!timestamp) {
                            const timePatterns = [
                                /\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}/, // ISO8601
                                /\\d{4}년\\s*\\d{1,2}월\\s*\\d{1,2}일/, // 한국어 날짜
                                /\\d{1,2}:\\d{2}/, // 시:분
                                /\\d{4}-\\d{2}-\\d{2}/, // YYYY-MM-DD
                                /\\d{1,2}시간?\\s*전/, // N시간 전
                                /\\d{1,2}일\\s*전/ // N일 전
                            ];
                            
                            for (let i = 0; i < timePatterns.length; i++) {
                                const pattern = timePatterns[i];
                                const match = textContent.match(pattern);
                                if (match) {
                                    timestamp = match[0];
                                    packageScore += 10;
                                    detailedLogs.push('   👁️ 4요소[ts]: 텍스트 패턴="' + timestamp + '"');
                                    break;
                                }
                            }
                        }
                        
                        // 현재 시간으로 대체 (최후 수단)
                        if (!timestamp) {
                            timestamp = new Date().toISOString();
                            packageScore += 2;
                            detailedLogs.push('   👁️ 4요소[ts]: 현재 시간="' + timestamp + '"');
                        }
                        
                        fourElementPackage.ts = timestamp;
                        
                        // ④ **컨텍스트 키워드 (kw)**
                        let keywords = '';
                        
                        // 텍스트에서 키워드 추출 (첫 10자 + 마지막 10자)
                        if (textContent.length > 20) {
                            keywords = textContent.substring(0, 10) + '...' + textContent.substring(textContent.length - 10);
                            packageScore += 12;
                        } else if (textContent.length > 0) {
                            keywords = textContent.substring(0, 20);
                            packageScore += 8;
                        }
                        
                        // 대체 키워드 (제목, alt 등)
                        if (!keywords) {
                            const titleAttr = element.getAttribute('title') || 
                                            element.getAttribute('alt') ||
                                            element.getAttribute('aria-label');
                            if (titleAttr) {
                                keywords = titleAttr.substring(0, 20);
                                packageScore += 5;
                                detailedLogs.push('   👁️ 4요소[kw]: 속성 키워드="' + keywords + '"');
                            }
                        }
                        
                        // 클래스명을 키워드로 (최후 수단)
                        if (!keywords && className) {
                            keywords = className.split(' ')[0].substring(0, 15);
                            packageScore += 2;
                            detailedLogs.push('   👁️ 4요소[kw]: 클래스명 키워드="' + keywords + '"');
                        }
                        
                        fourElementPackage.kw = keywords || 'unknown';
                        detailedLogs.push('   👁️ 4요소[kw]: "' + fourElementPackage.kw + '"');
                        
                        // 📊 **품질 점수 계산 (보이는 요소는 50점 이상 필요)**
                        let qualityScore = packageScore;
                        
                        // 👁️ **가시성 보너스 (중요!)**
                        if (includeVisibility && visibilityResult) {
                            qualityScore += 15; // 실제로 보이는 요소 보너스
                            if (visibilityResult.reason === 'fully_visible') qualityScore += 5; // 완전히 보이는 경우
                        }
                        
                        // 🧹 **품질 텍스트 보너스**
                        if (textContent.length >= 20) qualityScore += 8; // 충분한 길이
                        if (textContent.length >= 50) qualityScore += 8; // 더 긴 텍스트
                        if (!/^(답글|댓글|더보기|클릭|선택)/.test(textContent)) qualityScore += 5; // 의미있는 텍스트
                        
                        // 고유 ID 보너스
                        if (uniqueId && !uniqueId.startsWith('auto_')) qualityScore += 10; // 실제 고유 ID
                        
                        // 타입 정확도 보너스  
                        if (contentType !== 'unknown' && contentType !== tagName) qualityScore += 5; // 정확한 타입 추론
                        
                        // 시간 정보 보너스
                        if (timestamp && !timestamp.includes(new Date().toISOString().split('T')[0])) qualityScore += 5; // 실제 시간
                        
                        detailedLogs.push('   👁️ 앵커[' + index + '] 품질점수: ' + qualityScore + '점 (패키지=' + packageScore + ', 보너스=' + (qualityScore-packageScore) + ')');
                        
                        // 👁️ **보이는 요소는 품질 점수 50점 미만 제외**
                        if (qualityScore < 50) {
                            detailedLogs.push('   👁️ 앵커[' + index + '] 품질점수 부족으로 제외: ' + qualityScore + '점 < 50점');
                            return null;
                        }
                        
                        // 🚫 **수정: DOM 요소 대신 기본 타입만 반환**
                        const anchorData = {
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
                            
                            // 🎯 **4요소 패키지 (핵심)**
                            fourElementPackage: fourElementPackage,
                            
                            // 메타 정보
                            anchorType: 'fourElementPackage',
                            captureTimestamp: Date.now(),
                            qualityScore: qualityScore,
                            anchorIndex: index
                        };
                        
                        // 👁️ **가시성 정보 추가**
                        if (includeVisibility && visibilityResult) {
                            anchorData.isVisible = visibilityResult.visible;
                            anchorData.visibilityReason = visibilityResult.reason;
                            anchorData.visibilityDetails = {
                                inViewport: visibilityResult.inViewport,
                                elementRect: {
                                    width: rect.width,
                                    height: rect.height,
                                    top: rect.top,
                                    left: rect.left
                                },
                                actualViewportRect: actualViewportRect
                            };
                        }
                        
                        return anchorData;
                        
                    } catch(e) {
                        console.error('👁️ 보이는 4요소 패키지 앵커[' + index + '] 생성 실패:', e);
                        detailedLogs.push('  👁️ 앵커[' + index + '] 생성 실패: ' + e.message);
                        return null;
                    }
                }
                
                // 👁️ **메인 실행 - 보이는 요소만 4요소 패키지 데이터 수집**
                const startTime = Date.now();
                const packageAnchorsData = collectVisibleFourElementPackageAnchors();
                const endTime = Date.now();
                const captureTime = endTime - startTime;
                
                captureStats.captureTime = captureTime;
                pageAnalysis.capturePerformance = {
                    totalTime: captureTime,
                    anchorsPerSecond: packageAnchorsData.anchors.length > 0 ? (packageAnchorsData.anchors.length / (captureTime / 1000)).toFixed(2) : 0
                };
                
                detailedLogs.push('=== 보이는 요소만 4요소 패키지 캡처 완료 (' + captureTime + 'ms) ===');
                detailedLogs.push('최종 보이는 4요소 패키지 앵커: ' + packageAnchorsData.anchors.length + '개');
                detailedLogs.push('처리 성능: ' + pageAnalysis.capturePerformance.anchorsPerSecond + ' 앵커/초');
                
                console.log('👁️ 보이는 요소만 4요소 패키지 캡처 완료:', {
                    visiblePackageAnchorsCount: packageAnchorsData.anchors.length,
                    stats: packageAnchorsData.stats,
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight],
                    captureTime: captureTime,
                    actualViewportRect: actualViewportRect
                });
                
                // ✅ **수정: Promise 없이 직접 반환**
                return {
                    fourElementPackageAnchors: packageAnchorsData, // 🎯 **보이는 요소만 4요소 패키지 데이터**
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
                    actualViewportRect: actualViewportRect,     // 👁️ **실제 보이는 영역 정보**
                    detailedLogs: detailedLogs,                 // 📊 **상세 로그 배열**
                    captureStats: captureStats,                 // 📊 **캡처 통계**
                    pageAnalysis: pageAnalysis,                 // 📊 **페이지 분석 결과**
                    captureTime: captureTime                    // 📊 **캡처 소요 시간**
                };
            } catch(e) { 
                console.error('👁️ 보이는 요소만 4요소 패키지 캡처 실패:', e);
                return {
                    fourElementPackageAnchors: { anchors: [], stats: {} },
                    scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message,
                    detailedLogs: ['보이는 요소만 4요소 패키지 캡처 실패: ' + e.message],
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
