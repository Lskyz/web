//
//  BFCacheSnapshotManager.swift
//  📸 **개선된 4요소 패키지 조합 BFCache 페이지 스냅샷 및 복원 시스템**
//  🎯 **실제 스크롤 컨테이너 감지** - window/document뿐만 아니라 overflow:auto/scroll 컨테이너 감지
//  🔄 **스크롤 컨테이너 기반 복원** - 실제 스크롤 담당 요소를 찾아서 element.scrollTop으로 복원
//  ⏱️ **비동기 안정화 대기** - busy-wait 제거하고 적절한 비동기 대기 방식 적용
//  📦 **비동기 프리로딩 대기** - 무한스크롤 트리거 후 실제 콘텐츠 로딩 완료까지 대기
//  📊 **올바른 스크롤 기준 계산** - 실제 스크롤 컨테이너 기준으로 백분율 계산
//  🎯 **앵커 복원 컨테이너 보정** - 실제 스크롤 컨테이너 기준으로 요소 복원
//  🚫 **스무스 스크롤 간섭 대응** - scroll-behavior 일시 무효화 후 복원
//  👁️ **보이는 요소만 캡처** - 실제 표시되는 활성 요소만 선별 캡처
//  🧹 **의미있는 텍스트 필터링** - 에러메시지, 로딩메시지 등 제외

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
    
    // ⏱️ **개선된 대기 설정**
    let waitingConfig: WaitingConfig
    
    // 🎯 **스크롤 컨테이너 정보**
    let scrollContainerInfo: ScrollContainerInfo
    
    struct PreloadingConfig: Codable {
        let enableDataPreloading: Bool          // 🔄 데이터 프리로딩 활성화
        let enableBatchLoading: Bool            // 📦 배치 로딩 활성화  
        let targetContentHeight: CGFloat        // 🎯 목표 콘텐츠 높이
        let maxPreloadAttempts: Int            // ⚡ 최대 프리로딩 시도 횟수
        let preloadBatchSize: Int              // 📦 배치 크기
        let preloadTimeoutSeconds: Int         // ⏰ 프리로딩 타임아웃
        let enableAsyncWaiting: Bool            // 📦 **비동기 로딩 대기 활성화**
        let asyncWaitTimeoutMs: Int            // ⏰ **비동기 대기 타임아웃**
        
        static let `default` = PreloadingConfig(
            enableDataPreloading: true,
            enableBatchLoading: true,
            targetContentHeight: 0,
            maxPreloadAttempts: 10,
            preloadBatchSize: 5,
            preloadTimeoutSeconds: 30,
            enableAsyncWaiting: true,
            asyncWaitTimeoutMs: 2000
        )
    }
    
    // ⏱️ **개선된 대기 설정 구조체**
    struct WaitingConfig: Codable {
        let enableSmartWaiting: Bool           // 스마트 대기 활성화
        let useAsyncWaiting: Bool              // 🔄 **비동기 대기 사용 (busy-wait 대신)**
        let maxWaitTimeMs: Int                 // 최대 대기 시간 (ms)
        let minWaitTimeMs: Int                 // 최소 대기 시간 (ms)
        let stabilityCheckIntervalMs: Int      // 안정성 체크 간격 (ms)
        let domStabilityThresholdMs: Int       // DOM 안정화 임계값 (ms)
        let scrollStabilityThresholdMs: Int    // 🎯 **스크롤 안정화 임계값 (ms)**
        
        static let `default` = WaitingConfig(
            enableSmartWaiting: true,
            useAsyncWaiting: true,              // 🔄 **비동기 대기 기본 활성화**
            maxWaitTimeMs: 1500,               // 최대 1.5초 대기
            minWaitTimeMs: 100,                // 최소 100ms 대기
            stabilityCheckIntervalMs: 50,      // 50ms 간격으로 체크
            domStabilityThresholdMs: 200,      // 200ms 동안 변경 없으면 안정화
            scrollStabilityThresholdMs: 300    // 🎯 **스크롤 안정화 300ms**
        )
    }
    
    // 🎯 **스크롤 컨테이너 정보 구조체**
    struct ScrollContainerInfo: Codable {
        let hasMainScrollContainer: Bool       // 메인 스크롤 컨테이너 존재 여부
        let scrollContainerSelector: String?   // 스크롤 컨테이너 셀렉터
        let isWindowScroll: Bool              // window/document 스크롤 여부
        let containerScrollHeight: CGFloat     // 컨테이너 스크롤 높이
        let containerScrollWidth: CGFloat      // 컨테이너 스크롤 너비
        let containerClientHeight: CGFloat     // 컨테이너 클라이언트 높이
        let containerClientWidth: CGFloat      // 컨테이너 클라이언트 너비
        
        static let `default` = ScrollContainerInfo(
            hasMainScrollContainer: false,
            scrollContainerSelector: nil,
            isWindowScroll: true,
            containerScrollHeight: 0,
            containerScrollWidth: 0,
            containerClientHeight: 0,
            containerClientWidth: 0
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
        case waitingConfig
        case scrollContainerInfo
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
        waitingConfig = try container.decodeIfPresent(WaitingConfig.self, forKey: .waitingConfig) ?? WaitingConfig.default
        scrollContainerInfo = try container.decodeIfPresent(ScrollContainerInfo.self, forKey: .scrollContainerInfo) ?? ScrollContainerInfo.default
        
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
        try container.encode(waitingConfig, forKey: .waitingConfig)
        try container.encode(scrollContainerInfo, forKey: .scrollContainerInfo)
        
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
         preloadingConfig: PreloadingConfig = PreloadingConfig.default,
         waitingConfig: WaitingConfig = WaitingConfig.default,
         scrollContainerInfo: ScrollContainerInfo = ScrollContainerInfo.default) {
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
            preloadTimeoutSeconds: preloadingConfig.preloadTimeoutSeconds,
            enableAsyncWaiting: preloadingConfig.enableAsyncWaiting,
            asyncWaitTimeoutMs: preloadingConfig.asyncWaitTimeoutMs
        )
        self.waitingConfig = waitingConfig
        self.scrollContainerInfo = scrollContainerInfo
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🚀 **핵심 개선: 스크롤 컨테이너 감지 기반 4단계 복원 시스템**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🚀 개선된 스크롤 컨테이너 감지 기반 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 캡처 상태: \(captureStatus.rawValue)")
        TabPersistenceManager.debugMessages.append("📊 목표 스크롤: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("🎯 스크롤 컨테이너: \(scrollContainerInfo.hasMainScrollContainer ? "감지됨" : "미감지") - window기반: \(scrollContainerInfo.isWindowScroll)")
        TabPersistenceManager.debugMessages.append("⏱️ 대기 방식: \(waitingConfig.useAsyncWaiting ? "비동기" : "동기")")
        
        // 🚀 **1단계: 스크롤 컨테이너 재감지 및 데이터 프리로딩**
        performScrollContainerDetectionAndPreloading(to: webView) { preloadSuccess in
            TabPersistenceManager.debugMessages.append("🔄 1단계 컨테이너 감지 및 프리로딩: \(preloadSuccess ? "성공" : "실패")")
            
            // ⏱️ **프리로딩 후 비동기 안정화 대기**
            self.waitForAsyncStabilization(webView: webView, stepName: "프리로딩 후") { 
                
                // 🚀 **2단계: 스크롤 컨테이너 기반 백분율 복원**
                self.performContainerBasedPercentageRestore(to: webView) { percentageSuccess in
                    TabPersistenceManager.debugMessages.append("📊 2단계 컨테이너 기반 백분율 복원: \(percentageSuccess ? "성공" : "실패")")
                    
                    // ⏱️ **스크롤 완료 비동기 대기**
                    self.waitForAsyncScrollCompletion(webView: webView, stepName: "백분율 복원 후") {
                        
                        // 🚀 **3단계: 4요소 패키지 앵커 컨테이너 기반 정밀 복원**
                        self.performContainerBasedFourElementPackageRestore(to: webView) { anchorSuccess in
                            TabPersistenceManager.debugMessages.append("🎯 3단계 컨테이너 기반 앵커 복원: \(anchorSuccess ? "성공" : "실패")")
                            
                            // ⏱️ **앵커 스크롤 완료 비동기 대기**
                            self.waitForAsyncScrollCompletion(webView: webView, stepName: "앵커 복원 후") {
                                
                                // 🚀 **4단계: 최종 검증 및 스무스 스크롤 대응**
                                self.performFinalVerificationWithSmoothScrollHandling(to: webView) { finalSuccess in
                                    TabPersistenceManager.debugMessages.append("✅ 4단계 최종 검증: \(finalSuccess ? "성공" : "풀백")")
                                    
                                    let overallSuccess = preloadSuccess || percentageSuccess || anchorSuccess || finalSuccess
                                    TabPersistenceManager.debugMessages.append("🚀 전체 복원 결과: \(overallSuccess ? "✅ 성공" : "❌ 실패")")
                                    completion(overallSuccess)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // ⏱️ **비동기 안정화 대기 메서드 - busy-wait 제거**
    private func waitForAsyncStabilization(webView: WKWebView, stepName: String, completion: @escaping () -> Void) {
        if !waitingConfig.enableSmartWaiting || !waitingConfig.useAsyncWaiting {
            TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 비동기 대기 비활성화 - 즉시 진행")
            completion()
            return
        }
        
        TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 비동기 안정화 대기 시작")
        
        let waitScript = generateAsyncStabilizationWaitScript(
            maxWaitMs: waitingConfig.maxWaitTimeMs,
            minWaitMs: waitingConfig.minWaitTimeMs,
            stabilityThresholdMs: waitingConfig.domStabilityThresholdMs,
            checkIntervalMs: waitingConfig.stabilityCheckIntervalMs
        )
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(waitScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 비동기 대기 스크립트 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    if let waitedMs = resultDict["waitedMs"] as? Int {
                        TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 비동기 대기 완료: \(waitedMs)ms")
                    }
                    if let method = resultDict["method"] as? String {
                        TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 대기 방법: \(method)")
                    }
                    if let mutationCount = resultDict["mutationCount"] as? Int {
                        TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 감지된 DOM 변경: \(mutationCount)회")
                    }
                }
                completion()
            }
        }
    }
    
    // ⏱️ **비동기 스크롤 완료 대기 메서드 - busy-wait 제거**
    private func waitForAsyncScrollCompletion(webView: WKWebView, stepName: String, completion: @escaping () -> Void) {
        if !waitingConfig.enableSmartWaiting || !waitingConfig.useAsyncWaiting {
            TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 비동기 스크롤 대기 비활성화 - 즉시 진행")
            completion()
            return
        }
        
        TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 비동기 스크롤 완료 대기 시작")
        
        let waitScript = generateAsyncScrollCompletionWaitScript(
            maxWaitMs: min(waitingConfig.maxWaitTimeMs, 800), // 스크롤은 더 짧게
            minWaitMs: waitingConfig.minWaitTimeMs,
            scrollStabilityMs: waitingConfig.scrollStabilityThresholdMs,
            checkIntervalMs: waitingConfig.stabilityCheckIntervalMs
        )
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(waitScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 비동기 스크롤 대기 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    if let waitedMs = resultDict["waitedMs"] as? Int {
                        TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 스크롤 대기: \(waitedMs)ms")
                    }
                    if let scrollStable = resultDict["scrollStable"] as? Bool {
                        TabPersistenceManager.debugMessages.append("⏱️ \(stepName) 스크롤 안정화: \(scrollStable)")
                    }
                }
                completion()
            }
        }
    }
    
    // 🔄 **1단계: 스크롤 컨테이너 재감지 및 데이터 프리로딩**
    private func performScrollContainerDetectionAndPreloading(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🔄 스크롤 컨테이너 재감지 및 데이터 프리로딩 시작")
        
        let containerDetectionAndPreloadingJS = generateScrollContainerDetectionAndPreloadingScript()
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(containerDetectionAndPreloadingJS) { result, error in
                var success = false
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔄 컨테이너 감지 및 프리로딩 JS 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    success = (resultDict["success"] as? Bool) ?? false
                    
                    // 스크롤 컨테이너 정보 로깅
                    if let containerInfo = resultDict["scrollContainerInfo"] as? [String: Any] {
                        TabPersistenceManager.debugMessages.append("🎯 스크롤 컨테이너 정보: \(containerInfo)")
                    }
                    
                    // 프리로딩 결과 로깅
                    if let preloadingResult = resultDict["preloadingResult"] as? [String: Any] {
                        if let loadedHeight = preloadingResult["loadedContentHeight"] as? Double {
                            TabPersistenceManager.debugMessages.append("🔄 프리로딩 후 높이: \(String(format: "%.1f", loadedHeight))px")
                        }
                        if let heightIncrease = preloadingResult["heightIncrease"] as? Double {
                            TabPersistenceManager.debugMessages.append("🔄 높이 증가량: \(String(format: "%.1f", heightIncrease))px")
                        }
                    }
                    
                    if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                        TabPersistenceManager.debugMessages.append("🔄 컨테이너 감지 및 프리로딩 상세:")
                        for log in detailedLogs.prefix(5) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                }
                
                TabPersistenceManager.debugMessages.append("🔄 1단계 컨테이너 감지 및 프리로딩 결과: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // 📊 **2단계: 스크롤 컨테이너 기반 백분율 복원**
    private func performContainerBasedPercentageRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("📊 스크롤 컨테이너 기반 백분율 복원 시작")
        
        let containerBasedPercentageRestoreJS = generateContainerBasedPercentageRestoreScript()
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(containerBasedPercentageRestoreJS) { result, error in
                var success = false
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("📊 컨테이너 기반 백분율 복원 JS 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    success = (resultDict["success"] as? Bool) ?? false
                    
                    if let method = resultDict["method"] as? String {
                        TabPersistenceManager.debugMessages.append("📊 사용된 복원 방법: \(method)")
                    }
                    
                    if let containerType = resultDict["containerType"] as? String {
                        TabPersistenceManager.debugMessages.append("📊 복원된 컨테이너 타입: \(containerType)")
                    }
                    
                    if let calculatedY = resultDict["calculatedY"] as? Double {
                        TabPersistenceManager.debugMessages.append("📊 계산된 Y 위치: \(String(format: "%.1f", calculatedY))px")
                    }
                    
                    if let actualY = resultDict["actualY"] as? Double {
                        TabPersistenceManager.debugMessages.append("📊 실제 복원된 Y: \(String(format: "%.1f", actualY))px")
                    }
                    
                    if let diffY = resultDict["diffY"] as? Double {
                        TabPersistenceManager.debugMessages.append("📊 목표와 차이: \(String(format: "%.1f", diffY))px")
                    }
                    
                    if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                        for log in detailedLogs.prefix(3) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                }
                
                TabPersistenceManager.debugMessages.append("📊 2단계 컨테이너 기반 백분율 복원 결과: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // 🎯 **3단계: 4요소 패키지 앵커 컨테이너 기반 정밀 복원**
    private func performContainerBasedFourElementPackageRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 4요소 패키지 앵커 컨테이너 기반 정밀 복원 시작")
        
        let containerBasedAnchorRestoreJS = generateContainerBasedFourElementPackageRestoreScript()
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(containerBasedAnchorRestoreJS) { result, error in
                var success = false
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🎯 컨테이너 기반 앵커 복원 JS 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    success = (resultDict["success"] as? Bool) ?? false
                    
                    if let method = resultDict["method"] as? String {
                        TabPersistenceManager.debugMessages.append("🎯 앵커 복원 방법: \(method)")
                    }
                    
                    if let anchorInfo = resultDict["anchorInfo"] as? String {
                        TabPersistenceManager.debugMessages.append("🎯 사용된 앵커: \(anchorInfo)")
                    }
                    
                    if let containerType = resultDict["containerType"] as? String {
                        TabPersistenceManager.debugMessages.append("🎯 복원 컨테이너: \(containerType)")
                    }
                    
                    if let packageBased = resultDict["packageBased"] as? Bool {
                        TabPersistenceManager.debugMessages.append("🎯 4요소 패키지 기반: \(packageBased)")
                    }
                    
                    if let verification = resultDict["verification"] as? [String: Any],
                       let actualRestoreSuccess = verification["actualRestoreSuccess"] as? Bool {
                        TabPersistenceManager.debugMessages.append("🎯 실제 복원 성공: \(actualRestoreSuccess)")
                        success = actualRestoreSuccess // 실제 복원 성공 여부를 우선시
                    }
                    
                    if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                        for log in detailedLogs.prefix(3) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                }
                
                TabPersistenceManager.debugMessages.append("🎯 3단계 컨테이너 기반 앵커 복원 결과: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // ✅ **4단계: 최종 검증 및 스무스 스크롤 대응**
    private func performFinalVerificationWithSmoothScrollHandling(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("✅ 최종 검증 및 스무스 스크롤 대응 시작")
        
        let verificationJS = generateFinalVerificationWithSmoothScrollScript()
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(verificationJS) { result, error in
                var success = false
                
                if let error = error {
                    TabPersistenceManager.debugMessages.append("✅ 최종 검증 JS 오류: \(error.localizedDescription)")
                } else if let resultDict = result as? [String: Any] {
                    success = (resultDict["success"] as? Bool) ?? false
                    
                    if let withinTolerance = resultDict["withinTolerance"] as? Bool {
                        TabPersistenceManager.debugMessages.append("✅ 허용 오차 내: \(withinTolerance)")
                    }
                    
                    if let finalY = resultDict["finalY"] as? Double {
                        TabPersistenceManager.debugMessages.append("✅ 최종 Y 위치: \(String(format: "%.1f", finalY))px")
                    }
                    
                    if let diffY = resultDict["diffY"] as? Double {
                        TabPersistenceManager.debugMessages.append("✅ 목표와 최종 차이: \(String(format: "%.1f", diffY))px")
                    }
                    
                    if let fallbackApplied = resultDict["fallbackApplied"] as? Bool,
                       fallbackApplied {
                        TabPersistenceManager.debugMessages.append("🚨 오차 임계값 초과 → 최상단 풀백 적용")
                        success = true // 풀백 적용도 성공으로 간주
                    }
                    
                    if let smoothScrollHandled = resultDict["smoothScrollHandled"] as? Bool,
                       smoothScrollHandled {
                        TabPersistenceManager.debugMessages.append("🚫 스무스 스크롤 간섭 대응 완료")
                    }
                    
                    if let detailedLogs = resultDict["detailedLogs"] as? [String] {
                        for log in detailedLogs.prefix(3) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                }
                
                TabPersistenceManager.debugMessages.append("✅ 4단계 최종 검증 결과: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // ⏱️ **비동기 안정화 대기 스크립트 생성 - busy-wait 제거**
    private func generateAsyncStabilizationWaitScript(maxWaitMs: Int, minWaitMs: Int, stabilityThresholdMs: Int, checkIntervalMs: Int) -> String {
        return """
        (function() {
            return new Promise(function(resolve) {
                console.log('⏱️ 비동기 안정화 대기 시작');
                
                var startTime = Date.now();
                var maxWait = \(maxWaitMs);
                var minWait = \(minWaitMs);
                var stabilityThreshold = \(stabilityThresholdMs);
                var checkInterval = \(checkIntervalMs);
                
                var mutationCount = 0;
                var lastMutationTime = Date.now();
                var observer = null;
                
                // MutationObserver 설정
                if (typeof MutationObserver !== 'undefined') {
                    observer = new MutationObserver(function(mutations) {
                        mutationCount += mutations.length;
                        lastMutationTime = Date.now();
                    });
                    
                    observer.observe(document.body, {
                        childList: true,
                        subtree: true,
                        attributes: true,
                        characterData: true
                    });
                }
                
                // 최소 대기 시간 후 안정성 체크 시작
                setTimeout(function() {
                    var checkStability = function() {
                        var now = Date.now();
                        var elapsed = now - startTime;
                        var timeSinceLastMutation = now - lastMutationTime;
                        
                        // 안정화 조건: 일정 시간 동안 DOM 변경이 없음
                        var isStable = timeSinceLastMutation >= stabilityThreshold;
                        
                        if (isStable || elapsed >= maxWait) {
                            if (observer) observer.disconnect();
                            
                            var method = isStable ? 'stable' : 'timeout';
                            var waitedMs = elapsed;
                            
                            console.log('⏱️ 비동기 안정화 완료: ' + method + ' (' + waitedMs + 'ms)');
                            
                            resolve({
                                success: true,
                                method: method,
                                waitedMs: waitedMs,
                                mutationCount: mutationCount,
                                lastMutationTime: lastMutationTime,
                                isStable: isStable
                            });
                        } else {
                            // 다음 체크 스케줄링
                            setTimeout(checkStability, checkInterval);
                        }
                    };
                    
                    checkStability();
                }, minWait);
            });
        })()
        """
    }
    
    // ⏱️ **비동기 스크롤 완료 대기 스크립트 생성 - busy-wait 제거**
    private func generateAsyncScrollCompletionWaitScript(maxWaitMs: Int, minWaitMs: Int, scrollStabilityMs: Int, checkIntervalMs: Int) -> String {
        return """
        (function() {
            return new Promise(function(resolve) {
                console.log('⏱️ 비동기 스크롤 완료 대기 시작');
                
                var startTime = Date.now();
                var minWait = \(minWaitMs);
                var maxWait = \(maxWaitMs);
                var scrollStabilityMs = \(scrollStabilityMs);
                var checkInterval = \(checkIntervalMs);
                
                var initialScrollY = 0;
                var initialScrollX = 0;
                var lastScrollTime = Date.now();
                
                // 실제 스크롤 컨테이너 찾기
                function findMainScrollContainer() {
                    // 높은 우선순위 컨테이너들
                    var highPrioritySelectors = [
                        '[data-scroll-container]', '[data-scrollable]',
                        '.scroll-container', '.scrollable',
                        '.main-content', '.content-wrapper',
                        '.feed', '.timeline', '.list-container'
                    ];
                    
                    for (var i = 0; i < highPrioritySelectors.length; i++) {
                        var elements = document.querySelectorAll(highPrioritySelectors[i]);
                        for (var j = 0; j < elements.length; j++) {
                            var el = elements[j];
                            var style = window.getComputedStyle(el);
                            if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                el.scrollHeight > el.clientHeight) {
                                return el;
                            }
                        }
                    }
                    
                    // 일반 overflow 컨테이너 검색
                    var allElements = document.querySelectorAll('*');
                    for (var i = 0; i < allElements.length; i++) {
                        var el = allElements[i];
                        var style = window.getComputedStyle(el);
                        if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                            el.scrollHeight > el.clientHeight + 50) { // 충분한 스크롤 영역
                            return el;
                        }
                    }
                    
                    return null; // window 스크롤 사용
                }
                
                var scrollContainer = findMainScrollContainer();
                
                // 초기 스크롤 위치 기록
                if (scrollContainer) {
                    initialScrollY = scrollContainer.scrollTop;
                    initialScrollX = scrollContainer.scrollLeft;
                } else {
                    initialScrollY = window.scrollY || window.pageYOffset || 0;
                    initialScrollX = window.scrollX || window.pageXOffset || 0;
                }
                
                // 스크롤 이벤트 리스너
                var scrollHandler = function() {
                    lastScrollTime = Date.now();
                };
                
                if (scrollContainer) {
                    scrollContainer.addEventListener('scroll', scrollHandler, { passive: true });
                } else {
                    window.addEventListener('scroll', scrollHandler, { passive: true });
                }
                
                // 최소 대기 시간 후 안정성 체크 시작
                setTimeout(function() {
                    var checkScrollStability = function() {
                        var now = Date.now();
                        var elapsed = now - startTime;
                        var timeSinceLastScroll = now - lastScrollTime;
                        
                        // 현재 스크롤 위치
                        var currentScrollY, currentScrollX;
                        if (scrollContainer) {
                            currentScrollY = scrollContainer.scrollTop;
                            currentScrollX = scrollContainer.scrollLeft;
                        } else {
                            currentScrollY = window.scrollY || window.pageYOffset || 0;
                            currentScrollX = window.scrollX || window.pageXOffset || 0;
                        }
                        
                        // 스크롤 안정화 조건
                        var scrollStable = timeSinceLastScroll >= scrollStabilityMs;
                        var positionStable = Math.abs(currentScrollY - initialScrollY) < 1 && 
                                           Math.abs(currentScrollX - initialScrollX) < 1;
                        
                        if (scrollStable || elapsed >= maxWait) {
                            // 이벤트 리스너 제거
                            if (scrollContainer) {
                                scrollContainer.removeEventListener('scroll', scrollHandler);
                            } else {
                                window.removeEventListener('scroll', scrollHandler);
                            }
                            
                            var method = scrollStable ? 'scroll_stable' : 'timeout';
                            var waitedMs = elapsed;
                            
                            console.log('⏱️ 비동기 스크롤 대기 완료: ' + method + ' (' + waitedMs + 'ms)');
                            
                            resolve({
                                success: true,
                                scrollStable: scrollStable,
                                waitedMs: waitedMs,
                                finalScrollY: currentScrollY,
                                finalScrollX: currentScrollX,
                                containerType: scrollContainer ? 'element' : 'window',
                                method: method
                            });
                        } else {
                            // 다음 체크 스케줄링
                            setTimeout(checkScrollStability, checkInterval);
                        }
                    };
                    
                    checkScrollStability();
                }, minWait);
            });
        })()
        """
    }
    
    // 🔄 **스크롤 컨테이너 감지 및 데이터 프리로딩 JavaScript 생성**
    private func generateScrollContainerDetectionAndPreloadingScript() -> String {
        let targetHeight = preloadingConfig.targetContentHeight
        let maxAttempts = preloadingConfig.maxPreloadAttempts
        let batchSize = preloadingConfig.preloadBatchSize
        let enableBatchLoading = preloadingConfig.enableBatchLoading
        let enableAsyncWaiting = preloadingConfig.enableAsyncWaiting
        let asyncWaitTimeoutMs = preloadingConfig.asyncWaitTimeoutMs
        
        return """
        (function() {
            return new Promise(function(resolve) {
                try {
                    console.log('🔄 스크롤 컨테이너 감지 및 데이터 프리로딩 시작');
                    
                    var safeResult = {
                        success: false,
                        scrollContainerInfo: {},
                        preloadingResult: {},
                        detailedLogs: []
                    };
                    
                    var detailedLogs = [];
                    
                    // 🎯 **핵심: 실제 스크롤 컨테이너 감지**
                    function findMainScrollContainer() {
                        detailedLogs.push('🎯 실제 스크롤 컨테이너 감지 시작');
                        
                        // 1. 높은 우선순위 컨테이너들 (데이터 속성 기반)
                        var highPrioritySelectors = [
                            '[data-scroll-container]', '[data-scrollable]', '[data-scroll]',
                            '[data-scroll-view]', '[data-main-scroll]'
                        ];
                        
                        for (var i = 0; i < highPrioritySelectors.length; i++) {
                            var elements = document.querySelectorAll(highPrioritySelectors[i]);
                            for (var j = 0; j < elements.length; j++) {
                                var el = elements[j];
                                var style = window.getComputedStyle(el);
                                if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                    el.scrollHeight > el.clientHeight) {
                                    detailedLogs.push('우선순위 컨테이너 발견: ' + highPrioritySelectors[i]);
                                    return el;
                                }
                            }
                        }
                        
                        // 2. 일반적인 스크롤 컨테이너 클래스들
                        var commonScrollSelectors = [
                            '.scroll-container', '.scrollable', '.scroll-view',
                            '.main-content', '.content-wrapper', '.content-container',
                            '.feed', '.timeline', '.list-container', '.posts-container',
                            '.messages', '.chat-container', '.content-area'
                        ];
                        
                        for (var i = 0; i < commonScrollSelectors.length; i++) {
                            var elements = document.querySelectorAll(commonScrollSelectors[i]);
                            for (var j = 0; j < elements.length; j++) {
                                var el = elements[j];
                                var style = window.getComputedStyle(el);
                                if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                    el.scrollHeight > el.clientHeight + 50) { // 충분한 스크롤 영역
                                    detailedLogs.push('일반 컨테이너 발견: ' + commonScrollSelectors[i]);
                                    return el;
                                }
                            }
                        }
                        
                        // 3. 전체 DOM 스캔 (overflow 속성 기반)
                        detailedLogs.push('전체 DOM 스캔으로 스크롤 컨테이너 검색');
                        var allElements = document.querySelectorAll('*');
                        var candidates = [];
                        
                        for (var i = 0; i < allElements.length; i++) {
                            var el = allElements[i];
                            var style = window.getComputedStyle(el);
                            
                            if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                el.scrollHeight > el.clientHeight + 100) { // 충분한 스크롤 영역
                                
                                var scrollableHeight = el.scrollHeight - el.clientHeight;
                                candidates.push({
                                    element: el,
                                    scrollableHeight: scrollableHeight,
                                    tagName: el.tagName.toLowerCase(),
                                    className: el.className || '',
                                    id: el.id || ''
                                });
                            }
                        }
                        
                        // 스크롤 가능 높이가 가장 큰 컨테이너 선택
                        if (candidates.length > 0) {
                            candidates.sort(function(a, b) {
                                return b.scrollableHeight - a.scrollableHeight;
                            });
                            
                            var bestCandidate = candidates[0];
                            detailedLogs.push('최적 컨테이너 선택: <' + bestCandidate.tagName + '> ' + 
                                            'scrollHeight=' + bestCandidate.scrollableHeight.toFixed(0) + 'px');
                            return bestCandidate.element;
                        }
                        
                        detailedLogs.push('스크롤 컨테이너 미발견 - window 스크롤 사용');
                        return null; // window 스크롤 사용
                    }
                    
                    // 스크롤 컨테이너 감지
                    var scrollContainer = findMainScrollContainer();
                    var isWindowScroll = !scrollContainer;
                    
                    // 스크롤 정보 수집
                    var scrollInfo = {
                        hasMainScrollContainer: !isWindowScroll,
                        scrollContainerSelector: null,
                        isWindowScroll: isWindowScroll,
                        containerScrollHeight: 0,
                        containerScrollWidth: 0,
                        containerClientHeight: 0,
                        containerClientWidth: 0
                    };
                    
                    if (scrollContainer) {
                        scrollInfo.containerScrollHeight = scrollContainer.scrollHeight;
                        scrollInfo.containerScrollWidth = scrollContainer.scrollWidth;
                        scrollInfo.containerClientHeight = scrollContainer.clientHeight;
                        scrollInfo.containerClientWidth = scrollContainer.clientWidth;
                        
                        // 셀렉터 생성 시도
                        if (scrollContainer.id) {
                            scrollInfo.scrollContainerSelector = '#' + scrollContainer.id;
                        } else if (scrollContainer.className) {
                            var firstClass = scrollContainer.className.split(' ')[0];
                            scrollInfo.scrollContainerSelector = '.' + firstClass;
                        } else {
                            scrollInfo.scrollContainerSelector = scrollContainer.tagName.toLowerCase();
                        }
                        
                        detailedLogs.push('스크롤 컨테이너 정보: ' + scrollInfo.scrollContainerSelector);
                        detailedLogs.push('컨테이너 크기: ' + scrollInfo.containerScrollWidth + ' x ' + scrollInfo.containerScrollHeight);
                        detailedLogs.push('클라이언트 크기: ' + scrollInfo.containerClientWidth + ' x ' + scrollInfo.containerClientHeight);
                    } else {
                        // window 스크롤 정보
                        scrollInfo.containerScrollHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                        scrollInfo.containerScrollWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                        scrollInfo.containerClientHeight = parseFloat(window.innerHeight) || 0;
                        scrollInfo.containerClientWidth = parseFloat(window.innerWidth) || 0;
                        
                        detailedLogs.push('Window 스크롤 사용');
                        detailedLogs.push('문서 크기: ' + scrollInfo.containerScrollWidth + ' x ' + scrollInfo.containerScrollHeight);
                        detailedLogs.push('뷰포트 크기: ' + scrollInfo.containerClientWidth + ' x ' + scrollInfo.containerClientHeight);
                    }
                    
                    safeResult.scrollContainerInfo = scrollInfo;
                    
                    // 🔄 **데이터 프리로딩 실행 (스크롤 컨테이너 기반)**
                    if (\(preloadingConfig.enableDataPreloading)) {
                        detailedLogs.push('🔄 데이터 프리로딩 시작 (스크롤 컨테이너 기반)');
                        
                        var targetHeight = parseFloat('\(targetHeight)');
                        var maxAttempts = parseInt('\(maxAttempts)');
                        var batchSize = parseInt('\(batchSize)');
                        var enableBatchLoading = \(enableBatchLoading);
                        var enableAsyncWaiting = \(enableAsyncWaiting);
                        var asyncWaitTimeoutMs = parseInt('\(asyncWaitTimeoutMs)');
                        
                        var initialHeight = scrollInfo.containerScrollHeight;
                        var currentHeight = initialHeight;
                        var totalHeightIncrease = 0;
                        var loadingAttempts = 0;
                        
                        detailedLogs.push('목표 높이: ' + targetHeight.toFixed(1) + 'px');
                        detailedLogs.push('초기 높이: ' + initialHeight.toFixed(1) + 'px');
                        
                        if (initialHeight >= targetHeight * 0.95) {
                            detailedLogs.push('이미 충분한 콘텐츠 로드됨 - 프리로딩 불필요');
                            safeResult.preloadingResult = {
                                success: true,
                                reason: 'already_sufficient',
                                loadedContentHeight: initialHeight,
                                heightIncrease: 0,
                                loadingAttempts: 0
                            };
                        } else {
                            // 무한스크롤 트리거 함수 (스크롤 컨테이너 기반)
                            function triggerInfiniteScrollLoading() {
                                var triggersUsed = 0;
                                
                                // 스크롤 컨테이너의 하단으로 스크롤
                                if (scrollContainer) {
                                    var maxScrollTop = Math.max(0, scrollContainer.scrollHeight - scrollContainer.clientHeight);
                                    scrollContainer.scrollTop = maxScrollTop;
                                    detailedLogs.push('컨테이너 하단 스크롤: ' + maxScrollTop.toFixed(1) + 'px');
                                } else {
                                    var maxScrollY = Math.max(0, scrollInfo.containerScrollHeight - scrollInfo.containerClientHeight);
                                    window.scrollTo(0, maxScrollY);
                                    detailedLogs.push('윈도우 하단 스크롤: ' + maxScrollY.toFixed(1) + 'px');
                                }
                                triggersUsed++;
                                
                                // 스크롤 이벤트 발생
                                var scrollEvent = new Event('scroll', { bubbles: true });
                                if (scrollContainer) {
                                    scrollContainer.dispatchEvent(scrollEvent);
                                } else {
                                    window.dispatchEvent(scrollEvent);
                                }
                                window.dispatchEvent(new Event('resize', { bubbles: true }));
                                triggersUsed++;
                                
                                // 더보기 버튼 클릭
                                var loadMoreButtons = document.querySelectorAll(
                                    '[class*="load"], [class*="more"], .load-more, .show-more, ' +
                                    '[data-testid*="load"], .infinite-scroll-trigger, .btn-more, ' +
                                    'button[aria-label*="more"], button[aria-label*="load"]'
                                );
                                
                                for (var i = 0; i < loadMoreButtons.length; i++) {
                                    try {
                                        loadMoreButtons[i].click();
                                        triggersUsed++;
                                    } catch(e) {
                                        // 클릭 실패는 무시
                                    }
                                }
                                
                                return triggersUsed;
                            }
                            
                            // 📦 **비동기 프리로딩 실행**
                            function performAsyncPreloading() {
                                return new Promise(function(preloadResolve) {
                                    if (enableBatchLoading) {
                                        var batchIndex = 0;
                                        
                                        function processBatch() {
                                            if (batchIndex >= batchSize || loadingAttempts >= maxAttempts) {
                                                preloadResolve();
                                                return;
                                            }
                                            
                                            var beforeHeight = scrollContainer ? scrollContainer.scrollHeight : 
                                                             parseFloat(document.documentElement.scrollHeight) || 0;
                                            
                                            var triggersUsed = triggerInfiniteScrollLoading();
                                            loadingAttempts++;
                                            batchIndex++;
                                            
                                            detailedLogs.push('배치[' + batchIndex + '] 트리거: ' + triggersUsed + '개 방법 시도');
                                            
                                            // 비동기 로딩 대기
                                            if (enableAsyncWaiting) {
                                                setTimeout(function() {
                                                    var afterHeight = scrollContainer ? scrollContainer.scrollHeight : 
                                                                    parseFloat(document.documentElement.scrollHeight) || 0;
                                                    var heightDiff = afterHeight - beforeHeight;
                                                    
                                                    if (heightDiff > 0) {
                                                        totalHeightIncrease += heightDiff;
                                                        currentHeight = afterHeight;
                                                        detailedLogs.push('배치[' + batchIndex + '] 높이 증가: ' + heightDiff.toFixed(1) + 'px');
                                                    }
                                                    
                                                    if (currentHeight >= targetHeight) {
                                                        detailedLogs.push('목표 높이 달성: ' + currentHeight.toFixed(1) + 'px');
                                                        preloadResolve();
                                                        return;
                                                    }
                                                    
                                                    // 다음 배치 처리
                                                    setTimeout(processBatch, 100); // 배치 간 간격
                                                }, asyncWaitTimeoutMs / batchSize); // 배치별 대기 시간
                                            } else {
                                                // 즉시 다음 배치
                                                setTimeout(processBatch, 100);
                                            }
                                        }
                                        
                                        processBatch();
                                    } else {
                                        // 단일 로딩
                                        var triggersUsed = triggerInfiniteScrollLoading();
                                        loadingAttempts = 1;
                                        
                                        if (enableAsyncWaiting) {
                                            setTimeout(function() {
                                                var afterHeight = scrollContainer ? scrollContainer.scrollHeight : 
                                                                parseFloat(document.documentElement.scrollHeight) || 0;
                                                totalHeightIncrease = afterHeight - initialHeight;
                                                currentHeight = afterHeight;
                                                preloadResolve();
                                            }, asyncWaitTimeoutMs);
                                        } else {
                                            preloadResolve();
                                        }
                                    }
                                });
                            }
                            
                            // 비동기 프리로딩 실행
                            performAsyncPreloading().then(function() {
                                var finalHeight = scrollContainer ? scrollContainer.scrollHeight : 
                                                parseFloat(document.documentElement.scrollHeight) || 0;
                                var success = finalHeight >= targetHeight * 0.8 || totalHeightIncrease > 0;
                                
                                safeResult.preloadingResult = {
                                    success: success,
                                    reason: success ? 'preloading_success' : 'insufficient_growth',
                                    loadedContentHeight: finalHeight,
                                    heightIncrease: totalHeightIncrease,
                                    loadingAttempts: loadingAttempts
                                };
                                
                                detailedLogs.push('프리로딩 완료: ' + finalHeight.toFixed(1) + 'px');
                                detailedLogs.push('총 증가량: ' + totalHeightIncrease.toFixed(1) + 'px');
                                
                                safeResult.success = true;
                                safeResult.detailedLogs = detailedLogs;
                                resolve(safeResult);
                            });
                        }
                    } else {
                        // 프리로딩 비활성화
                        safeResult.preloadingResult = {
                            success: false,
                            reason: 'disabled',
                            loadedContentHeight: scrollInfo.containerScrollHeight,
                            heightIncrease: 0,
                            loadingAttempts: 0
                        };
                        
                        safeResult.success = true;
                        safeResult.detailedLogs = detailedLogs;
                        resolve(safeResult);
                    }
                    
                } catch(e) {
                    console.error('🔄 스크롤 컨테이너 감지 및 프리로딩 실패:', e);
                    resolve({
                        success: false,
                        error: e.message,
                        scrollContainerInfo: {},
                        preloadingResult: {},
                        detailedLogs: ['스크롤 컨테이너 감지 및 프리로딩 실패: ' + e.message]
                    });
                }
            });
        })()
        """
    }
    
    // 📊 **스크롤 컨테이너 기반 백분율 복원 JavaScript 생성**
    private func generateContainerBasedPercentageRestoreScript() -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        
        return """
        (function() {
            try {
                console.log('📊 스크롤 컨테이너 기반 백분율 복원 시작');
                
                var safeResult = {
                    success: false,
                    method: 'none',
                    containerType: 'unknown',
                    beforeHeight: 0,
                    afterHeight: 0,
                    calculatedX: 0,
                    calculatedY: 0,
                    actualX: 0,
                    actualY: 0,
                    diffX: 0,
                    diffY: 0,
                    tolerance: 50.0,
                    detailedLogs: []
                };
                
                var detailedLogs = [];
                var targetX = parseFloat('\(targetX)');
                var targetY = parseFloat('\(targetY)');
                var targetPercentX = parseFloat('\(targetPercentX)');
                var targetPercentY = parseFloat('\(targetPercentY)');
                
                detailedLogs.push('📊 스크롤 컨테이너 기반 백분율 복원 시작');
                detailedLogs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                detailedLogs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                
                // 🎯 **실제 스크롤 컨테이너 재검색**
                function findScrollContainer() {
                    var highPrioritySelectors = [
                        '[data-scroll-container]', '[data-scrollable]',
                        '.scroll-container', '.scrollable',
                        '.main-content', '.content-wrapper',
                        '.feed', '.timeline', '.list-container'
                    ];
                    
                    for (var i = 0; i < highPrioritySelectors.length; i++) {
                        var elements = document.querySelectorAll(highPrioritySelectors[i]);
                        for (var j = 0; j < elements.length; j++) {
                            var el = elements[j];
                            var style = window.getComputedStyle(el);
                            if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                el.scrollHeight > el.clientHeight) {
                                return el;
                            }
                        }
                    }
                    
                    var allElements = document.querySelectorAll('*');
                    for (var i = 0; i < allElements.length; i++) {
                        var el = allElements[i];
                        var style = window.getComputedStyle(el);
                        if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                            el.scrollHeight > el.clientHeight + 50) {
                            return el;
                        }
                    }
                    
                    return null;
                }
                
                var scrollContainer = findScrollContainer();
                var isWindowScroll = !scrollContainer;
                
                var containerInfo = {};
                var currentMaxScrollY = 0;
                var currentMaxScrollX = 0;
                
                if (scrollContainer) {
                    containerInfo = {
                        tagName: scrollContainer.tagName.toLowerCase(),
                        className: scrollContainer.className || '',
                        id: scrollContainer.id || '',
                        scrollHeight: scrollContainer.scrollHeight,
                        clientHeight: scrollContainer.clientHeight,
                        scrollWidth: scrollContainer.scrollWidth,
                        clientWidth: scrollContainer.clientWidth
                    };
                    
                    currentMaxScrollY = Math.max(0, scrollContainer.scrollHeight - scrollContainer.clientHeight);
                    currentMaxScrollX = Math.max(0, scrollContainer.scrollWidth - scrollContainer.clientWidth);
                    
                    detailedLogs.push('스크롤 컨테이너 발견: <' + containerInfo.tagName + '>');
                    detailedLogs.push('컨테이너 ID/Class: ' + (containerInfo.id || containerInfo.className || 'none'));
                    safeResult.containerType = 'element';
                } else {
                    var documentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                    var documentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                    var viewportHeight = parseFloat(window.innerHeight) || 0;
                    var viewportWidth = parseFloat(window.innerWidth) || 0;
                    
                    containerInfo = {
                        tagName: 'window',
                        scrollHeight: documentHeight,
                        clientHeight: viewportHeight,
                        scrollWidth: documentWidth,
                        clientWidth: viewportWidth
                    };
                    
                    currentMaxScrollY = Math.max(0, documentHeight - viewportHeight);
                    currentMaxScrollX = Math.max(0, documentWidth - viewportWidth);
                    
                    detailedLogs.push('Window 스크롤 사용');
                    safeResult.containerType = 'window';
                }
                
                safeResult.beforeHeight = containerInfo.scrollHeight;
                detailedLogs.push('컨테이너 크기: ' + containerInfo.scrollWidth.toFixed(0) + ' x ' + containerInfo.scrollHeight.toFixed(0));
                detailedLogs.push('클라이언트 크기: ' + containerInfo.clientWidth.toFixed(0) + ' x ' + containerInfo.clientHeight.toFixed(0));
                detailedLogs.push('최대 스크롤: X=' + currentMaxScrollX.toFixed(1) + 'px, Y=' + currentMaxScrollY.toFixed(1) + 'px');
                
                var calculatedX = 0;
                var calculatedY = 0;
                var method = 'none';
                
                // 🔧 **개선된 복원 로직 (스크롤 컨테이너 기반)**
                var hasVerticalScroll = currentMaxScrollY > 0;
                var hasHorizontalScroll = currentMaxScrollX > 0;
                
                detailedLogs.push('스크롤 가능: 세로=' + hasVerticalScroll + ', 가로=' + hasHorizontalScroll);
                
                // 🔧 **Y축 복원 (스크롤 컨테이너 기반 로직)**
                if (hasVerticalScroll) {
                    // 백분율이 저장되어 있으면 백분율 사용
                    if (targetPercentY >= 0) { // 0도 유효한 값
                        calculatedY = (targetPercentY / 100.0) * currentMaxScrollY;
                        method = 'container_percentage_y';
                        detailedLogs.push('Y축 컨테이너 백분율 복원: ' + targetPercentY.toFixed(2) + '% → ' + calculatedY.toFixed(1) + 'px');
                    } else if (targetY > 0) {
                        // 백분율이 없으면 절대값 사용 (최대값으로 제한)
                        calculatedY = Math.min(targetY, currentMaxScrollY);
                        method = 'container_absolute_y_clamped';
                        detailedLogs.push('Y축 컨테이너 절대값 복원: ' + targetY.toFixed(1) + ' → ' + calculatedY.toFixed(1) + 'px');
                    }
                } else {
                    // 스크롤 불가능한 경우
                    calculatedY = 0;
                    method = currentMaxScrollY === 0 ? 'container_no_scroll_y' : 'container_top_position';
                    detailedLogs.push('Y축 컨테이너 스크롤 불가능 - 0px 복원');
                }
                
                // 🔧 **X축 복원 (스크롤 컨테이너 기반 로직)**
                if (hasHorizontalScroll) {
                    if (targetPercentX >= 0) {
                        calculatedX = (targetPercentX / 100.0) * currentMaxScrollX;
                        detailedLogs.push('X축 컨테이너 백분율 복원: ' + targetPercentX.toFixed(2) + '% → ' + calculatedX.toFixed(1) + 'px');
                    } else if (targetX > 0) {
                        calculatedX = Math.min(targetX, currentMaxScrollX);
                        detailedLogs.push('X축 컨테이너 절대값 복원: ' + targetX.toFixed(1) + ' → ' + calculatedX.toFixed(1) + 'px');
                    }
                } else {
                    calculatedX = 0;
                    if (targetX > 0) {
                        detailedLogs.push('X축 컨테이너 스크롤 불가능 - 0px');
                    }
                }
                
                safeResult.method = method;
                safeResult.calculatedX = calculatedX;
                safeResult.calculatedY = calculatedY;
                detailedLogs.push('최종 계산 위치: X=' + calculatedX.toFixed(1) + ', Y=' + calculatedY.toFixed(1));
                
                // 🚫 **스무스 스크롤 일시 비활성화**
                var originalScrollBehavior = null;
                if (scrollContainer) {
                    originalScrollBehavior = scrollContainer.style.scrollBehavior;
                    scrollContainer.style.scrollBehavior = 'auto';
                } else {
                    originalScrollBehavior = document.documentElement.style.scrollBehavior;
                    document.documentElement.style.scrollBehavior = 'auto';
                    document.body.style.scrollBehavior = 'auto';
                }
                
                // 🎯 **스크롤 컨테이너 기반 스크롤 실행**
                if (scrollContainer) {
                    scrollContainer.scrollTop = calculatedY;
                    scrollContainer.scrollLeft = calculatedX;
                    detailedLogs.push('컨테이너 스크롤 실행: scrollTop=' + calculatedY.toFixed(1) + ', scrollLeft=' + calculatedX.toFixed(1));
                } else {
                    window.scrollTo(calculatedX, calculatedY);
                    document.documentElement.scrollTop = calculatedY;
                    document.documentElement.scrollLeft = calculatedX;
                    document.body.scrollTop = calculatedY;
                    document.body.scrollLeft = calculatedX;
                    
                    if (document.scrollingElement) {
                        document.scrollingElement.scrollTop = calculatedY;
                        document.scrollingElement.scrollLeft = calculatedX;
                    }
                    detailedLogs.push('윈도우 스크롤 실행');
                }
                
                // 스무스 스크롤 복원
                setTimeout(function() {
                    if (scrollContainer && originalScrollBehavior !== null) {
                        scrollContainer.style.scrollBehavior = originalScrollBehavior;
                    } else if (originalScrollBehavior !== null) {
                        document.documentElement.style.scrollBehavior = originalScrollBehavior;
                        document.body.style.scrollBehavior = originalScrollBehavior;
                    }
                }, 100);
                
                // 결과 확인
                var actualY, actualX;
                if (scrollContainer) {
                    actualY = parseFloat(scrollContainer.scrollTop);
                    actualX = parseFloat(scrollContainer.scrollLeft);
                } else {
                    actualY = parseFloat(window.scrollY || window.pageYOffset || 0);
                    actualX = parseFloat(window.scrollX || window.pageXOffset || 0);
                }
                
                var diffY = Math.abs(actualY - calculatedY);
                var diffX = Math.abs(actualX - calculatedX);
                var tolerance = 50.0;
                var success = diffY <= tolerance && diffX <= tolerance;
                
                // 🔧 **안전한 결과 설정**
                safeResult.success = success;
                safeResult.afterHeight = scrollContainer ? scrollContainer.scrollHeight : 
                                       parseFloat(document.documentElement.scrollHeight) || 0;
                safeResult.actualX = actualX;
                safeResult.actualY = actualY;
                safeResult.diffX = diffX;
                safeResult.diffY = diffY;
                safeResult.detailedLogs = detailedLogs;
                
                detailedLogs.push('실제 위치: X=' + actualX.toFixed(1) + ', Y=' + actualY.toFixed(1));
                detailedLogs.push('위치 차이: X=' + diffX.toFixed(1) + ', Y=' + diffY.toFixed(1));
                detailedLogs.push('허용 오차: ' + tolerance + 'px → 성공: ' + success);
                
                return safeResult;
                
            } catch(e) {
                console.error('📊 스크롤 컨테이너 기반 백분율 복원 실패:', e);
                return {
                    success: false,
                    method: 'error',
                    containerType: 'error',
                    error: e.message || 'unknown_error',
                    detailedLogs: ['스크롤 컨테이너 기반 백분율 복원 실패: ' + (e.message || 'unknown_error')]
                };
            }
        })()
        """
    }
    
    // 🎯 **스크롤 컨테이너 기반 4요소 패키지 앵커 정밀 복원 JavaScript 생성**
    private func generateContainerBasedFourElementPackageRestoreScript() -> String {
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
                var targetX = parseFloat('\(targetPos.x)');
                var targetY = parseFloat('\(targetPos.y)');
                var fourElementPackageData = \(fourElementPackageDataJSON);
                
                var safeResult = {
                    success: false,
                    method: 'none',
                    containerType: 'unknown',
                    anchorInfo: 'none',
                    packageBased: false,
                    verification: {
                        actualRestoreSuccess: false,
                        final: [0, 0],
                        target: [targetX, targetY],
                        diff: [0, 0],
                        tolerance: 30.0
                    },
                    detailedLogs: []
                };
                
                var detailedLogs = [];
                var restoredByPackage = false;
                var usedMethod = 'none';
                var anchorInfo = 'none';
                
                detailedLogs.push('🎯 스크롤 컨테이너 기반 4요소 패키지 앵커 정밀 복원 시작');
                detailedLogs.push('목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                detailedLogs.push('4요소 패키지 데이터: ' + (!!fourElementPackageData));
                
                // 🎯 **실제 스크롤 컨테이너 재검색**
                function findScrollContainer() {
                    var highPrioritySelectors = [
                        '[data-scroll-container]', '[data-scrollable]',
                        '.scroll-container', '.scrollable',
                        '.main-content', '.content-wrapper',
                        '.feed', '.timeline', '.list-container'
                    ];
                    
                    for (var i = 0; i < highPrioritySelectors.length; i++) {
                        var elements = document.querySelectorAll(highPrioritySelectors[i]);
                        for (var j = 0; j < elements.length; j++) {
                            var el = elements[j];
                            var style = window.getComputedStyle(el);
                            if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                el.scrollHeight > el.clientHeight) {
                                return el;
                            }
                        }
                    }
                    
                    var allElements = document.querySelectorAll('*');
                    for (var i = 0; i < allElements.length; i++) {
                        var el = allElements[i];
                        var style = window.getComputedStyle(el);
                        if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                            el.scrollHeight > el.clientHeight + 50) {
                            return el;
                        }
                    }
                    
                    return null;
                }
                
                var scrollContainer = findScrollContainer();
                var isWindowScroll = !scrollContainer;
                
                if (scrollContainer) {
                    detailedLogs.push('앵커 복원용 스크롤 컨테이너: <' + scrollContainer.tagName.toLowerCase() + '>');
                    safeResult.containerType = 'element';
                } else {
                    detailedLogs.push('앵커 복원용 윈도우 스크롤 사용');
                    safeResult.containerType = 'window';
                }
                
                // 🚫 **스무스 스크롤 일시 비활성화**
                var originalScrollBehavior = null;
                if (scrollContainer) {
                    originalScrollBehavior = scrollContainer.style.scrollBehavior;
                    scrollContainer.style.scrollBehavior = 'auto';
                } else {
                    originalScrollBehavior = document.documentElement.style.scrollBehavior;
                    document.documentElement.style.scrollBehavior = 'auto';
                    document.body.style.scrollBehavior = 'auto';
                }
                
                if (fourElementPackageData && fourElementPackageData.anchors && fourElementPackageData.anchors.length > 0) {
                    var anchors = fourElementPackageData.anchors;
                    
                    // 완전한 4요소 패키지 앵커 필터링
                    var completeAnchors = [];
                    for (var i = 0; i < anchors.length; i++) {
                        var anchor = anchors[i];
                        if (anchor.fourElementPackage) {
                            var pkg = anchor.fourElementPackage;
                            if (pkg.id && pkg.type && pkg.ts && pkg.kw) {
                                completeAnchors.push(anchor);
                            }
                        }
                    }
                    
                    detailedLogs.push('완전 패키지 앵커: ' + completeAnchors.length + '개');
                    
                    // 완전 패키지 앵커 순회하여 복원 시도
                    for (var i = 0; i < completeAnchors.length; i++) {
                        var anchor = completeAnchors[i];
                        var pkg = anchor.fourElementPackage;
                        
                        var foundElement = null;
                        
                        // ID 기반 검색
                        if (pkg.id && pkg.id !== 'unknown' && pkg.id.indexOf('auto_') !== 0) {
                            foundElement = document.getElementById(pkg.id);
                            
                            if (!foundElement) {
                                var dataSelectors = [
                                    '[data-id="' + pkg.id + '"]',
                                    '[data-' + pkg.type + '-id="' + pkg.id + '"]',
                                    '[data-item-id="' + pkg.id + '"]'
                                ];
                                
                                for (var j = 0; j < dataSelectors.length; j++) {
                                    try {
                                        var elements = document.querySelectorAll(dataSelectors[j]);
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
                            var allElements = document.querySelectorAll('*');
                            for (var j = 0; j < allElements.length; j++) {
                                var el = allElements[j];
                                var text = (el.textContent || '').trim();
                                if (text.indexOf(pkg.kw) !== -1 && text.length >= 10) {
                                    foundElement = el;
                                    break;
                                }
                            }
                        }
                        
                        if (foundElement) {
                            detailedLogs.push('앵커[' + i + '] 요소 발견: ' + foundElement.tagName.toLowerCase());
                            
                            // 🎯 **스크롤 컨테이너 기반 앵커 복원**
                            var elementRect = foundElement.getBoundingClientRect();
                            
                            if (scrollContainer) {
                                // 컨테이너 기준 상대 위치 계산
                                var containerRect = scrollContainer.getBoundingClientRect();
                                var relativeTop = elementRect.top - containerRect.top + scrollContainer.scrollTop;
                                var relativeLeft = elementRect.left - containerRect.left + scrollContainer.scrollLeft;
                                
                                // 오프셋 보정
                                if (anchor.offsetFromTop) {
                                    var offset = parseFloat(anchor.offsetFromTop) || 0;
                                    relativeTop -= offset;
                                }
                                
                                scrollContainer.scrollTop = relativeTop;
                                scrollContainer.scrollLeft = relativeLeft;
                                
                                detailedLogs.push('컨테이너 기준 앵커 복원: top=' + relativeTop.toFixed(1) + ', left=' + relativeLeft.toFixed(1));
                            } else {
                                // 윈도우 스크롤
                                foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                                
                                // 오프셋 보정
                                if (anchor.offsetFromTop) {
                                    var offset = parseFloat(anchor.offsetFromTop) || 0;
                                    window.scrollBy(0, -offset);
                                }
                                
                                detailedLogs.push('윈도우 기준 앵커 복원: scrollIntoView + 오프셋');
                            }
                            
                            restoredByPackage = true;
                            usedMethod = 'container_package_anchor_' + i;
                            anchorInfo = pkg.id + '_' + pkg.type;
                            
                            detailedLogs.push('앵커 복원 성공: ' + anchorInfo);
                            break;
                        }
                    }
                }
                
                if (!restoredByPackage) {
                    detailedLogs.push('앵커 복원 실패 - 컨테이너 기반 좌표 복원 시도');
                    
                    if (scrollContainer) {
                        scrollContainer.scrollTop = targetY;
                        scrollContainer.scrollLeft = targetX;
                        detailedLogs.push('컨테이너 좌표 복원: top=' + targetY.toFixed(1) + ', left=' + targetX.toFixed(1));
                    } else {
                        window.scrollTo(targetX, targetY);
                        detailedLogs.push('윈도우 좌표 복원');
                    }
                    
                    usedMethod = 'container_coordinate_fallback';
                }
                
                // 스무스 스크롤 복원
                setTimeout(function() {
                    if (scrollContainer && originalScrollBehavior !== null) {
                        scrollContainer.style.scrollBehavior = originalScrollBehavior;
                    } else if (originalScrollBehavior !== null) {
                        document.documentElement.style.scrollBehavior = originalScrollBehavior;
                        document.body.style.scrollBehavior = originalScrollBehavior;
                    }
                }, 100);
                
                // 결과 검증
                var currentY, currentX;
                if (scrollContainer) {
                    currentY = parseFloat(scrollContainer.scrollTop);
                    currentX = parseFloat(scrollContainer.scrollLeft);
                } else {
                    currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                    currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                }
                
                var diffY = Math.abs(currentY - targetY);
                var diffX = Math.abs(currentX - targetX);
                var tolerance = 30.0; // 앵커 복원은 더 정밀
                var success = diffY <= tolerance && diffX <= tolerance;
                var actualRestoreSuccess = diffY <= 50; // 실제 복원 성공 기준
                
                // 🔧 **안전한 결과 설정**
                safeResult.success = success;
                safeResult.method = usedMethod;
                safeResult.anchorInfo = anchorInfo;
                safeResult.packageBased = restoredByPackage;
                safeResult.verification.actualRestoreSuccess = actualRestoreSuccess;
                safeResult.verification.final = [currentX, currentY];
                safeResult.verification.diff = [diffX, diffY];
                safeResult.detailedLogs = detailedLogs;
                
                detailedLogs.push('앵커 복원 후: X=' + currentX.toFixed(1) + ', Y=' + currentY.toFixed(1));
                detailedLogs.push('목표와 차이: X=' + diffX.toFixed(1) + ', Y=' + diffY.toFixed(1));
                
                return safeResult;
                
            } catch(e) {
                console.error('🎯 스크롤 컨테이너 기반 앵커 복원 실패:', e);
                return {
                    success: false,
                    method: 'error',
                    containerType: 'error',
                    error: e.message || 'unknown_error',
                    packageBased: false,
                    verification: {
                        actualRestoreSuccess: false,
                        final: [0, 0],
                        target: [0, 0],
                        diff: [0, 0],
                        tolerance: 30.0
                    },
                    detailedLogs: ['스크롤 컨테이너 기반 앵커 복원 실패: ' + (e.message || 'unknown_error')]
                };
            }
        })()
        """
    }
    
    // ✅ **최종 검증 및 스무스 스크롤 대응 JavaScript 생성**
    private func generateFinalVerificationWithSmoothScrollScript() -> String {
        let targetY = scrollPosition.y
        let targetX = scrollPosition.x
        
        return """
        (function() {
            try {
                var targetX = parseFloat('\(targetX)');
                var targetY = parseFloat('\(targetY)');
                
                var safeResult = {
                    success: false,
                    withinTolerance: false,
                    fallbackApplied: false,
                    smoothScrollHandled: false,
                    finalX: 0,
                    finalY: 0,
                    diffX: 0,
                    diffY: 0,
                    toleranceThreshold: 0,
                    basicTolerance: 100.0,
                    detailedLogs: []
                };
                
                var detailedLogs = [];
                
                detailedLogs.push('✅ 최종 검증 및 스무스 스크롤 대응 시작');
                
                // 🎯 **실제 스크롤 컨테이너 재검색**
                function findScrollContainer() {
                    var highPrioritySelectors = [
                        '[data-scroll-container]', '[data-scrollable]',
                        '.scroll-container', '.scrollable',
                        '.main-content', '.content-wrapper',
                        '.feed', '.timeline', '.list-container'
                    ];
                    
                    for (var i = 0; i < highPrioritySelectors.length; i++) {
                        var elements = document.querySelectorAll(highPrioritySelectors[i]);
                        for (var j = 0; j < elements.length; j++) {
                            var el = elements[j];
                            var style = window.getComputedStyle(el);
                            if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                el.scrollHeight > el.clientHeight) {
                                return el;
                            }
                        }
                    }
                    
                    var allElements = document.querySelectorAll('*');
                    for (var i = 0; i < allElements.length; i++) {
                        var el = allElements[i];
                        var style = window.getComputedStyle(el);
                        if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                            el.scrollHeight > el.clientHeight + 50) {
                            return el;
                        }
                    }
                    
                    return null;
                }
                
                var scrollContainer = findScrollContainer();
                
                // 현재 스크롤 위치 확인
                var currentY, currentX;
                if (scrollContainer) {
                    currentY = parseFloat(scrollContainer.scrollTop);
                    currentX = parseFloat(scrollContainer.scrollLeft);
                    detailedLogs.push('최종 검증: 스크롤 컨테이너 <' + scrollContainer.tagName.toLowerCase() + '> 사용');
                } else {
                    currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                    currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                    detailedLogs.push('최종 검증: 윈도우 스크롤 사용');
                }
                
                var diffY = Math.abs(currentY - targetY);
                var diffX = Math.abs(currentX - targetX);
                
                // 🚨 **오차 임계값 설정** - 컨테이너 크기 기반
                var viewportHeight;
                if (scrollContainer) {
                    viewportHeight = parseFloat(scrollContainer.clientHeight) || 0;
                } else {
                    viewportHeight = parseFloat(window.innerHeight) || 0;
                }
                
                var toleranceThreshold = viewportHeight * 3; // 컨테이너 높이의 3배
                var basicTolerance = 100.0; // 기본 허용 오차
                
                var withinBasicTolerance = diffY <= basicTolerance && diffX <= basicTolerance;
                var exceedsThreshold = diffY > toleranceThreshold || diffX > toleranceThreshold;
                
                safeResult.toleranceThreshold = toleranceThreshold;
                detailedLogs.push('현재 위치: X=' + currentX.toFixed(1) + ', Y=' + currentY.toFixed(1));
                detailedLogs.push('목표 위치: X=' + targetX.toFixed(1) + ', Y=' + targetY.toFixed(1));
                detailedLogs.push('위치 차이: X=' + diffX.toFixed(1) + ', Y=' + diffY.toFixed(1));
                detailedLogs.push('기본 허용 오차: ' + basicTolerance + 'px');
                detailedLogs.push('풀백 임계값: ' + toleranceThreshold.toFixed(1) + 'px');
                detailedLogs.push('임계값 초과: ' + exceedsThreshold);
                
                var fallbackApplied = false;
                var smoothScrollHandled = false;
                var finalSuccess = false;
                
                // 🚫 **스무스 스크롤 간섭 대응**
                var scrollBehaviorElements = document.querySelectorAll('[style*="scroll-behavior"], .smooth-scroll');
                if (scrollBehaviorElements.length > 0 || 
                    getComputedStyle(document.documentElement).scrollBehavior === 'smooth' ||
                    getComputedStyle(document.body).scrollBehavior === 'smooth') {
                    
                    detailedLogs.push('🚫 스무스 스크롤 감지 - 일시 비활성화');
                    smoothScrollHandled = true;
                    
                    // 일시적으로 scroll-behavior 제거
                    var originalBehaviors = [];
                    for (var i = 0; i < scrollBehaviorElements.length; i++) {
                        var el = scrollBehaviorElements[i];
                        originalBehaviors.push({
                            element: el,
                            original: el.style.scrollBehavior
                        });
                        el.style.scrollBehavior = 'auto';
                    }
                    
                    if (scrollContainer) {
                        originalBehaviors.push({
                            element: scrollContainer,
                            original: scrollContainer.style.scrollBehavior
                        });
                        scrollContainer.style.scrollBehavior = 'auto';
                    }
                    
                    originalBehaviors.push({
                        element: document.documentElement,
                        original: document.documentElement.style.scrollBehavior
                    });
                    document.documentElement.style.scrollBehavior = 'auto';
                    
                    // 강제 재스크롤
                    if (scrollContainer) {
                        scrollContainer.scrollTop = targetY;
                        scrollContainer.scrollLeft = targetX;
                    } else {
                        window.scrollTo(targetX, targetY);
                    }
                    
                    // 복원 (비동기)
                    setTimeout(function() {
                        for (var i = 0; i < originalBehaviors.length; i++) {
                            var item = originalBehaviors[i];
                            if (item.original) {
                                item.element.style.scrollBehavior = item.original;
                            }
                        }
                    }, 200);
                    
                    // 재측정
                    if (scrollContainer) {
                        currentY = parseFloat(scrollContainer.scrollTop);
                        currentX = parseFloat(scrollContainer.scrollLeft);
                    } else {
                        currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                    }
                    
                    diffY = Math.abs(currentY - targetY);
                    diffX = Math.abs(currentX - targetX);
                    withinBasicTolerance = diffY <= basicTolerance && diffX <= basicTolerance;
                    exceedsThreshold = diffY > toleranceThreshold || diffX > toleranceThreshold;
                    
                    detailedLogs.push('스무스 스크롤 대응 후: X=' + currentX.toFixed(1) + ', Y=' + currentY.toFixed(1));
                    detailedLogs.push('대응 후 차이: X=' + diffX.toFixed(1) + ', Y=' + diffY.toFixed(1));
                }
                
                if (withinBasicTolerance) {
                    detailedLogs.push('기본 허용 오차 내 - 복원 성공');
                    finalSuccess = true;
                } else if (exceedsThreshold) {
                    detailedLogs.push('🚨 오차 임계값 초과 - 최상단 풀백 실행');
                    
                    // 최상단으로 풀백
                    if (scrollContainer) {
                        scrollContainer.scrollTop = 0;
                        scrollContainer.scrollLeft = 0;
                    } else {
                        window.scrollTo(0, 0);
                        document.documentElement.scrollTop = 0;
                        document.documentElement.scrollLeft = 0;
                        document.body.scrollTop = 0;
                        document.body.scrollLeft = 0;
                        
                        if (document.scrollingElement) {
                            document.scrollingElement.scrollTop = 0;
                            document.scrollingElement.scrollLeft = 0;
                        }
                    }
                    
                    fallbackApplied = true;
                    finalSuccess = true; // 풀백도 성공으로 간주
                    detailedLogs.push('최상단 풀백 완료');
                } else {
                    detailedLogs.push('기본 허용 오차는 초과했지만 임계값 내 - 현재 위치 유지');
                    finalSuccess = diffY <= basicTolerance * 2; // 2배까지는 허용
                }
                
                // 최종 위치 재측정
                var finalY, finalX;
                if (scrollContainer) {
                    finalY = parseFloat(scrollContainer.scrollTop);
                    finalX = parseFloat(scrollContainer.scrollLeft);
                } else {
                    finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                    finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                }
                
                var finalDiffY = Math.abs(finalY - targetY);
                var finalDiffX = Math.abs(finalX - targetX);
                
                // 🔧 **안전한 결과 설정**
                safeResult.success = finalSuccess;
                safeResult.withinTolerance = withinBasicTolerance;
                safeResult.fallbackApplied = fallbackApplied;
                safeResult.smoothScrollHandled = smoothScrollHandled;
                safeResult.finalX = finalX;
                safeResult.finalY = finalY;
                safeResult.diffX = finalDiffX;
                safeResult.diffY = finalDiffY;
                safeResult.detailedLogs = detailedLogs;
                
                detailedLogs.push('최종 위치: X=' + finalX.toFixed(1) + ', Y=' + finalY.toFixed(1));
                detailedLogs.push('최종 차이: X=' + finalDiffX.toFixed(1) + ', Y=' + finalDiffY.toFixed(1));
                
                return safeResult;
                
            } catch(e) {
                console.error('✅ 최종 검증 및 스무스 스크롤 대응 실패:', e);
                return {
                    success: false,
                    error: e.message || 'unknown_error',
                    fallbackApplied: false,
                    smoothScrollHandled: false,
                    detailedLogs: ['최종 검증 및 스무스 스크롤 대응 실패: ' + (e.message || 'unknown_error')]
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
        
        // 📊 **스크롤 컨테이너 정보 캡처**
        var scrollContainerInfo = BFCacheSnapshot.ScrollContainerInfo.default
        
        // 스크롤 컨테이너 감지 JavaScript 실행
        let containerDetectionSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let containerDetectionScript = """
            (function() {
                try {
                    // 🎯 **스크롤 컨테이너 감지**
                    function findMainScrollContainer() {
                        var highPrioritySelectors = [
                            '[data-scroll-container]', '[data-scrollable]',
                            '.scroll-container', '.scrollable',
                            '.main-content', '.content-wrapper',
                            '.feed', '.timeline', '.list-container'
                        ];
                        
                        for (var i = 0; i < highPrioritySelectors.length; i++) {
                            var elements = document.querySelectorAll(highPrioritySelectors[i]);
                            for (var j = 0; j < elements.length; j++) {
                                var el = elements[j];
                                var style = window.getComputedStyle(el);
                                if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                    el.scrollHeight > el.clientHeight) {
                                    return el;
                                }
                            }
                        }
                        
                        var allElements = document.querySelectorAll('*');
                        for (var i = 0; i < allElements.length; i++) {
                            var el = allElements[i];
                            var style = window.getComputedStyle(el);
                            if ((style.overflowY === 'auto' || style.overflowY === 'scroll') && 
                                el.scrollHeight > el.clientHeight + 50) {
                                return el;
                            }
                        }
                        
                        return null;
                    }
                    
                    var scrollContainer = findMainScrollContainer();
                    var isWindowScroll = !scrollContainer;
                    
                    if (scrollContainer) {
                        var selector = null;
                        if (scrollContainer.id) {
                            selector = '#' + scrollContainer.id;
                        } else if (scrollContainer.className) {
                            var firstClass = scrollContainer.className.split(' ')[0];
                            selector = '.' + firstClass;
                        } else {
                            selector = scrollContainer.tagName.toLowerCase();
                        }
                        
                        return {
                            hasMainScrollContainer: true,
                            scrollContainerSelector: selector,
                            isWindowScroll: false,
                            containerScrollHeight: scrollContainer.scrollHeight,
                            containerScrollWidth: scrollContainer.scrollWidth,
                            containerClientHeight: scrollContainer.clientHeight,
                            containerClientWidth: scrollContainer.clientWidth
                        };
                    } else {
                        return {
                            hasMainScrollContainer: false,
                            scrollContainerSelector: null,
                            isWindowScroll: true,
                            containerScrollHeight: document.documentElement.scrollHeight || 0,
                            containerScrollWidth: document.documentElement.scrollWidth || 0,
                            containerClientHeight: window.innerHeight || 0,
                            containerClientWidth: window.innerWidth || 0
                        };
                    }
                } catch(e) {
                    return {
                        hasMainScrollContainer: false,
                        scrollContainerSelector: null,
                        isWindowScroll: true,
                        containerScrollHeight: 0,
                        containerScrollWidth: 0,
                        containerClientHeight: 0,
                        containerClientWidth: 0
                    };
                }
            })()
            """
            
            webView.evaluateJavaScript(containerDetectionScript) { result, error in
                if let containerData = result as? [String: Any] {
                    scrollContainerInfo = BFCacheSnapshot.ScrollContainerInfo(
                        hasMainScrollContainer: (containerData["hasMainScrollContainer"] as? Bool) ?? false,
                        scrollContainerSelector: containerData["scrollContainerSelector"] as? String,
                        isWindowScroll: (containerData["isWindowScroll"] as? Bool) ?? true,
                        containerScrollHeight: CGFloat((containerData["containerScrollHeight"] as? Double) ?? 0),
                        containerScrollWidth: CGFloat((containerData["containerScrollWidth"] as? Double) ?? 0),
                        containerClientHeight: CGFloat((containerData["containerClientHeight"] as? Double) ?? 0),
                        containerClientWidth: CGFloat((containerData["containerClientWidth"] as? Double) ?? 0)
                    )
                    
                    TabPersistenceManager.debugMessages.append("🎯 스크롤 컨테이너 캡처: \(scrollContainerInfo.hasMainScrollContainer ? "감지됨" : "미감지")")
                }
                containerDetectionSemaphore.signal()
            }
        }
        _ = containerDetectionSemaphore.wait(timeout: .now() + 1.0)
        
        // 📱 **개선된 백분율 계산 로직 (스크롤 컨테이너 기반)**
        let scrollPercent: CGPoint
        let maxScrollY: CGFloat
        let maxScrollX: CGFloat
        
        if scrollContainerInfo.hasMainScrollContainer && !scrollContainerInfo.isWindowScroll {
            // 스크롤 컨테이너 기반 계산
            maxScrollY = max(0, scrollContainerInfo.containerScrollHeight - scrollContainerInfo.containerClientHeight)
            maxScrollX = max(0, scrollContainerInfo.containerScrollWidth - scrollContainerInfo.containerClientWidth)
        } else {
            // 윈도우 스크롤 기반 계산
            maxScrollY = max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height)
            maxScrollX = max(0, captureData.actualScrollableSize.width - captureData.viewportSize.width)
        }
        
        // 🔧 **백분율 계산 수정 - 스크롤 가능한 경우에만 계산**
        if maxScrollY > 0 || maxScrollX > 0 {
            scrollPercent = CGPoint(
                x: maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            // 스크롤 불가능한 페이지는 백분율 0
            scrollPercent = CGPoint.zero
        }
        
        TabPersistenceManager.debugMessages.append("📊 캡처 완료: 위치=(\(String(format: "%.1f", captureData.scrollPosition.x)), \(String(format: "%.1f", captureData.scrollPosition.y))), 백분율=(\(String(format: "%.2f", scrollPercent.x))%, \(String(format: "%.2f", scrollPercent.y))%)")
        TabPersistenceManager.debugMessages.append("📱 최대 스크롤: X=\(String(format: "%.1f", maxScrollX))px, Y=\(String(format: "%.1f", maxScrollY))px")
        TabPersistenceManager.debugMessages.append("🎯 컨테이너 기반: \(!scrollContainerInfo.isWindowScroll)")
        
        // 🔄 **프리로딩 설정 생성 (스크롤 컨테이너 기반 높이)**
        let targetHeight = scrollContainerInfo.hasMainScrollContainer ? 
                          scrollContainerInfo.containerScrollHeight : 
                          max(captureData.actualScrollableSize.height, captureData.contentSize.height)
        
        let preloadingConfig = BFCacheSnapshot.PreloadingConfig(
            enableDataPreloading: true,
            enableBatchLoading: true, 
            targetContentHeight: targetHeight,
            maxPreloadAttempts: 10,
            preloadBatchSize: 5,
            preloadTimeoutSeconds: 30,
            enableAsyncWaiting: true,
            asyncWaitTimeoutMs: 2000
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
            preloadingConfig: preloadingConfig,
            scrollContainerInfo: scrollContainerInfo
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 👁️ **개선: 보이는 요소만 캡처하는 4요소 패키지 JavaScript 생성 - WKWebView 직렬화 안전 버전**
    private func generateVisibleOnlyFourElementPackageCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('👁️ 보이는 요소만 4요소 패키지 캡처 시작');
                
                // 📊 **WKWebView 직렬화 안전 결과 객체 (기본 타입만 사용)**
                var safeResult = {
                    fourElementPackageAnchors: {
                        anchors: [],
                        stats: {}
                    },
                    scroll: { 
                        x: parseFloat(window.scrollX || window.pageXOffset) || 0, 
                        y: parseFloat(window.scrollY || window.pageYOffset) || 0
                    },
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now(),
                    userAgent: navigator.userAgent,
                    viewport: {
                        width: parseFloat(window.innerWidth) || 0,
                        height: parseFloat(window.innerHeight) || 0
                    },
                    content: {
                        width: parseFloat(document.documentElement.scrollWidth) || 0,
                        height: parseFloat(document.documentElement.scrollHeight) || 0
                    },
                    actualScrollable: { 
                        width: 0,
                        height: 0
                    },
                    actualViewportRect: {},
                    detailedLogs: [],
                    captureStats: {},
                    pageAnalysis: {},
                    captureTime: 0
                };
                
                var detailedLogs = [];
                var captureStats = {};
                var pageAnalysis = {};
                
                // 기본 정보 수집
                var scrollY = safeResult.scroll.y;
                var scrollX = safeResult.scroll.x;
                var viewportHeight = safeResult.viewport.height;
                var viewportWidth = safeResult.viewport.width;
                var contentHeight = safeResult.content.height;
                var contentWidth = safeResult.content.width;
                
                // 실제 스크롤 가능 크기 계산
                safeResult.actualScrollable.width = Math.max(contentWidth, viewportWidth);
                safeResult.actualScrollable.height = Math.max(contentHeight, viewportHeight);
                
                detailedLogs.push('👁️ 보이는 요소만 4요소 패키지 캡처 시작');
                detailedLogs.push('스크롤 위치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포트 크기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                // 👁️ **핵심: 실제 보이는 영역 계산 (정확한 뷰포트)**
                var actualViewportRect = {
                    top: scrollY,
                    left: scrollX,
                    bottom: scrollY + viewportHeight,
                    right: scrollX + viewportWidth,
                    width: viewportWidth,
                    height: viewportHeight
                };
                
                // WKWebView 직렬화를 위해 기본 타입으로 변환
                safeResult.actualViewportRect = {
                    top: actualViewportRect.top,
                    left: actualViewportRect.left,
                    bottom: actualViewportRect.bottom,
                    right: actualViewportRect.right,
                    width: actualViewportRect.width,
                    height: actualViewportRect.height
                };
                
                detailedLogs.push('실제 보이는 영역: top=' + actualViewportRect.top.toFixed(1) + ', bottom=' + actualViewportRect.bottom.toFixed(1));
                
                // 👁️ **요소 가시성 정확 판단 함수**
                function isElementActuallyVisible(element, strictMode) {
                    if (strictMode === undefined) strictMode = true;
                    
                    try {
                        // 1. 기본 DOM 연결 확인
                        if (!element || !element.getBoundingClientRect) return { visible: false, reason: 'invalid_element' };
                        
                        // 2. DOM 트리 연결 확인
                        if (!document.contains(element)) return { visible: false, reason: 'not_in_dom' };
                        
                        // 3. 요소 크기 확인
                        var rect = element.getBoundingClientRect();
                        if (rect.width === 0 || rect.height === 0) return { visible: false, reason: 'zero_size' };
                        
                        // 4. 뷰포트와 겹침 확인 (정확한 계산)
                        var elementTop = scrollY + rect.top;
                        var elementBottom = scrollY + rect.bottom;
                        var elementLeft = scrollX + rect.left;
                        var elementRight = scrollX + rect.right;
                        
                        // 👁️ **엄격한 뷰포트 겹침 판단**
                        var isInViewportVertically = elementBottom > actualViewportRect.top && elementTop < actualViewportRect.bottom;
                        var isInViewportHorizontally = elementRight > actualViewportRect.left && elementLeft < actualViewportRect.right;
                        
                        if (strictMode && (!isInViewportVertically || !isInViewportHorizontally)) {
                            return { visible: false, reason: 'outside_viewport', rect: rect };
                        }
                        
                        // 5. CSS visibility, display 확인
                        var computedStyle = window.getComputedStyle(element);
                        if (computedStyle.display === 'none') return { visible: false, reason: 'display_none' };
                        if (computedStyle.visibility === 'hidden') return { visible: false, reason: 'visibility_hidden' };
                        if (computedStyle.opacity === '0') return { visible: false, reason: 'opacity_zero' };
                        
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
                    
                    var cleanText = text.trim();
                    if (cleanText.length < 5) return false; // 너무 짧은 텍스트
                    
                    // 🧹 **의미없는 텍스트 패턴들**
                    var meaninglessPatterns = [
                        /^(투표는|표시되지|않습니다|네트워크|문제로|연결되지|잠시|후에|다시|시도)/,
                        /^(로딩|loading|wait|please|기다려|잠시만)/i,
                        /^(오류|에러|error|fail|실패|죄송|sorry)/i,
                        /^(확인|ok|yes|no|취소|cancel|닫기|close)/i,
                        /^(더보기|more|load|next|이전|prev|previous)/i,
                        /^(클릭|click|tap|터치|touch|선택)/i,
                        /^(답글|댓글|reply|comment|쓰기|작성)/i,
                        /^[\\s\\.\\-_=+]{2,}$/, // 특수문자만
                        /^[0-9\\s\\.\\/\\-:]{3,}$/, // 숫자와 특수문자만
                        /^(am|pm|오전|오후|시|분|초)$/i,
                    ];
                    
                    for (var i = 0; i < meaninglessPatterns.length; i++) {
                        var pattern = meaninglessPatterns[i];
                        if (pattern.test(cleanText)) {
                            return false;
                        }
                    }
                    
                    return true;
                }
                
                // 👁️ **핵심 개선: 보이는 요소만 4요소 패키지 앵커 수집**
                function collectVisibleFourElementPackageAnchors() {
                    var anchors = [];
                    var visibilityStats = {
                        totalCandidates: 0,
                        visibilityChecked: 0,
                        actuallyVisible: 0,
                        qualityFiltered: 0,
                        finalAnchors: 0
                    };
                    
                    detailedLogs.push('👁️ 보이는 뷰포트 영역: ' + actualViewportRect.top.toFixed(1) + ' ~ ' + actualViewportRect.bottom.toFixed(1) + 'px');
                    
                    // 👁️ **범용 콘텐츠 요소 패턴 (보이는 것만 선별)**
                    var contentSelectors = [
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
                    
                    var candidateElements = [];
                    var selectorStats = {};
                    
                    detailedLogs.push('총 ' + contentSelectors.length + '개 selector 패턴으로 후보 요소 수집 시작');
                    
                    // 모든 selector에서 요소 수집
                    for (var i = 0; i < contentSelectors.length; i++) {
                        var selector = contentSelectors[i];
                        try {
                            var elements = document.querySelectorAll(selector);
                            if (elements.length > 0) {
                                selectorStats[selector] = elements.length;
                                for (var j = 0; j < elements.length; j++) {
                                    candidateElements.push(elements[j]);
                                }
                            }
                        } catch(e) {
                            selectorStats[selector] = 'error: ' + e.message;
                        }
                    }
                    
                    visibilityStats.totalCandidates = candidateElements.length;
                    
                    detailedLogs.push('후보 요소 수집 완료: ' + candidateElements.length + '개');
                    
                    // 👁️ **핵심 개선: 실제로 보이는 요소만 필터링 (엄격 모드)**
                    var visibleElements = [];
                    var processingErrors = 0;
                    
                    for (var i = 0; i < candidateElements.length; i++) {
                        var element = candidateElements[i];
                        try {
                            var visibilityResult = isElementActuallyVisible(element, true); // 엄격 모드
                            visibilityStats.visibilityChecked++;
                            
                            if (visibilityResult.visible) {
                                // 👁️ **품질 텍스트 추가 검증**
                                var elementText = (element.textContent || '').trim();
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
                    
                    detailedLogs.push('가시성 검사 완료: ' + visibilityStats.visibilityChecked + '개 검사, ' + visibilityStats.actuallyVisible + '개 실제 보임');
                    detailedLogs.push('품질 필터링 후 최종: ' + visibleElements.length + '개 (오류: ' + processingErrors + '개)');
                    
                    // 👁️ **뷰포트 중심에서 가까운 순으로 정렬하여 상위 20개 선택**
                    var viewportCenterY = scrollY + (viewportHeight / 2);
                    var viewportCenterX = scrollX + (viewportWidth / 2);
                    
                    visibleElements.sort(function(a, b) {
                        var aCenterY = a.absoluteTop + (a.rect.height / 2);
                        var aCenterX = a.absoluteLeft + (a.rect.width / 2);
                        var bCenterY = b.absoluteTop + (b.rect.height / 2);
                        var bCenterX = b.absoluteLeft + (b.rect.width / 2);
                        
                        var aDistance = Math.sqrt(Math.pow(aCenterX - viewportCenterX, 2) + Math.pow(aCenterY - viewportCenterY, 2));
                        var bDistance = Math.sqrt(Math.pow(bCenterX - viewportCenterX, 2) + Math.pow(bCenterY - viewportCenterY, 2));
                        
                        return aDistance - bDistance;
                    });
                    
                    var selectedElements = visibleElements.slice(0, 20); // 👁️ 20개로 제한
                    visibilityStats.finalAnchors = selectedElements.length;
                    
                    detailedLogs.push('뷰포트 중심 기준 정렬 후 상위 ' + selectedElements.length + '개 선택');
                    detailedLogs.push('뷰포트 중심: X=' + viewportCenterX.toFixed(1) + 'px, Y=' + viewportCenterY.toFixed(1) + 'px');
                    
                    // 각 선택된 요소에 대해 4요소 패키지 정보 수집
                    var anchorCreationErrors = 0;
                    for (var i = 0; i < selectedElements.length; i++) {
                        try {
                            var anchor = createFourElementPackageAnchor(selectedElements[i], i, true);
                            if (anchor) {
                                anchors.push(anchor);
                            }
                        } catch(e) {
                            anchorCreationErrors++;
                        }
                    }
                    
                    // 📊 **WKWebView 안전 통계 객체**
                    var safeStats = {
                        selectorStats: selectorStats,
                        visibilityStats: visibilityStats,
                        processingErrors: processingErrors,
                        anchorCreationErrors: anchorCreationErrors,
                        finalAnchors: anchors.length,
                        captureTime: 0
                    };
                    
                    detailedLogs.push('보이는 4요소 패키지 앵커 생성 완료: ' + anchors.length + '개 (실패: ' + anchorCreationErrors + '개)');
                    
                    return {
                        anchors: anchors,
                        stats: safeStats
                    };
                }
                
                // 👁️ **개별 보이는 4요소 패키지 앵커 생성 (WKWebView 직렬화 안전 버전)**
                function createFourElementPackageAnchor(elementData, index, includeVisibility) {
                    if (includeVisibility === undefined) includeVisibility = true;
                    
                    try {
                        var element = elementData.element;
                        var rect = elementData.rect;
                        var absoluteTop = elementData.absoluteTop;
                        var absoluteLeft = elementData.absoluteLeft;
                        var textContent = elementData.textContent;
                        var visibilityResult = elementData.visibilityResult;
                        
                        // 뷰포트 기준 오프셋 계산
                        var offsetFromTop = scrollY - absoluteTop;
                        var offsetFromLeft = scrollX - absoluteLeft;
                        
                        detailedLogs.push('👁️ 보이는 앵커[' + index + '] 생성: 위치 Y=' + absoluteTop.toFixed(1) + 'px, 오프셋=' + offsetFromTop.toFixed(1) + 'px');
                        
                        // 🧹 **품질 텍스트 재확인**
                        if (!isQualityText(textContent)) {
                            detailedLogs.push('   👁️ 앵커[' + index + '] 품질 텍스트 검증 실패: "' + textContent.substring(0, 30) + '"');
                            return null;
                        }
                        
                        // 🎯 **4요소 패키지 생성: {id, type, ts, kw}**
                        var fourElementPackage = {};
                        var packageScore = 0; // 패키지 완성도 점수
                        
                        // ① **고유 식별자 (id) - 최우선**
                        var uniqueId = null;
                        
                        // ID 속성
                        if (element.id) {
                            uniqueId = element.id;
                            packageScore += 20;
                        }
                        
                        // data-* 속성들 (고유 식별자용)
                        if (!uniqueId) {
                            var dataAttrs = ['data-id', 'data-post-id', 'data-article-id', 
                                             'data-comment-id', 'data-item-id', 'data-key', 
                                             'data-user-id', 'data-thread-id'];
                            for (var i = 0; i < dataAttrs.length; i++) {
                                var attr = dataAttrs[i];
                                var value = element.getAttribute(attr);
                                if (value) {
                                    uniqueId = value;
                                    packageScore += 18;
                                    break;
                                }
                            }
                        }
                        
                        // href에서 ID 추출
                        if (!uniqueId) {
                            var linkElement = element.querySelector('a[href]') || (element.tagName === 'A' ? element : null);
                            if (linkElement && linkElement.href) {
                                try {
                                    var url = new URL(linkElement.href);
                                    var urlParams = url.searchParams;
                                    var paramEntries = Array.from(urlParams.entries());
                                    for (var i = 0; i < paramEntries.length; i++) {
                                        var key = paramEntries[i][0];
                                        var value = paramEntries[i][1];
                                        if (key.indexOf('id') !== -1 || key.indexOf('post') !== -1 || key.indexOf('article') !== -1) {
                                            uniqueId = value;
                                            packageScore += 15;
                                            break;
                                        }
                                    }
                                    // 직접 ID 패턴 추출
                                    if (!uniqueId && linkElement.href.indexOf('id=') !== -1) {
                                        var match = linkElement.href.match(/id=([^&]+)/);
                                        if (match) {
                                            uniqueId = match[1];
                                            packageScore += 12;
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
                        }
                        
                        fourElementPackage.id = uniqueId;
                        
                        // ② **콘텐츠 타입 (type)**
                        var contentType = 'unknown';
                        var tagName = element.tagName.toLowerCase();
                        var className = (element.className || '').toLowerCase();
                        var parentClassName = (element.parentElement && element.parentElement.className || '').toLowerCase();
                        
                        // 클래스명/태그명 기반 타입 추론
                        if (className.indexOf('comment') !== -1 || className.indexOf('reply') !== -1) {
                            contentType = 'comment';
                            packageScore += 15;
                        } else if (className.indexOf('post') !== -1 || className.indexOf('article') !== -1) {
                            contentType = 'post';
                            packageScore += 15;
                        } else if (className.indexOf('review') !== -1 || className.indexOf('rating') !== -1) {
                            contentType = 'review'; 
                            packageScore += 15;
                        } else if (tagName === 'article') {
                            contentType = 'article';
                            packageScore += 12;
                        } else if (tagName === 'li' && (parentClassName.indexOf('list') !== -1 || parentClassName.indexOf('feed') !== -1)) {
                            contentType = 'item';
                            packageScore += 10;
                        } else if (className.indexOf('card') !== -1 || className.indexOf('item') !== -1) {
                            contentType = 'item';
                            packageScore += 8;
                        } else {
                            contentType = tagName; // 태그명을 타입으로
                            packageScore += 3;
                        }
                        
                        fourElementPackage.type = contentType;
                        
                        // ③ **타임스탬프 (ts)**
                        var timestamp = null;
                        
                        // 시간 정보 추출 시도
                        var timeElement = element.querySelector('time') || 
                                          element.querySelector('[datetime]') ||
                                          element.querySelector('.time, .date, .timestamp');
                        
                        if (timeElement) {
                            var datetime = timeElement.getAttribute('datetime') || timeElement.textContent;
                            if (datetime) {
                                timestamp = datetime.trim();
                                packageScore += 15;
                            }
                        }
                        
                        // 텍스트에서 시간 패턴 추출
                        if (!timestamp) {
                            var timePatterns = [
                                /\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}/, // ISO8601
                                /\\d{4}년\\s*\\d{1,2}월\\s*\\d{1,2}일/, // 한국어 날짜
                                /\\d{1,2}:\\d{2}/, // 시:분
                                /\\d{4}-\\d{2}-\\d{2}/, // YYYY-MM-DD
                                /\\d{1,2}시간?\\s*전/, // N시간 전
                                /\\d{1,2}일\\s*전/ // N일 전
                            ];
                            
                            for (var i = 0; i < timePatterns.length; i++) {
                                var pattern = timePatterns[i];
                                var match = textContent.match(pattern);
                                if (match) {
                                    timestamp = match[0];
                                    packageScore += 10;
                                    break;
                                }
                            }
                        }
                        
                        // 현재 시간으로 대체 (최후 수단)
                        if (!timestamp) {
                            timestamp = new Date().toISOString();
                            packageScore += 2;
                        }
                        
                        fourElementPackage.ts = timestamp;
                        
                        // ④ **컨텍스트 키워드 (kw)**
                        var keywords = '';
                        
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
                            var titleAttr = element.getAttribute('title') || 
                                            element.getAttribute('alt') ||
                                            element.getAttribute('aria-label');
                            if (titleAttr) {
                                keywords = titleAttr.substring(0, 20);
                                packageScore += 5;
                            }
                        }
                        
                        // 클래스명을 키워드로 (최후 수단)
                        if (!keywords && className) {
                            keywords = className.split(' ')[0].substring(0, 15);
                            packageScore += 2;
                        }
                        
                        fourElementPackage.kw = keywords || 'unknown';
                        
                        // 📊 **품질 점수 계산 (보이는 요소는 50점 이상 필요)**
                        var qualityScore = packageScore;
                        
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
                        if (uniqueId && uniqueId.indexOf('auto_') !== 0) qualityScore += 10; // 실제 고유 ID
                        
                        // 타입 정확도 보너스  
                        if (contentType !== 'unknown' && contentType !== tagName) qualityScore += 5; // 정확한 타입 추론
                        
                        // 시간 정보 보너스
                        if (timestamp && timestamp.indexOf(new Date().toISOString().split('T')[0]) === -1) qualityScore += 5; // 실제 시간
                        
                        detailedLogs.push('   👁️ 앵커[' + index + '] 품질점수: ' + qualityScore + '점 (패키지=' + packageScore + ', 보너스=' + (qualityScore-packageScore) + ')');
                        
                        // 👁️ **보이는 요소는 품질 점수 50점 미만 제외**
                        if (qualityScore < 50) {
                            detailedLogs.push('   👁️ 앵커[' + index + '] 품질점수 부족으로 제외: ' + qualityScore + '점 < 50점');
                            return null;
                        }
                        
                        // 🚫 **WKWebView 직렬화 안전: DOM 요소 대신 기본 타입만 반환**
                        var safeAnchorData = {
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
                            safeAnchorData.isVisible = visibilityResult.visible;
                            safeAnchorData.visibilityReason = visibilityResult.reason;
                            safeAnchorData.visibilityDetails = {
                                inViewport: visibilityResult.inViewport,
                                elementRect: {
                                    width: rect.width,
                                    height: rect.height,
                                    top: rect.top,
                                    left: rect.left
                                },
                                actualViewportRect: safeResult.actualViewportRect
                            };
                        }
                        
                        return safeAnchorData;
                        
                    } catch(e) {
                        console.error('👁️ 보이는 4요소 패키지 앵커[' + index + '] 생성 실패:', e);
                        detailedLogs.push('  👁️ 앵커[' + index + '] 생성 실패: ' + e.message);
                        return null;
                    }
                }
                
                // 👁️ **메인 실행 - 보이는 요소만 4요소 패키지 데이터 수집**
                var startTime = Date.now();
                var packageAnchorsData = collectVisibleFourElementPackageAnchors();
                var endTime = Date.now();
                var captureTime = endTime - startTime;
                
                // 📊 **최종 결과 설정 (WKWebView 직렬화 안전)**
                safeResult.fourElementPackageAnchors = packageAnchorsData; // 🎯 **보이는 요소만 4요소 패키지 데이터**
                safeResult.detailedLogs = detailedLogs;                     // 📊 **상세 로그 배열**
                safeResult.captureStats = packageAnchorsData.stats;         // 📊 **캡처 통계**
                safeResult.pageAnalysis = pageAnalysis;                     // 📊 **페이지 분석 결과**
                safeResult.captureTime = captureTime;                       // 📊 **캡처 소요 시간**
                
                detailedLogs.push('=== 보이는 요소만 4요소 패키지 캡처 완료 (' + captureTime + 'ms) ===');
                detailedLogs.push('최종 보이는 4요소 패키지 앵커: ' + packageAnchorsData.anchors.length + '개');
                detailedLogs.push('처리 성능: ' + (packageAnchorsData.anchors.length > 0 ? (packageAnchorsData.anchors.length / (captureTime / 1000)).toFixed(2) : 0) + ' 앵커/초');
                
                console.log('👁️ 보이는 요소만 4요소 패키지 캡처 완료:', {
                    visiblePackageAnchorsCount: packageAnchorsData.anchors.length,
                    captureTime: captureTime
                });
                
                return safeResult;
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
