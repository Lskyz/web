//
//  BFCacheSnapshotManager.swift
//  📸 **개선된 4요소 패키지 조합 BFCache 페이지 스냅샷 및 복원 시스템**
//  🎯 **개선된 복원 순서** - 프리로딩 → 백분율 복원 → 앵커 복원 → 오차시 풀백
//  🔄 **데이터 프리로딩 우선** - 저장시점 콘텐츠 높이까지 선로딩 후 복원
//  📊 **상대적 백분율 복원** - 페이지 크기 변화 대응한 스마트 복원
//  🎯 **4요소 패키지 정밀 복원** - 앵커 기반 최종 위치 조정
//  🚨 **오차 임계값 풀백** - 복원 실패시 최상단으로 안전 복원
//  👁️ **보이는 요소만 캡처** - 실제 표시되는 활성 요소만 선별 캡처
//  🧹 **의미있는 텍스트 필터링** - 에러메시지, 로딩메시지 등 제외
//  🚫 **점진적 스크롤 제거** - 프리로딩으로 대체하여 중복 제거
//  ⏰ **렌더링 대기 추가** - 각 단계별 DOM 적용 완료 대기

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
    
    // 🔄 **프리로딩 설정**
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
    
    // ⏰ **핵심 수정: 렌더링 대기가 포함된 개선된 4단계 복원 시스템**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("⏰ 렌더링 대기 포함 4단계 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 캡처 상태: \(captureStatus.rawValue)")
        TabPersistenceManager.debugMessages.append("📊 목표 스크롤: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 저장시점 콘텐츠: \(String(format: "%.0f", preloadingConfig.targetContentHeight))px")
        
        // ⏰ **1단계: 데이터 프리로딩 (저장시점 콘텐츠 높이까지) + 렌더링 대기**
        performDataPreloadingWithRenderWait(to: webView) { preloadSuccess in
            TabPersistenceManager.debugMessages.append("🔄 1단계 데이터 프리로딩 + 렌더링 대기: \(preloadSuccess ? "성공" : "실패")")
            
            // ⏰ **단계간 대기시간 증가: 150ms → 300ms**
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // ⏰ **2단계: 상대적 백분율 복원 + 렌더링 대기**
                self.performPercentageRestoreWithRenderWait(to: webView) { percentageSuccess in
                    TabPersistenceManager.debugMessages.append("📊 2단계 백분율 복원 + 렌더링 대기: \(percentageSuccess ? "성공" : "실패")")
                    
                    // ⏰ **단계간 대기시간 증가**
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        // ⏰ **3단계: 4요소 패키지 앵커 정밀 복원 + 렌더링 대기**
                        self.performFourElementPackageRestoreWithRenderWait(to: webView) { anchorSuccess in
                            TabPersistenceManager.debugMessages.append("🎯 3단계 앵커 정밀 복원 + 렌더링 대기: \(anchorSuccess ? "성공" : "실패")")
                            
                            // ⏰ **단계간 대기시간 증가**
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                // ⏰ **4단계: 최종 검증 및 오차 임계값 풀백 + 렌더링 대기**
                                self.performFinalVerificationAndFallbackWithRenderWait(to: webView) { finalSuccess in
                                    TabPersistenceManager.debugMessages.append("✅ 4단계 최종 검증 + 렌더링 대기: \(finalSuccess ? "성공" : "풀백")")
                                    
                                    let overallSuccess = preloadSuccess || percentageSuccess || anchorSuccess || finalSuccess
                                    TabPersistenceManager.debugMessages.append("⏰ 전체 복원 결과 (렌더링 대기 포함): \(overallSuccess ? "✅ 성공" : "❌ 실패")")
                                    completion(overallSuccess)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // ⏰ **1단계: 데이터 프리로딩 + 렌더링 대기**
    private func performDataPreloadingWithRenderWait(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        if !preloadingConfig.enableDataPreloading {
            TabPersistenceManager.debugMessages.append("🔄 데이터 프리로딩 비활성화 - 스킵")
            completion(false)
            return
        }
        
        TabPersistenceManager.debugMessages.append("⏰ 저장시점 콘텐츠 높이까지 프리로딩 + 렌더링 대기 시작")
        
        let preloadingJS = generateDataPreloadingScriptWithRenderWait()
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(preloadingJS) { result, error in
                var success = false
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔄 프리로딩 JS 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    success = (resultDict["success"] as? Bool) ?? false
                    
                    if let loadedContentHeight = resultDict["loadedContentHeight"] as? Double {
                        TabPersistenceManager.debugMessages.append("🔄 프리로딩 후 콘텐츠 높이: \(String(format: "%.1f", loadedContentHeight))px")
                    }
                    
                    if let renderWaitTime = resultDict["renderWaitTime"] as? Double {
                        TabPersistenceManager.debugMessages.append("⏰ 프리로딩 렌더링 대기 시간: \(String(format: "%.1f", renderWaitTime))ms")
                    }
                    
                    if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                        TabPersistenceManager.debugMessages.append("🔄 프리로딩 + 렌더링 대기 상세:")
                        for log in detailedLogs.prefix(5) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                }
                
                TabPersistenceManager.debugMessages.append("⏰ 1단계 프리로딩 + 렌더링 대기 결과: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // ⏰ **2단계: 상대적 백분율 복원 + 렌더링 대기**
    private func performPercentageRestoreWithRenderWait(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("⏰ 상대적 백분율 복원 + 렌더링 대기 시작")
        
        let percentageRestoreJS = generatePercentageRestoreScriptWithRenderWait()
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(percentageRestoreJS) { result, error in
                var success = false
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("📊 백분율 복원 JS 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    success = (resultDict["success"] as? Bool) ?? false
                    
                    if let renderWaitTime = resultDict["renderWaitTime"] as? Double {
                        TabPersistenceManager.debugMessages.append("⏰ 백분율 복원 렌더링 대기 시간: \(String(format: "%.1f", renderWaitTime))ms")
                    }
                    
                    if let actualY = resultDict["actualY"] as? Double {
                        TabPersistenceManager.debugMessages.append("📊 실제 복원된 Y (렌더링 후): \(String(format: "%.1f", actualY))px")
                    }
                    
                    if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                        for log in detailedLogs.prefix(3) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                }
                
                TabPersistenceManager.debugMessages.append("⏰ 2단계 백분율 복원 + 렌더링 대기 결과: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // ⏰ **3단계: 4요소 패키지 앵커 정밀 복원 + 렌더링 대기**
    private func performFourElementPackageRestoreWithRenderWait(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("⏰ 4요소 패키지 앵커 정밀 복원 + 렌더링 대기 시작")
        
        let anchorRestoreJS = generateFourElementPackageRestoreScriptWithRenderWait()
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(anchorRestoreJS) { result, error in
                var success = false
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🎯 앵커 복원 JS 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    success = (resultDict["success"] as? Bool) ?? false
                    
                    if let renderWaitTime = resultDict["renderWaitTime"] as? Double {
                        TabPersistenceManager.debugMessages.append("⏰ 앵커 복원 렌더링 대기 시간: \(String(format: "%.1f", renderWaitTime))ms")
                    }
                    
                    if let verification = resultDict["verification"] as? [String: Any],
                       let actualRestoreSuccess = verification["actualRestoreSuccess"] as? Bool {
                        TabPersistenceManager.debugMessages.append("🎯 실제 복원 성공 (렌더링 후): \(actualRestoreSuccess)")
                        success = actualRestoreSuccess // 실제 복원 성공 여부를 우선시
                    }
                    
                    if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                        for log in detailedLogs.prefix(3) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                }
                
                TabPersistenceManager.debugMessages.append("⏰ 3단계 앵커 복원 + 렌더링 대기 결과: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // ⏰ **4단계: 최종 검증 및 오차 임계값 풀백 + 렌더링 대기**
    private func performFinalVerificationAndFallbackWithRenderWait(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("⏰ 최종 검증 및 오차 임계값 풀백 + 렌더링 대기 시작")
        
        let verificationJS = generateFinalVerificationScriptWithRenderWait()
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(verificationJS) { result, error in
                var success = false
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("✅ 최종 검증 JS 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    success = (resultDict["success"] as? Bool) ?? false
                    
                    if let renderWaitTime = resultDict["renderWaitTime"] as? Double {
                        TabPersistenceManager.debugMessages.append("⏰ 최종 검증 렌더링 대기 시간: \(String(format: "%.1f", renderWaitTime))ms")
                    }
                    
                    if let fallbackApplied = resultDict["fallbackApplied"] as? Bool,
                       fallbackApplied {
                        TabPersistenceManager.debugMessages.append("🚨 오차 임계값 초과 → 최상단 풀백 적용 (렌더링 대기 포함)")
                        success = true // 풀백 적용도 성공으로 간주
                    }
                    
                    if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                        for log in detailedLogs.prefix(3) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                }
                
                TabPersistenceManager.debugMessages.append("⏰ 4단계 최종 검증 + 렌더링 대기 결과: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // ⏰ **데이터 프리로딩 + 렌더링 대기 JavaScript 생성**
    private func generateDataPreloadingScriptWithRenderWait() -> String {
        let targetHeight = preloadingConfig.targetContentHeight
        let maxAttempts = preloadingConfig.maxPreloadAttempts
        let batchSize = preloadingConfig.preloadBatchSize
        let enableBatchLoading = preloadingConfig.enableBatchLoading
        
        return """
        (function() {
            try {
                console.log('⏰ 저장시점까지 데이터 프리로딩 + 렌더링 대기 시작');
                
                const detailedLogs = [];
                const renderWaitStartTime = Date.now();
                const targetHeight = parseFloat('\(targetHeight)');
                const maxAttempts = parseInt('\(maxAttempts)');
                const batchSize = parseInt('\(batchSize)');
                const enableBatchLoading = \(enableBatchLoading);
                
                const initialHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                
                detailedLogs.push('⏰ 목표 높이: ' + targetHeight.toFixed(1) + 'px');
                detailedLogs.push('⏰ 초기 높이: ' + initialHeight.toFixed(1) + 'px');
                
                if (initialHeight >= targetHeight * 0.95) {
                    detailedLogs.push('⏰ 이미 충분한 콘텐츠 로드됨 - 프리로딩 불필요');
                    return new Promise(function(resolve) {
                        // ⏰ **렌더링 완료 대기**
                        requestAnimationFrame(function() {
                            requestAnimationFrame(function() {
                                const renderWaitTime = Date.now() - renderWaitStartTime;
                                resolve({
                                    success: true,
                                    reason: 'already_sufficient',
                                    loadedContentHeight: initialHeight,
                                    renderWaitTime: renderWaitTime,
                                    detailedLogs: detailedLogs
                                });
                            });
                        });
                    });
                }
                
                return new Promise(function(resolve) {
                    let currentHeight = initialHeight;
                    let loadingAttempts = 0;
                    let totalHeightIncrease = 0;
                    
                    // 무한스크롤 트리거 함수
                    function triggerInfiniteScrollLoading() {
                        let triggersUsed = 0;
                        
                        // 페이지 하단으로 스크롤
                        const maxScrollY = Math.max(0, currentHeight - viewportHeight);
                        window.scrollTo(0, maxScrollY);
                        triggersUsed++;
                        
                        // 스크롤 이벤트 발생
                        window.dispatchEvent(new Event('scroll', { bubbles: true }));
                        window.dispatchEvent(new Event('resize', { bubbles: true }));
                        triggersUsed++;
                        
                        // 더보기 버튼 클릭
                        const loadMoreButtons = document.querySelectorAll(
                            '[class*="load"], [class*="more"], .load-more, .show-more, ' +
                            '[data-testid*="load"], .infinite-scroll-trigger, .btn-more'
                        );
                        
                        for (let i = 0; i < loadMoreButtons.length; i++) {
                            try {
                                loadMoreButtons[i].click();
                                triggersUsed++;
                            } catch(e) {
                                // 클릭 실패는 무시
                            }
                        }
                        
                        return triggersUsed;
                    }
                    
                    // ⏰ **프리로딩 실행 + 렌더링 대기**
                    function executePreloadingWithRenderWait() {
                        if (enableBatchLoading) {
                            let completedBatches = 0;
                            
                            function processBatch(batch) {
                                if (batch >= batchSize || loadingAttempts >= maxAttempts || currentHeight >= targetHeight) {
                                    // ⏰ **모든 배치 완료 후 렌더링 대기**
                                    requestAnimationFrame(function() {
                                        requestAnimationFrame(function() {
                                            const finalHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                                            const success = finalHeight >= targetHeight * 0.8 || totalHeightIncrease > 0;
                                            const renderWaitTime = Date.now() - renderWaitStartTime;
                                            
                                            detailedLogs.push('⏰ 프리로딩 완료 (렌더링 대기 후): ' + finalHeight.toFixed(1) + 'px');
                                            detailedLogs.push('⏰ 렌더링 대기 시간: ' + renderWaitTime + 'ms');
                                            
                                            resolve({
                                                success: success,
                                                reason: success ? 'preloading_success' : 'insufficient_growth',
                                                loadedContentHeight: finalHeight,
                                                renderWaitTime: renderWaitTime,
                                                detailedLogs: detailedLogs
                                            });
                                        });
                                    });
                                    return;
                                }
                                
                                const beforeHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                                const triggersUsed = triggerInfiniteScrollLoading();
                                loadingAttempts++;
                                
                                // ⏰ **각 배치마다 렌더링 대기**
                                requestAnimationFrame(function() {
                                    const afterHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                                    const heightDiff = afterHeight - beforeHeight;
                                    
                                    if (heightDiff > 0) {
                                        totalHeightIncrease += heightDiff;
                                        currentHeight = afterHeight;
                                        detailedLogs.push('⏰ 배치[' + (batch + 1) + '] 높이 증가 (렌더링 후): ' + heightDiff.toFixed(1) + 'px');
                                    }
                                    
                                    // 다음 배치 처리 (50ms 대기)
                                    setTimeout(function() {
                                        processBatch(batch + 1);
                                    }, 50);
                                });
                            }
                            
                            processBatch(0);
                        } else {
                            // 단일 로딩 + 렌더링 대기
                            const triggersUsed = triggerInfiniteScrollLoading();
                            loadingAttempts = 1;
                            
                            // ⏰ **렌더링 완료 대기**
                            requestAnimationFrame(function() {
                                requestAnimationFrame(function() {
                                    const afterHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                                    totalHeightIncrease = afterHeight - initialHeight;
                                    currentHeight = afterHeight;
                                    
                                    const success = currentHeight >= targetHeight * 0.8 || totalHeightIncrease > 0;
                                    const renderWaitTime = Date.now() - renderWaitStartTime;
                                    
                                    detailedLogs.push('⏰ 단일 프리로딩 완료 (렌더링 후): ' + currentHeight.toFixed(1) + 'px');
                                    detailedLogs.push('⏰ 렌더링 대기 시간: ' + renderWaitTime + 'ms');
                                    
                                    resolve({
                                        success: success,
                                        reason: success ? 'preloading_success' : 'insufficient_growth',
                                        loadedContentHeight: currentHeight,
                                        renderWaitTime: renderWaitTime,
                                        detailedLogs: detailedLogs
                                    });
                                });
                            });
                        }
                    }
                    
                    executePreloadingWithRenderWait();
                });
                
            } catch(e) {
                console.error('⏰ 데이터 프리로딩 + 렌더링 대기 실패:', e);
                return {
                    success: false,
                    reason: 'exception',
                    error: e.message,
                    renderWaitTime: 0,
                    detailedLogs: ['⏰ 프리로딩 + 렌더링 대기 실패: ' + e.message]
                };
            }
        })()
        """
    }
    
    // ⏰ **상대적 백분율 복원 + 렌더링 대기 JavaScript 생성**
    private func generatePercentageRestoreScriptWithRenderWait() -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        
        return """
        (function() {
            try {
                console.log('⏰ 상대적 백분율 복원 + 렌더링 대기 시작');
                
                return new Promise(function(resolve) {
                    const detailedLogs = [];
                    const renderWaitStartTime = Date.now();
                    const targetX = parseFloat('\(targetX)');
                    const targetY = parseFloat('\(targetY)');
                    const targetPercentX = parseFloat('\(targetPercentX)');
                    const targetPercentY = parseFloat('\(targetPercentY)');
                    
                    const currentViewportHeight = parseFloat(window.innerHeight) || 0;
                    const currentViewportWidth = parseFloat(window.innerWidth) || 0;
                    const currentContentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                    const currentContentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                    
                    const currentMaxScrollY = Math.max(0, currentContentHeight - currentViewportHeight);
                    const currentMaxScrollX = Math.max(0, currentContentWidth - currentViewportWidth);
                    
                    detailedLogs.push('⏰ 현재 콘텐츠: ' + currentContentWidth.toFixed(0) + ' x ' + currentContentHeight.toFixed(0));
                    detailedLogs.push('⏰ 목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                    
                    let calculatedX = 0;
                    let calculatedY = 0;
                    let method = 'percentage';
                    
                    // 백분율 기반 위치 계산
                    if (targetPercentY > 0 && currentMaxScrollY > 0) {
                        calculatedY = (targetPercentY / 100.0) * currentMaxScrollY;
                        method = 'percentage_y';
                    } else if (targetY > 0 && currentMaxScrollY > 0) {
                        calculatedY = Math.min(targetY, currentMaxScrollY);
                        method = 'absolute_y_clamped';
                    } else {
                        calculatedY = 0;
                        method = 'fallback_top';
                    }
                    
                    if (targetPercentX > 0 && currentMaxScrollX > 0) {
                        calculatedX = (targetPercentX / 100.0) * currentMaxScrollX;
                    } else {
                        calculatedX = Math.min(targetX, currentMaxScrollX);
                    }
                    
                    detailedLogs.push('⏰ 계산된 위치: X=' + calculatedX.toFixed(1) + ', Y=' + calculatedY.toFixed(1));
                    
                    // ⏰ **스크롤 실행 후 렌더링 완료 대기**
                    window.scrollTo(calculatedX, calculatedY);
                    document.documentElement.scrollTop = calculatedY;
                    document.documentElement.scrollLeft = calculatedX;
                    document.body.scrollTop = calculatedY;
                    document.body.scrollLeft = calculatedX;
                    
                    if (document.scrollingElement) {
                        document.scrollingElement.scrollTop = calculatedY;
                        document.scrollingElement.scrollLeft = calculatedX;
                    }
                    
                    // ⏰ **렌더링 완료까지 대기 (이중 requestAnimationFrame)**
                    requestAnimationFrame(function() {
                        requestAnimationFrame(function() {
                            // ⏰ **추가 100ms 대기로 스크롤 적용 확실히 보장**
                            setTimeout(function() {
                                const actualY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                const actualX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                const diffY = Math.abs(actualY - calculatedY);
                                const diffX = Math.abs(actualX - calculatedX);
                                const tolerance = 50.0;
                                const success = diffY <= tolerance && diffX <= tolerance;
                                const renderWaitTime = Date.now() - renderWaitStartTime;
                                
                                detailedLogs.push('⏰ 실제 위치 (렌더링 후): X=' + actualX.toFixed(1) + ', Y=' + actualY.toFixed(1));
                                detailedLogs.push('⏰ 위치 차이: X=' + diffX.toFixed(1) + ', Y=' + diffY.toFixed(1));
                                detailedLogs.push('⏰ 렌더링 대기 시간: ' + renderWaitTime + 'ms');
                                
                                resolve({
                                    success: success,
                                    method: method,
                                    actualX: actualX,
                                    actualY: actualY,
                                    diffX: diffX,
                                    diffY: diffY,
                                    renderWaitTime: renderWaitTime,
                                    detailedLogs: detailedLogs
                                });
                            }, 100); // ⏰ **추가 100ms 대기**
                        });
                    });
                });
                
            } catch(e) {
                console.error('⏰ 백분율 복원 + 렌더링 대기 실패:', e);
                return {
                    success: false,
                    method: 'error',
                    error: e.message,
                    renderWaitTime: 0,
                    detailedLogs: ['⏰ 백분율 복원 + 렌더링 대기 실패: ' + e.message]
                };
            }
        })()
        """
    }
    
    // ⏰ **4요소 패키지 앵커 정밀 복원 + 렌더링 대기 JavaScript 생성**
    private func generateFourElementPackageRestoreScriptWithRenderWait() -> String {
        let targetPos = self.scrollPosition
        
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
                return new Promise(function(resolve) {
                    const renderWaitStartTime = Date.now();
                    const targetX = parseFloat('\(targetPos.x)');
                    const targetY = parseFloat('\(targetPos.y)');
                    const fourElementPackageData = \(fourElementPackageDataJSON);
                    
                    const detailedLogs = [];
                    let restoredByPackage = false;
                    let usedMethod = 'none';
                    let anchorInfo = 'none';
                    
                    detailedLogs.push('⏰ 4요소 패키지 앵커 정밀 복원 + 렌더링 대기 시작');
                    detailedLogs.push('⏰ 목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                    
                    function performScrollWithRenderWait() {
                        if (fourElementPackageData && fourElementPackageData.anchors && fourElementPackageData.anchors.length > 0) {
                            const anchors = fourElementPackageData.anchors;
                            
                            // 완전한 4요소 패키지 앵커 필터링
                            const completeAnchors = anchors.filter(function(anchor) {
                                if (!anchor.fourElementPackage) return false;
                                const pkg = anchor.fourElementPackage;
                                return pkg.id && pkg.type && pkg.ts && pkg.kw;
                            });
                            
                            detailedLogs.push('⏰ 완전 패키지 앵커: ' + completeAnchors.length + '개');
                            
                            // 완전 패키지 앵커 순회하여 복원 시도
                            for (let i = 0; i < completeAnchors.length; i++) {
                                const anchor = completeAnchors[i];
                                const pkg = anchor.fourElementPackage;
                                
                                let foundElement = null;
                                
                                // ID 기반 검색
                                if (pkg.id && pkg.id !== 'unknown' && !pkg.id.startsWith('auto_')) {
                                    foundElement = document.getElementById(pkg.id);
                                    
                                    if (!foundElement) {
                                        const dataSelectors = [
                                            '[data-id="' + pkg.id + '"]',
                                            '[data-' + pkg.type + '-id="' + pkg.id + '"]',
                                            '[data-item-id="' + pkg.id + '"]'
                                        ];
                                        
                                        for (let j = 0; j < dataSelectors.length; j++) {
                                            try {
                                                const elements = document.querySelectorAll(dataSelectors[j]);
                                                if (elements.length > 0) {
                                                    foundElement = elements[0];
                                                    break;
                                                }
                                            } catch(e) {
                                                // selector 오류 무시
                                            }
                                        }
                                    }
                                }
                                
                                // 키워드 기반 대체 검색
                                if (!foundElement && pkg.kw && pkg.kw !== 'unknown') {
                                    const allElements = document.querySelectorAll('*');
                                    for (let j = 0; j < allElements.length; j++) {
                                        const el = allElements[j];
                                        const text = (el.textContent || '').trim();
                                        if (text.includes(pkg.kw) && text.length >= 10) {
                                            foundElement = el;
                                            break;
                                        }
                                    }
                                }
                                
                                if (foundElement) {
                                    detailedLogs.push('⏰ 앵커[' + i + '] 요소 발견: ' + foundElement.tagName.toLowerCase());
                                    
                                    // ⏰ **요소로 스크롤 후 렌더링 대기**
                                    foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                                    
                                    // 오프셋 보정
                                    if (anchor.offsetFromTop) {
                                        const offset = parseFloat(anchor.offsetFromTop) || 0;
                                        window.scrollBy(0, -offset);
                                    }
                                    
                                    restoredByPackage = true;
                                    usedMethod = 'package_anchor_' + i;
                                    anchorInfo = pkg.id + '_' + pkg.type;
                                    
                                    detailedLogs.push('⏰ 앵커 복원 성공: ' + anchorInfo);
                                    break;
                                }
                            }
                        }
                        
                        if (!restoredByPackage) {
                            detailedLogs.push('⏰ 앵커 복원 실패 - 좌표 복원 시도');
                            window.scrollTo(targetX, targetY);
                            usedMethod = 'coordinate_fallback';
                        }
                        
                        // ⏰ **스크롤 완료 후 렌더링 대기**
                        requestAnimationFrame(function() {
                            requestAnimationFrame(function() {
                                // ⏰ **추가 100ms 대기로 앵커 스크롤 적용 확실히 보장**
                                setTimeout(function() {
                                    // 결과 검증
                                    const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                    const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                    const diffY = Math.abs(currentY - targetY);
                                    const diffX = Math.abs(currentX - targetX);
                                    const tolerance = 30.0; // 앵커 복원은 더 정밀
                                    const success = diffY <= tolerance && diffX <= tolerance;
                                    const actualRestoreSuccess = diffY <= 50; // 실제 복원 성공 기준
                                    const renderWaitTime = Date.now() - renderWaitStartTime;
                                    
                                    detailedLogs.push('⏰ 앵커 복원 후 (렌더링 후): X=' + currentX.toFixed(1) + ', Y=' + currentY.toFixed(1));
                                    detailedLogs.push('⏰ 목표와 차이: X=' + diffX.toFixed(1) + ', Y=' + diffY.toFixed(1));
                                    detailedLogs.push('⏰ 렌더링 대기 시간: ' + renderWaitTime + 'ms');
                                    
                                    resolve({
                                        success: success,
                                        method: usedMethod,
                                        anchorInfo: anchorInfo,
                                        packageBased: restoredByPackage,
                                        renderWaitTime: renderWaitTime,
                                        verification: {
                                            actualRestoreSuccess: actualRestoreSuccess,
                                            final: [currentX, currentY],
                                            target: [targetX, targetY],
                                            diff: [diffX, diffY],
                                            tolerance: tolerance
                                        },
                                        detailedLogs: detailedLogs
                                    });
                                }, 100); // ⏰ **추가 100ms 대기**
                            });
                        });
                    }
                    
                    performScrollWithRenderWait();
                });
                
            } catch(e) {
                console.error('⏰ 앵커 복원 + 렌더링 대기 실패:', e);
                return {
                    success: false,
                    method: 'error',
                    error: e.message,
                    packageBased: false,
                    renderWaitTime: 0,
                    detailedLogs: ['⏰ 앵커 복원 + 렌더링 대기 실패: ' + e.message]
                };
            }
        })()
        """
    }
    
    // ⏰ **최종 검증 및 오차 임계값 풀백 + 렌더링 대기 JavaScript 생성**
    private func generateFinalVerificationScriptWithRenderWait() -> String {
        let targetY = scrollPosition.y
        let targetX = scrollPosition.x
        
        return """
        (function() {
            try {
                return new Promise(function(resolve) {
                    const renderWaitStartTime = Date.now();
                    const targetX = parseFloat('\(targetX)');
                    const targetY = parseFloat('\(targetY)');
                    const detailedLogs = [];
                    
                    detailedLogs.push('⏰ 최종 검증 및 오차 임계값 풀백 + 렌더링 대기 시작');
                    
                    const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                    const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                    const diffY = Math.abs(currentY - targetY);
                    const diffX = Math.abs(currentX - targetX);
                    
                    // 🚨 **오차 임계값 설정**
                    const viewportHeight = parseFloat(window.innerHeight) || 0;
                    const toleranceThreshold = viewportHeight * 3; // 화면 높이의 3배
                    const basicTolerance = 100.0; // 기본 허용 오차
                    
                    const withinBasicTolerance = diffY <= basicTolerance && diffX <= basicTolerance;
                    const exceedsThreshold = diffY > toleranceThreshold || diffX > toleranceThreshold;
                    
                    detailedLogs.push('⏰ 현재 위치: X=' + currentX.toFixed(1) + ', Y=' + currentY.toFixed(1));
                    detailedLogs.push('⏰ 위치 차이: X=' + diffX.toFixed(1) + ', Y=' + diffY.toFixed(1));
                    detailedLogs.push('⏰ 임계값 초과: ' + exceedsThreshold);
                    
                    let fallbackApplied = false;
                    let finalSuccess = false;
                    
                    function completeVerificationWithRenderWait() {
                        if (withinBasicTolerance) {
                            detailedLogs.push('⏰ 기본 허용 오차 내 - 복원 성공');
                            finalSuccess = true;
                            finishVerification();
                        } else if (exceedsThreshold) {
                            detailedLogs.push('⏰ 🚨 오차 임계값 초과 - 최상단 풀백 실행');
                            
                            // ⏰ **최상단으로 풀백 후 렌더링 대기**
                            window.scrollTo(0, 0);
                            document.documentElement.scrollTop = 0;
                            document.documentElement.scrollLeft = 0;
                            document.body.scrollTop = 0;
                            document.body.scrollLeft = 0;
                            
                            if (document.scrollingElement) {
                                document.scrollingElement.scrollTop = 0;
                                document.scrollingElement.scrollLeft = 0;
                            }
                            
                            // ⏰ **풀백 후 렌더링 완료 대기**
                            requestAnimationFrame(function() {
                                requestAnimationFrame(function() {
                                    // ⏰ **추가 100ms 대기로 풀백 적용 확실히 보장**
                                    setTimeout(function() {
                                        fallbackApplied = true;
                                        finalSuccess = true; // 풀백도 성공으로 간주
                                        detailedLogs.push('⏰ 최상단 풀백 완료 (렌더링 후)');
                                        finishVerification();
                                    }, 100); // ⏰ **추가 100ms 대기**
                                });
                            });
                        } else {
                            detailedLogs.push('⏰ 기본 허용 오차는 초과했지만 임계값 내 - 현재 위치 유지');
                            finalSuccess = diffY <= basicTolerance * 2; // 2배까지는 허용
                            finishVerification();
                        }
                    }
                    
                    function finishVerification() {
                        const finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const finalDiffY = Math.abs(finalY - targetY);
                        const finalDiffX = Math.abs(finalX - targetX);
                        const renderWaitTime = Date.now() - renderWaitStartTime;
                        
                        detailedLogs.push('⏰ 최종 위치 (렌더링 후): X=' + finalX.toFixed(1) + ', Y=' + finalY.toFixed(1));
                        detailedLogs.push('⏰ 최종 차이: X=' + finalDiffX.toFixed(1) + ', Y=' + finalDiffY.toFixed(1));
                        detailedLogs.push('⏰ 렌더링 대기 시간: ' + renderWaitTime + 'ms');
                        
                        resolve({
                            success: finalSuccess,
                            withinTolerance: withinBasicTolerance,
                            fallbackApplied: fallbackApplied,
                            finalX: finalX,
                            finalY: finalY,
                            diffX: finalDiffX,
                            diffY: finalDiffY,
                            renderWaitTime: renderWaitTime,
                            detailedLogs: detailedLogs
                        });
                    }
                    
                    completeVerificationWithRenderWait();
                });
                
            } catch(e) {
                console.error('⏰ 최종 검증 + 렌더링 대기 실패:', e);
                return {
                    success: false,
                    error: e.message,
                    fallbackApplied: false,
                    renderWaitTime: 0,
                    detailedLogs: ['⏰ 최종 검증 + 렌더링 대기 실패: ' + e.message]
                };
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
