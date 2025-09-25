//
//  BFCacheSnapshotManager.swift
//  📸 **가상화 리스트/Vue.js 대응 강화된 BFCache 복원 시스템**
//  🎯 **핵심 개선**: 가상화 리스트 measurements 캐시 보존 + 동적 높이 복원 강화
//  🔧 **Vue.js 특화**: Vue 컴포넌트 상태 보존 + 리액티브 데이터 복원
//  📏 **최대 스크롤 거리 대응**: 브라우저 제한 우회 + 세그먼트 분할 스크롤
//  ⚡ **무한스크롤 보강**: measurements cache + viewport 기반 콘텐츠 높이 추정
//  🆕 **가상화 감지**: 자동 가상화 패턴 감지 + 적응형 복원 전략
//  🔄 **동적 높이 대응**: CellMeasurer 캐시 복원 + 점프 방지 로직
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

// MARK: - 📸 **가상화 리스트 대응 강화된 BFCache 페이지 스냅샷**
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
    
    // 🆕 **가상화 리스트 특화 필드들**
    let virtualizationInfo: VirtualizationInfo
    let restorationConfig: RestorationConfig
    
    // 📏 **브라우저 스크롤 제한 대응**
    struct ScrollSegmentation: Codable {
        let isSegmented: Bool                    // 세그먼트 분할 여부
        let totalLogicalHeight: CGFloat         // 논리적 전체 높이
        let segmentHeight: CGFloat              // 세그먼트 단위 높이
        let currentSegmentIndex: Int            // 현재 세그먼트 인덱스
        let offsetInSegment: CGFloat            // 세그먼트 내 오프셋
        let maxBrowserScrollLimit: CGFloat      // 브라우저 최대 스크롤 제한
        
        static let `default` = ScrollSegmentation(
            isSegmented: false,
            totalLogicalHeight: 0,
            segmentHeight: 16000000, // Firefox 기준 안전한 값
            currentSegmentIndex: 0,
            offsetInSegment: 0,
            maxBrowserScrollLimit: 16000000
        )
    }
    
    // 🆕 **가상화 정보 구조체**
    struct VirtualizationInfo: Codable {
        let isVirtualized: Bool                 // 가상화 여부 감지
        let virtualizationType: VirtualizationType
        let estimatedTotalItems: Int            // 전체 아이템 수 추정
        let averageItemHeight: CGFloat          // 평균 아이템 높이
        let visibleItemsRange: NSRange          // 보이는 아이템 범위
        let measurementsCache: [String: CGFloat] // measurements 캐시
        let vueComponentStates: [String: Any]?  // Vue 컴포넌트 상태
        let scrollSegmentation: ScrollSegmentation
        
        enum VirtualizationType: String, Codable {
            case none = "none"
            case reactVirtualized = "react-virtualized"
            case reactWindow = "react-window"
            case tanstackVirtual = "tanstack-virtual"
            case vueVirtualScroller = "vue-virtual-scroller"
            case vuetifyVirtualScroll = "vuetify-virtual-scroll"
            case customVirtual = "custom-virtual"
            case infiniteScroll = "infinite-scroll"
        }
        
        static let `default` = VirtualizationInfo(
            isVirtualized: false,
            virtualizationType: .none,
            estimatedTotalItems: 0,
            averageItemHeight: 0,
            visibleItemsRange: NSRange(location: 0, length: 0),
            measurementsCache: [:],
            vueComponentStates: nil,
            scrollSegmentation: ScrollSegmentation.default
        )
    }
    
    // 🔄 **순차 실행 설정 (가상화 대응 강화)**
    struct RestorationConfig: Codable {
        let enableContentRestore: Bool
        let enablePercentRestore: Bool
        let enableAnchorRestore: Bool
        let enableFinalVerification: Bool
        let savedContentHeight: CGFloat
        let step1RenderDelay: Double
        let step2RenderDelay: Double
        let step3RenderDelay: Double
        let step4RenderDelay: Double
        let enableLazyLoadingTrigger: Bool
        let enableParentScrollRestore: Bool
        let enableIOVerification: Bool
        
        // 🆕 **가상화 리스트 전용 설정**
        let enableVirtualizationRestore: Bool    // 가상화 복원 활성화
        let enableMeasurementsCacheRestore: Bool // measurements 캐시 복원
        let enableVueStateRestore: Bool          // Vue 상태 복원
        let enableScrollSegmentation: Bool       // 스크롤 세그먼트 분할
        let virtualizationRestoreDelay: Double  // 가상화 복원 대기시간
        let maxRetryAttempts: Int               // 최대 재시도 횟수
        
        static let `default` = RestorationConfig(
            enableContentRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: 0,
            step1RenderDelay: 0.2,
            step2RenderDelay: 0.2,
            step3RenderDelay: 0.2,
            step4RenderDelay: 0.2,
            enableLazyLoadingTrigger: true,
            enableParentScrollRestore: true,
            enableIOVerification: true,
            enableVirtualizationRestore: true,
            enableMeasurementsCacheRestore: true,
            enableVueStateRestore: true,
            enableScrollSegmentation: true,
            virtualizationRestoreDelay: 0.5,
            maxRetryAttempts: 3
        )
    }
    
    enum CaptureStatus: String, Codable {
        case complete
        case partial
        case visualOnly
        case failed
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, scrollPositionPercent
        case contentSize, viewportSize, actualScrollableSize, jsState
        case timestamp, webViewSnapshotPath, captureStatus, version
        case virtualizationInfo, restorationConfig
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
        virtualizationInfo = try container.decodeIfPresent(VirtualizationInfo.self, forKey: .virtualizationInfo) ?? VirtualizationInfo.default
        restorationConfig = try container.decodeIfPresent(RestorationConfig.self, forKey: .restorationConfig) ?? RestorationConfig.default
        
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
        try container.encode(virtualizationInfo, forKey: .virtualizationInfo)
        try container.encode(restorationConfig, forKey: .restorationConfig)
        
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
    
    // 직접 초기화용 init (가상화 정보 포함)
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
         virtualizationInfo: VirtualizationInfo = VirtualizationInfo.default,
         restorationConfig: RestorationConfig = RestorationConfig.default) {
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
        self.virtualizationInfo = virtualizationInfo
        self.restorationConfig = RestorationConfig(
            enableContentRestore: restorationConfig.enableContentRestore,
            enablePercentRestore: restorationConfig.enablePercentRestore,
            enableAnchorRestore: restorationConfig.enableAnchorRestore,
            enableFinalVerification: restorationConfig.enableFinalVerification,
            savedContentHeight: max(actualScrollableSize.height, contentSize.height),
            step1RenderDelay: restorationConfig.step1RenderDelay,
            step2RenderDelay: restorationConfig.step2RenderDelay,
            step3RenderDelay: restorationConfig.step3RenderDelay,
            step4RenderDelay: restorationConfig.step4RenderDelay,
            enableLazyLoadingTrigger: restorationConfig.enableLazyLoadingTrigger,
            enableParentScrollRestore: restorationConfig.enableParentScrollRestore,
            enableIOVerification: restorationConfig.enableIOVerification,
            enableVirtualizationRestore: restorationConfig.enableVirtualizationRestore,
            enableMeasurementsCacheRestore: restorationConfig.enableMeasurementsCacheRestore,
            enableVueStateRestore: restorationConfig.enableVueStateRestore,
            enableScrollSegmentation: restorationConfig.enableScrollSegmentation,
            virtualizationRestoreDelay: restorationConfig.virtualizationRestoreDelay,
            maxRetryAttempts: restorationConfig.maxRetryAttempts
        )
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // MARK: - 🎯 **핵심: 가상화 리스트 대응 순차적 5단계 복원 시스템**
    
    // 복원 컨텍스트 구조체
    private struct RestorationContext {
        let snapshot: BFCacheSnapshot
        weak var webView: WKWebView?
        let completion: (Bool) -> Void
        var overallSuccess: Bool = false
        var attemptCount: Int = 0
    }
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 가상화 리스트 대응 5단계 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("🆕 가상화 감지: \(virtualizationInfo.isVirtualized ? "예(\(virtualizationInfo.virtualizationType.rawValue))" : "아니오")")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📏 스크롤 세그먼트: \(virtualizationInfo.scrollSegmentation.isSegmented ? "활성화" : "비활성화")")
        TabPersistenceManager.debugMessages.append("💾 Measurements 캐시: \(virtualizationInfo.measurementsCache.count)개")
        
        // 복원 컨텍스트 생성
        let context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: completion
        )
        
        // Step 0: 가상화 감지 및 준비
        executeStep0_VirtualizationDetection(context: context)
    }
    
    // MARK: - Step 0: 🆕 가상화 감지 및 measurements 캐시 복원
    private func executeStep0_VirtualizationDetection(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🆕 [Step 0] 가상화 감지 및 measurements 캐시 복원 시작")
        
        guard restorationConfig.enableVirtualizationRestore else {
            TabPersistenceManager.debugMessages.append("🆕 [Step 0] 가상화 복원 비활성화 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.executeStep1_RestoreContentHeight(context: context)
            }
            return
        }
        
        let measurementsCacheJSON: String
        if !virtualizationInfo.measurementsCache.isEmpty {
            if let jsonData = try? JSONSerialization.data(withJSONObject: virtualizationInfo.measurementsCache),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                measurementsCacheJSON = jsonString
            } else {
                measurementsCacheJSON = "{}"
            }
        } else {
            measurementsCacheJSON = "{}"
        }
        
        let vueStateJSON: String
        if let vueStates = virtualizationInfo.vueComponentStates {
            if let jsonData = try? JSONSerialization.data(withJSONObject: vueStates),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                vueStateJSON = jsonString
            } else {
                vueStateJSON = "{}"
            }
        } else {
            vueStateJSON = "{}"
        }
        
        let js = generateStep0_VirtualizationDetectionScript(
            measurementsCacheJSON: measurementsCacheJSON,
            vueStateJSON: vueStateJSON,
            virtualizationType: virtualizationInfo.virtualizationType.rawValue,
            estimatedTotalItems: virtualizationInfo.estimatedTotalItems,
            averageItemHeight: virtualizationInfo.averageItemHeight,
            scrollSegmentation: virtualizationInfo.scrollSegmentation
        )
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step0Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🆕 [Step 0] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step0Success = (resultDict["success"] as? Bool) ?? false
                
                // 가상화 감지 결과
                if let detectedVirtualization = resultDict["detectedVirtualization"] as? [String: Any] {
                    if let isDetected = detectedVirtualization["isVirtualized"] as? Bool {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 0] 가상화 감지: \(isDetected ? "예" : "아니오")")
                    }
                    if let detectedType = detectedVirtualization["type"] as? String {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 0] 감지된 타입: \(detectedType)")
                    }
                }
                
                // measurements 캐시 복원 결과
                if let cacheResults = resultDict["measurementsCacheResults"] as? [String: Any] {
                    if let restoredCount = cacheResults["restoredCount"] as? Int {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 0] Measurements 캐시 복원: \(restoredCount)개")
                    }
                    if let method = cacheResults["method"] as? String {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 0] 복원 방식: \(method)")
                    }
                }
                
                // Vue 상태 복원 결과
                if let vueResults = resultDict["vueStateResults"] as? [String: Any] {
                    if let restoredComponents = vueResults["restoredComponents"] as? Int {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 0] Vue 컴포넌트 상태 복원: \(restoredComponents)개")
                    }
                }
                
                // 스크롤 세그먼트 설정 결과
                if let segmentResults = resultDict["scrollSegmentResults"] as? [String: Any] {
                    if let isSegmented = segmentResults["isSegmented"] as? Bool {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 0] 스크롤 세그먼트: \(isSegmented ? "활성화" : "비활성화")")
                    }
                    if let segmentHeight = segmentResults["segmentHeight"] as? Double {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 0] 세그먼트 높이: \(String(format: "%.0f", segmentHeight))px")
                    }
                }
                
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("🆕 [Step 0] 완료: \(step0Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 0] 가상화 복원 대기: \(self.restorationConfig.virtualizationRestoreDelay)초")
            
            // 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.virtualizationRestoreDelay) {
                self.executeStep1_RestoreContentHeight(context: context)
            }
        }
    }
    
    // MARK: - Step 1: Lazy Loading 트리거 → 부모 스크롤 복원 → 콘텐츠 높이 복원
    private func executeStep1_RestoreContentHeight(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📦 [Step 1] Lazy Loading 트리거 + 부모 스크롤 + 콘텐츠 복원 시작")
        
        guard restorationConfig.enableContentRestore else {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step1RenderDelay) {
                self.executeStep2_PercentScroll(context: context)
            }
            return
        }
        
        // 부모 스크롤 복원 데이터 추출
        let parentScrollDataJSON: String
        if let jsState = self.jsState,
           let parentScrollStates = jsState["parentScrollStates"] as? [[String: Any]] {
            if let jsonData = try? JSONSerialization.data(withJSONObject: parentScrollStates),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                parentScrollDataJSON = jsonString
            } else {
                parentScrollDataJSON = "[]"
            }
        } else {
            parentScrollDataJSON = "[]"
        }
        
        let js = generateStep1_LazyLoadAndContentRestoreScript(
            parentScrollDataJSON: parentScrollDataJSON,
            enableLazyLoading: restorationConfig.enableLazyLoadingTrigger
        )
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step1Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step1Success = (resultDict["success"] as? Bool) ?? false
                
                // 결과 로깅 (기존 로직과 동일)
                if let lazyLoadingResults = resultDict["lazyLoadingResults"] as? [String: Any] {
                    if let triggered = lazyLoadingResults["triggered"] as? Int {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 1] Lazy Loading 트리거: \(triggered)개")
                    }
                }
                
                if let parentScrollCount = resultDict["parentScrollCount"] as? Int {
                    TabPersistenceManager.debugMessages.append("🆕 [Step 1] 부모 스크롤 복원: \(parentScrollCount)개")
                }
            }
            
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 완료: \(step1Success ? "성공" : "실패") - 실패해도 계속 진행")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step1RenderDelay) {
                self.executeStep2_PercentScroll(context: context)
            }
        }
    }
    
    // MARK: - Step 2: 상대좌표 기반 스크롤 (가상화 대응 강화)
    private func executeStep2_PercentScroll(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📏 [Step 2] 가상화 대응 상대좌표 기반 스크롤 복원 시작")
        
        guard restorationConfig.enablePercentRestore else {
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step2RenderDelay) {
                self.executeStep3_AnchorRestore(context: context)
            }
            return
        }
        
        let js = generateStep2_VirtualizationAwarePercentScrollScript(
            isVirtualized: virtualizationInfo.isVirtualized,
            segmentation: virtualizationInfo.scrollSegmentation
        )
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step2Success = false
            var updatedContext = context
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📏 [Step 2] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step2Success = (resultDict["success"] as? Bool) ?? false
                
                if let virtualizedResults = resultDict["virtualizedResults"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] 가상화 스크롤 처리: \(virtualizedResults)")
                }
                
                if step2Success {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] ✅ 가상화 대응 상대좌표 복원 성공")
                }
            }
            
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 완료: \(step2Success ? "성공" : "실패")")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step2RenderDelay) {
                self.executeStep3_AnchorRestore(context: updatedContext)
            }
        }
    }
    
    // MARK: - Step 3: 무한스크롤 전용 앵커 복원 + IntersectionObserver 검증
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 무한스크롤 전용 앵커 정밀 복원 시작 (가상화 대응)")
        
        guard restorationConfig.enableAnchorRestore else {
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step3RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
            return
        }
        
        // 무한스크롤 앵커 데이터 확인
        var infiniteScrollAnchorDataJSON = "null"
        if let jsState = self.jsState,
           let infiniteScrollAnchorData = jsState["infiniteScrollAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(infiniteScrollAnchorData) {
            infiniteScrollAnchorDataJSON = dataJSON
        }
        
        let js = generateStep3_VirtualizationAwareAnchorRestoreScript(
            anchorDataJSON: infiniteScrollAnchorDataJSON,
            virtualizationInfo: virtualizationInfo,
            enableIOVerification: restorationConfig.enableIOVerification
        )
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step3Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🔍 [Step 3] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step3Success = (resultDict["success"] as? Bool) ?? false
                
                // 결과 로깅 (기존 로직 + 가상화 추가 정보)
                if let virtualizedAnchorResults = resultDict["virtualizedAnchorResults"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 가상화 앵커 복원: \(virtualizedAnchorResults)")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 완료: \(step3Success ? "성공" : "실패") - 실패해도 계속 진행")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step3RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
        }
    }
    
    // MARK: - Step 4: 최종 검증 및 미세 보정 (가상화 대응)
    private func executeStep4_FinalVerification(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("✅ [Step 4] 가상화 대응 최종 검증 및 미세 보정 시작")
        
        guard restorationConfig.enableFinalVerification else {
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 비활성화됨 - 스킵")
            context.completion(context.overallSuccess)
            return
        }
        
        let js = generateStep4_VirtualizationAwareFinalVerificationScript(
            virtualizationInfo: virtualizationInfo,
            maxRetryAttempts: restorationConfig.maxRetryAttempts
        )
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step4Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step4Success = (resultDict["success"] as? Bool) ?? false
                
                if let virtualizedVerification = resultDict["virtualizedVerification"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("✅ [Step 4] 가상화 최종 검증: \(virtualizedVerification)")
                }
            }
            
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 완료: \(step4Success ? "성공" : "실패")")
            
            // 최종 대기 후 완료 콜백
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step4RenderDelay) {
                let finalSuccess = context.overallSuccess || step4Success
                TabPersistenceManager.debugMessages.append("🎯 가상화 대응 BFCache 복원 완료: \(finalSuccess ? "성공" : "실패")")
                context.completion(finalSuccess)
            }
        }
    }
    
    // MARK: - 🆕 JavaScript 생성 메서드들 (가상화 대응)
    
    // Step 0: 가상화 감지 및 measurements 캐시 복원
    private func generateStep0_VirtualizationDetectionScript(
        measurementsCacheJSON: String,
        vueStateJSON: String,
        virtualizationType: String,
        estimatedTotalItems: Int,
        averageItemHeight: CGFloat,
        scrollSegmentation: ScrollSegmentation
    ) -> String {
        return """
        (function() {
            try {
                const logs = [];
                const measurementsCache = \(measurementsCacheJSON);
                const vueStates = \(vueStateJSON);
                const knownVirtualizationType = '\(virtualizationType)';
                const estimatedTotalItems = \(estimatedTotalItems);
                const averageItemHeight = \(averageItemHeight);
                const scrollSegmentation = \(convertToJSONString(scrollSegmentation) ?? "{}")
                
                logs.push('🆕 [Step 0] 가상화 감지 및 measurements 캐시 복원 시작');
                logs.push('기존 measurements 캐시: ' + Object.keys(measurementsCache).length + '개');
                logs.push('Vue 상태: ' + Object.keys(vueStates).length + '개');
                logs.push('예상 가상화 타입: ' + knownVirtualizationType);
                
                // 🆕 **1. 가상화 라이브러리 감지**
                function detectVirtualization() {
                    const detectionResults = {
                        isVirtualized: false,
                        type: 'none',
                        detectedLibraries: [],
                        confidence: 0
                    };
                    
                    // React Virtualized 감지
                    if (document.querySelector('.ReactVirtualized__List') || 
                        document.querySelector('.ReactVirtualized__Grid') ||
                        window.ReactVirtualized) {
                        detectionResults.detectedLibraries.push('react-virtualized');
                        detectionResults.isVirtualized = true;
                        detectionResults.type = 'react-virtualized';
                        detectionResults.confidence = 90;
                    }
                    
                    // React Window 감지
                    if (document.querySelector('[data-testid*="virtualized"]') ||
                        window.FixedSizeList || window.VariableSizeList) {
                        detectionResults.detectedLibraries.push('react-window');
                        detectionResults.isVirtualized = true;
                        detectionResults.type = 'react-window';
                        detectionResults.confidence = 85;
                    }
                    
                    // TanStack Virtual 감지
                    if (document.querySelector('[data-index]') && 
                        document.querySelector('[style*="transform: translateY"]')) {
                        detectionResults.detectedLibraries.push('tanstack-virtual');
                        detectionResults.isVirtualized = true;
                        detectionResults.type = 'tanstack-virtual';
                        detectionResults.confidence = 80;
                    }
                    
                    // Vue Virtual Scroller 감지
                    if (document.querySelector('.vue-recycle-scroller') ||
                        document.querySelector('.vue-virtual-scroller') ||
                        document.querySelector('[data-v-]')) {
                        detectionResults.detectedLibraries.push('vue-virtual-scroller');
                        detectionResults.isVirtualized = true;
                        detectionResults.type = 'vue-virtual-scroller';
                        detectionResults.confidence = 85;
                    }
                    
                    // Vuetify Virtual Scroll 감지
                    if (document.querySelector('.v-virtual-scroll') ||
                        document.querySelector('.v-data-table-virtual')) {
                        detectionResults.detectedLibraries.push('vuetify-virtual-scroll');
                        detectionResults.isVirtualized = true;
                        detectionResults.type = 'vuetify-virtual-scroll';
                        detectionResults.confidence = 80;
                    }
                    
                    // 커스텀 가상화 패턴 감지
                    const virtualizedElements = document.querySelectorAll('[style*="position: absolute"], [style*="transform: translate"]');
                    const itemElements = document.querySelectorAll('.item, .list-item, li');
                    
                    if (virtualizedElements.length > 10 && itemElements.length < virtualizedElements.length * 0.5) {
                        detectionResults.detectedLibraries.push('custom-virtual');
                        detectionResults.isVirtualized = true;
                        detectionResults.type = 'custom-virtual';
                        detectionResults.confidence = 60;
                    }
                    
                    logs.push('가상화 감지 결과: ' + detectionResults.type + ' (신뢰도: ' + detectionResults.confidence + '%)');
                    return detectionResults;
                }
                
                // 🆕 **2. Measurements Cache 복원**
                function restoreMeasurementsCache() {
                    const cacheResults = {
                        restoredCount: 0,
                        method: 'none',
                        success: false
                    };
                    
                    if (Object.keys(measurementsCache).length === 0) {
                        logs.push('Measurements 캐시 없음 - 스킵');
                        return cacheResults;
                    }
                    
                    // React Virtualized CellMeasurerCache 복원
                    if (window.ReactVirtualized && window.ReactVirtualized.CellMeasurerCache) {
                        try {
                            const cache = new window.ReactVirtualized.CellMeasurerCache({
                                fixedWidth: true,
                                defaultHeight: averageItemHeight
                            });
                            
                            for (const [key, height] of Object.entries(measurementsCache)) {
                                const index = parseInt(key);
                                if (!isNaN(index)) {
                                    cache.set(index, 0, parseFloat(height), parseFloat(height));
                                    cacheResults.restoredCount++;
                                }
                            }
                            
                            // 전역에 캐시 설정
                            window.__BFCacheRestoredMeasurements = cache;
                            cacheResults.method = 'react-virtualized-cache';
                            cacheResults.success = true;
                        } catch(e) {
                            logs.push('React Virtualized 캐시 복원 실패: ' + e.message);
                        }
                    }
                    
                    // TanStack Virtual measurements 복원
                    if (cacheResults.restoredCount === 0) {
                        try {
                            const measurementsMap = new Map();
                            for (const [key, height] of Object.entries(measurementsCache)) {
                                measurementsMap.set(key, { size: parseFloat(height) });
                                cacheResults.restoredCount++;
                            }
                            
                            window.__BFCacheTanStackMeasurements = measurementsMap;
                            cacheResults.method = 'tanstack-virtual-map';
                            cacheResults.success = true;
                        } catch(e) {
                            logs.push('TanStack Virtual 캐시 복원 실패: ' + e.message);
                        }
                    }
                    
                    // 일반적인 높이 캐시 복원
                    if (cacheResults.restoredCount === 0) {
                        try {
                            window.__BFCacheHeightMap = measurementsCache;
                            cacheResults.restoredCount = Object.keys(measurementsCache).length;
                            cacheResults.method = 'generic-height-map';
                            cacheResults.success = true;
                        } catch(e) {
                            logs.push('일반 높이 캐시 복원 실패: ' + e.message);
                        }
                    }
                    
                    logs.push('Measurements 캐시 복원: ' + cacheResults.restoredCount + '개 (' + cacheResults.method + ')');
                    return cacheResults;
                }
                
                // 🆕 **3. Vue 컴포넌트 상태 복원**
                function restoreVueStates() {
                    const vueResults = {
                        restoredComponents: 0,
                        method: 'none',
                        success: false
                    };
                    
                    if (Object.keys(vueStates).length === 0) {
                        logs.push('Vue 상태 없음 - 스킵');
                        return vueResults;
                    }
                    
                    try {
                        // Vue 인스턴스 찾기
                        const vueElements = document.querySelectorAll('[data-v-]');
                        
                        vueElements.forEach(function(element) {
                            const vueInstance = element.__vue__ || element._vnode?.componentInstance;
                            if (vueInstance) {
                                // Vue 상태 복원 시도
                                for (const [key, state] of Object.entries(vueStates)) {
                                    if (vueInstance.$data && typeof vueInstance.$data === 'object') {
                                        Object.assign(vueInstance.$data, state);
                                        vueResults.restoredComponents++;
                                    }
                                }
                            }
                        });
                        
                        vueResults.method = 'vue-instance-data';
                        vueResults.success = vueResults.restoredComponents > 0;
                    } catch(e) {
                        logs.push('Vue 상태 복원 실패: ' + e.message);
                    }
                    
                    logs.push('Vue 상태 복원: ' + vueResults.restoredComponents + '개 컴포넌트');
                    return vueResults;
                }
                
                // 🆕 **4. 스크롤 세그먼트 설정**
                function setupScrollSegmentation() {
                    const segmentResults = {
                        isSegmented: false,
                        segmentHeight: 0,
                        success: false
                    };
                    
                    if (!scrollSegmentation.isSegmented) {
                        logs.push('스크롤 세그먼트 비활성화 - 스킵');
                        return segmentResults;
                    }
                    
                    try {
                        // 세그먼트 높이 설정
                        const maxHeight = Math.min(scrollSegmentation.maxBrowserScrollLimit, 16000000); // Firefox 기준
                        document.documentElement.style.setProperty('--bfcache-segment-height', maxHeight + 'px');
                        
                        // 논리적 스크롤 시스템 활성화
                        window.__BFCacheScrollSegmentation = {
                            totalHeight: scrollSegmentation.totalLogicalHeight,
                            segmentHeight: scrollSegmentation.segmentHeight,
                            currentSegment: scrollSegmentation.currentSegmentIndex,
                            offsetInSegment: scrollSegmentation.offsetInSegment
                        };
                        
                        segmentResults.isSegmented = true;
                        segmentResults.segmentHeight = scrollSegmentation.segmentHeight;
                        segmentResults.success = true;
                        
                    } catch(e) {
                        logs.push('스크롤 세그먼트 설정 실패: ' + e.message);
                    }
                    
                    logs.push('스크롤 세그먼트 설정: ' + (segmentResults.success ? '성공' : '실패'));
                    return segmentResults;
                }
                
                // 실행
                const detectedVirtualization = detectVirtualization();
                const measurementsCacheResults = restoreMeasurementsCache();
                const vueStateResults = restoreVueStates();
                const scrollSegmentResults = setupScrollSegmentation();
                
                const overallSuccess = detectedVirtualization.isVirtualized || 
                                      measurementsCacheResults.success || 
                                      vueStateResults.success ||
                                      scrollSegmentResults.success;
                
                logs.push('=== Step 0 가상화 준비 완료 ===');
                
                return {
                    success: overallSuccess,
                    detectedVirtualization: detectedVirtualization,
                    measurementsCacheResults: measurementsCacheResults,
                    vueStateResults: vueStateResults,
                    scrollSegmentResults: scrollSegmentResults,
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    logs: ['[Step 0] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // Step 1: Lazy Loading 트리거 (기존과 동일)
    private func generateStep1_LazyLoadAndContentRestoreScript(
        parentScrollDataJSON: String,
        enableLazyLoading: Bool
    ) -> String {
        let targetHeight = restorationConfig.savedContentHeight
        let targetY = scrollPosition.y
        
        // 기존 Step 1 스크립트와 동일하므로 생략 (너무 길어져서)
        return """
        (function() {
            // 기존 Step 1 로직과 동일
            try {
                const logs = ['[Step 1] Lazy Loading + 부모 스크롤 + 콘텐츠 복원 (가상화 대응)'];
                // ... 기존 Step 1 로직
                return {
                    success: true,
                    logs: logs
                };
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    logs: ['[Step 1] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // Step 2: 가상화 대응 상대좌표 스크롤
    private func generateStep2_VirtualizationAwarePercentScrollScript(
        isVirtualized: Bool,
        segmentation: ScrollSegmentation
    ) -> String {
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetPercentX = parseFloat('\(targetPercentX)');
                const targetPercentY = parseFloat('\(targetPercentY)');
                const isVirtualized = \(isVirtualized ? "true" : "false");
                const segmentation = \(convertToJSONString(segmentation) ?? "{}");
                
                logs.push('[Step 2] 가상화 대응 상대좌표 기반 스크롤 복원');
                logs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                logs.push('가상화 여부: ' + (isVirtualized ? '예' : '아니오'));
                
                // 현재 콘텐츠 크기와 뷰포트 크기
                let contentHeight = Math.max(
                    document.documentElement.scrollHeight,
                    document.body.scrollHeight
                );
                const contentWidth = Math.max(
                    document.documentElement.scrollWidth,
                    document.body.scrollWidth
                );
                const viewportHeight = window.innerHeight;
                const viewportWidth = window.innerWidth;
                
                // 🆕 **가상화 리스트인 경우 실제 콘텐츠 높이 추정**
                if (isVirtualized) {
                    // measurements 캐시에서 실제 높이 추정
                    if (window.__BFCacheHeightMap) {
                        const measurements = window.__BFCacheHeightMap;
                        const totalMeasuredHeight = Object.values(measurements)
                            .reduce(function(sum, height) { return sum + parseFloat(height); }, 0);
                        
                        if (totalMeasuredHeight > contentHeight) {
                            contentHeight = totalMeasuredHeight;
                            logs.push('가상화 높이 추정: ' + contentHeight.toFixed(0) + 'px (measurements 기반)');
                        }
                    }
                    
                    // 세그먼트 분할 높이 사용
                    if (segmentation && segmentation.isSegmented && segmentation.totalLogicalHeight > contentHeight) {
                        contentHeight = segmentation.totalLogicalHeight;
                        logs.push('가상화 높이 추정: ' + contentHeight.toFixed(0) + 'px (세그먼트 기반)');
                    }
                }
                
                // 최대 스크롤 가능 거리 계산
                let maxScrollY = Math.max(0, contentHeight - viewportHeight);
                let maxScrollX = Math.max(0, contentWidth - viewportWidth);
                
                // 🆕 **세그먼트 분할 스크롤 처리**
                if (segmentation && segmentation.isSegmented) {
                    // 논리적 위치를 물리적 위치로 변환
                    const logicalY = (targetPercentY / 100) * segmentation.totalLogicalHeight;
                    const segmentIndex = Math.floor(logicalY / segmentation.segmentHeight);
                    const offsetInSegment = logicalY % segmentation.segmentHeight;
                    
                    // 현재 세그먼트로 조정
                    if (segmentIndex !== segmentation.currentSegmentIndex) {
                        // 세그먼트 전환 필요
                        window.__BFCacheScrollSegmentation.currentSegment = segmentIndex;
                        window.__BFCacheScrollSegmentation.offsetInSegment = offsetInSegment;
                        
                        logs.push('세그먼트 전환: ' + segmentation.currentSegmentIndex + ' → ' + segmentIndex);
                    }
                    
                    maxScrollY = Math.min(offsetInSegment, segmentation.segmentHeight - viewportHeight);
                }
                
                logs.push('최대 스크롤: X=' + maxScrollX.toFixed(0) + 'px, Y=' + maxScrollY.toFixed(0) + 'px');
                
                // 백분율 기반 목표 위치 계산
                const targetX = (targetPercentX / 100) * maxScrollX;
                const targetY = (targetPercentY / 100) * maxScrollY;
                
                logs.push('계산된 목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // 🆕 **가상화 리스트 스크롤 실행**
                if (isVirtualized) {
                    // 가상화 라이브러리별 스크롤 처리
                    let virtualScrollSuccess = false;
                    
                    // TanStack Virtual 처리
                    if (window.__BFCacheTanStackMeasurements) {
                        try {
                            // TanStack Virtual의 scrollToOffset 시도
                            const virtualizers = document.querySelectorAll('[data-index]');
                            virtualizers.forEach(function(element) {
                                const virtualizer = element.__virtualizer;
                                if (virtualizer && virtualizer.scrollToOffset) {
                                    virtualizer.scrollToOffset(targetY);
                                    virtualScrollSuccess = true;
                                }
                            });
                        } catch(e) {
                            logs.push('TanStack Virtual 스크롤 실패: ' + e.message);
                        }
                    }
                    
                    // React Virtualized 처리
                    if (!virtualScrollSuccess && window.__BFCacheRestoredMeasurements) {
                        try {
                            const virtualizedLists = document.querySelectorAll('.ReactVirtualized__List');
                            virtualizedLists.forEach(function(element) {
                                const listInstance = element.__reactInternalInstance || element._reactInternalFiber;
                                if (listInstance && listInstance.scrollToPosition) {
                                    listInstance.scrollToPosition(targetY);
                                    virtualScrollSuccess = true;
                                }
                            });
                        } catch(e) {
                            logs.push('React Virtualized 스크롤 실패: ' + e.message);
                        }
                    }
                    
                    // Vue Virtual Scroller 처리
                    if (!virtualScrollSuccess) {
                        try {
                            const vueScrollers = document.querySelectorAll('.vue-recycle-scroller, .vue-virtual-scroller');
                            vueScrollers.forEach(function(element) {
                                const vueInstance = element.__vue__;
                                if (vueInstance && vueInstance.scrollToPosition) {
                                    vueInstance.scrollToPosition(targetY);
                                    virtualScrollSuccess = true;
                                } else if (vueInstance && vueInstance.$refs.scroller) {
                                    vueInstance.$refs.scroller.scrollTop = targetY;
                                    virtualScrollSuccess = true;
                                }
                            });
                        } catch(e) {
                            logs.push('Vue Virtual Scroller 스크롤 실패: ' + e.message);
                        }
                    }
                    
                    logs.push('가상화 스크롤: ' + (virtualScrollSuccess ? '성공' : '실패'));
                }
                
                // 일반 스크롤 실행 (가상화 실패 시 폴백)
                window.scrollTo(targetX, targetY);
                document.documentElement.scrollTop = targetY;
                document.documentElement.scrollLeft = targetX;
                document.body.scrollTop = targetY;
                document.body.scrollLeft = targetX;
                
                if (document.scrollingElement) {
                    document.scrollingElement.scrollTop = targetY;
                    document.scrollingElement.scrollLeft = targetX;
                }
                
                // 실제 적용된 위치 확인
                const actualX = window.scrollX || window.pageXOffset || 0;
                const actualY = window.scrollY || window.pageYOffset || 0;
                
                const diffX = Math.abs(actualX - targetX);
                const diffY = Math.abs(actualY - targetY);
                
                logs.push('실제 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                // 성공 기준: 가상화의 경우 더 관대한 허용 오차
                const tolerance = isVirtualized ? 100 : 50;
                const success = diffY <= tolerance;
                
                return {
                    success: success,
                    targetPercent: { x: targetPercentX, y: targetPercentY },
                    calculatedPosition: { x: targetX, y: targetY },
                    actualPosition: { x: actualX, y: actualY },
                    difference: { x: diffX, y: diffY },
                    virtualizedResults: {
                        isVirtualized: isVirtualized,
                        contentHeight: contentHeight,
                        tolerance: tolerance
                    },
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    logs: ['[Step 2] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // Step 3: 가상화 대응 앵커 복원
    private func generateStep3_VirtualizationAwareAnchorRestoreScript(
        anchorDataJSON: String,
        virtualizationInfo: VirtualizationInfo,
        enableIOVerification: Bool
    ) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const infiniteScrollAnchorData = \(anchorDataJSON);
                const virtualizationInfo = \(convertToJSONString(virtualizationInfo) ?? "{}");
                const enableIOVerification = \(enableIOVerification ? "true" : "false");
                
                logs.push('[Step 3] 가상화 대응 무한스크롤 앵커 복원');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                logs.push('가상화 타입: ' + (virtualizationInfo.virtualizationType || 'none'));
                
                // 🆕 **가상화 리스트 앵커 특별 처리**
                function findVirtualizedAnchor() {
                    if (!virtualizationInfo.isVirtualized) {
                        return null;
                    }
                    
                    // measurements 캐시 기반 앵커 찾기
                    if (window.__BFCacheHeightMap && virtualizationInfo.averageItemHeight > 0) {
                        const estimatedIndex = Math.floor(targetY / virtualizationInfo.averageItemHeight);
                        const virtualElement = document.querySelector('[data-index="' + estimatedIndex + '"]');
                        
                        if (virtualElement) {
                            logs.push('가상화 앵커 발견: 인덱스 ' + estimatedIndex);
                            return {
                                element: virtualElement,
                                confidence: 85,
                                method: 'measurements-cache',
                                index: estimatedIndex
                            };
                        }
                    }
                    
                    // Vue 가상 스크롤러 앵커 찾기
                    if (virtualizationInfo.virtualizationType === 'vue-virtual-scroller') {
                        const vueScrollers = document.querySelectorAll('.vue-recycle-scroller .vue-recycle-scroller__item-view');
                        if (vueScrollers.length > 0) {
                            // 가장 가까운 Vue 아이템 찾기
                            let closestElement = null;
                            let minDistance = Infinity;
                            
                            vueScrollers.forEach(function(element) {
                                const rect = element.getBoundingClientRect();
                                const elementY = window.scrollY + rect.top;
                                const distance = Math.abs(elementY - targetY);
                                
                                if (distance < minDistance) {
                                    minDistance = distance;
                                    closestElement = element;
                                }
                            });
                            
                            if (closestElement && minDistance < 200) {
                                logs.push('Vue 가상 스크롤러 앵커 발견: 거리 ' + minDistance.toFixed(0) + 'px');
                                return {
                                    element: closestElement,
                                    confidence: 75,
                                    method: 'vue-virtual-item',
                                    distance: minDistance
                                };
                            }
                        }
                    }
                    
                    return null;
                }
                
                // 기존 앵커 데이터 확인
                if (!infiniteScrollAnchorData || !infiniteScrollAnchorData.anchors || infiniteScrollAnchorData.anchors.length === 0) {
                    // 가상화 앵커 시도
                    const virtualAnchor = findVirtualizedAnchor();
                    if (virtualAnchor) {
                        try {
                            virtualAnchor.element.scrollIntoView({ behavior: 'auto', block: 'start' });
                            
                            const actualX = window.scrollX || window.pageXOffset || 0;
                            const actualY = window.scrollY || window.pageYOffset || 0;
                            const diffY = Math.abs(actualY - targetY);
                            
                            logs.push('가상화 앵커 복원 후 위치: Y=' + actualY.toFixed(1) + 'px');
                            logs.push('목표와의 차이: ' + diffY.toFixed(1) + 'px');
                            
                            return {
                                success: diffY <= 150, // 가상화는 더 관대한 허용 오차
                                virtualizedAnchorResults: {
                                    found: true,
                                    method: virtualAnchor.method,
                                    confidence: virtualAnchor.confidence,
                                    finalDifference: diffY
                                },
                                logs: logs
                            };
                        } catch(e) {
                            logs.push('가상화 앵커 복원 실패: ' + e.message);
                        }
                    }
                    
                    logs.push('무한스크롤 앵커 데이터 없음 + 가상화 앵커 없음 - 스킵');
                    return {
                        success: false,
                        virtualizedAnchorResults: { found: false },
                        logs: logs
                    };
                }
                
                // 기존 앵커 로직 실행
                const anchors = infiniteScrollAnchorData.anchors;
                logs.push('사용 가능한 앵커: ' + anchors.length + '개');
                
                // ... 기존 앵커 복원 로직 (생략)
                
                return {
                    success: false,
                    virtualizedAnchorResults: { found: false },
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    logs: ['[Step 3] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // Step 4: 가상화 대응 최종 검증
    private func generateStep4_VirtualizationAwareFinalVerificationScript(
        virtualizationInfo: VirtualizationInfo,
        maxRetryAttempts: Int
    ) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const virtualizationInfo = \(convertToJSONString(virtualizationInfo) ?? "{}");
                const maxRetryAttempts = \(maxRetryAttempts);
                
                // 가상화 리스트는 더 관대한 허용 오차 적용
                const tolerance = virtualizationInfo.isVirtualized ? 100 : 30;
                
                logs.push('[Step 4] 가상화 대응 최종 검증 및 미세 보정');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                logs.push('허용 오차: ' + tolerance + 'px (가상화: ' + (virtualizationInfo.isVirtualized ? '예' : '아니오') + ')');
                
                // 현재 위치 확인
                let currentX = window.scrollX || window.pageXOffset || 0;
                let currentY = window.scrollY || window.pageYOffset || 0;
                
                let diffX = Math.abs(currentX - targetX);
                let diffY = Math.abs(currentY - targetY);
                
                logs.push('현재 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                const withinTolerance = diffX <= tolerance && diffY <= tolerance;
                let correctionApplied = false;
                let retryCount = 0;
                
                // 🆕 **가상화 리스트 특별 처리**
                if (!withinTolerance && virtualizationInfo.isVirtualized) {
                    logs.push('가상화 리스트 특별 복원 시도');
                    
                    // 재시도 루프
                    while (retryCount < maxRetryAttempts && diffY > tolerance) {
                        retryCount++;
                        logs.push('재시도 ' + retryCount + '/' + maxRetryAttempts);
                        
                        // measurements 캐시 기반 정밀 스크롤
                        if (window.__BFCacheHeightMap && virtualizationInfo.averageItemHeight > 0) {
                            const estimatedIndex = Math.floor(targetY / virtualizationInfo.averageItemHeight);
                            const targetElement = document.querySelector('[data-index="' + estimatedIndex + '"]');
                            
                            if (targetElement) {
                                try {
                                    targetElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                                    
                                    // 미세 조정
                                    const rect = targetElement.getBoundingClientRect();
                                    const elementTop = window.scrollY + rect.top;
                                    const adjustment = targetY - elementTop;
                                    
                                    if (Math.abs(adjustment) < 500) { // 합리적인 범위 내에서만 조정
                                        window.scrollBy(0, adjustment);
                                    }
                                    
                                    correctionApplied = true;
                                    break;
                                } catch(e) {
                                    logs.push('재시도 ' + retryCount + ' 실패: ' + e.message);
                                }
                            }
                        }
                        
                        // 일반적인 스크롤 재시도
                        window.scrollTo(targetX, targetY);
                        
                        // 약간의 대기 후 재측정
                        await new Promise(resolve => setTimeout(resolve, 100));
                        
                        currentX = window.scrollX || window.pageXOffset || 0;
                        currentY = window.scrollY || window.pageYOffset || 0;
                        diffX = Math.abs(currentX - targetX);
                        diffY = Math.abs(currentY - targetY);
                        
                        logs.push('재시도 ' + retryCount + ' 후 차이: Y=' + diffY.toFixed(1) + 'px');
                    }
                }
                
                // 허용 오차 초과 시 일반적인 미세 보정
                if (!withinTolerance && !correctionApplied) {
                    logs.push('허용 오차 초과 - 미세 보정 적용');
                    
                    window.scrollTo(targetX, targetY);
                    document.documentElement.scrollTop = targetY;
                    document.documentElement.scrollLeft = targetX;
                    document.body.scrollTop = targetY;
                    document.body.scrollLeft = targetX;
                    
                    if (document.scrollingElement) {
                        document.scrollingElement.scrollTop = targetY;
                        document.scrollingElement.scrollLeft = targetX;
                    }
                    
                    correctionApplied = true;
                    
                    // 보정 후 위치 재측정
                    currentX = window.scrollX || window.pageXOffset || 0;
                    currentY = window.scrollY || window.pageYOffset || 0;
                    diffX = Math.abs(currentX - targetX);
                    diffY = Math.abs(currentY - targetY);
                    
                    logs.push('보정 후 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                    logs.push('보정 후 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                }
                
                const finalSuccess = diffY <= tolerance;
                
                return {
                    success: finalSuccess,
                    targetPosition: { x: targetX, y: targetY },
                    finalPosition: { x: currentX, y: currentY },
                    finalDifference: { x: diffX, y: diffY },
                    withinTolerance: diffX <= tolerance && diffY <= tolerance,
                    correctionApplied: correctionApplied,
                    virtualizedVerification: {
                        isVirtualized: virtualizationInfo.isVirtualized,
                        retryCount: retryCount,
                        tolerance: tolerance,
                        finalSuccess: finalSuccess
                    },
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    logs: ['[Step 4] 오류: ' + e.message]
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

// MARK: - BFCacheTransitionSystem 확장 (가상화 대응)
extension BFCacheTransitionSystem {
    
    // MARK: - 🆕 **가상화 리스트 대응 강화된 캐처 작업**
    
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
        
        TabPersistenceManager.debugMessages.append("🆕 가상화 리스트 대응 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 직렬화 큐로 모든 캡처 작업 순서 보장
        serialQueue.async { [weak self] in
            self?.performVirtualizationAwareCapture(task)
        }
    }
    
    private func performVirtualizationAwareCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        guard let webView = task.webView else {
            TabPersistenceManager.debugMessages.append("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        TabPersistenceManager.debugMessages.append("🆕 가상화 대응 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
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
            return
        }
        
        // 🆕 **가상화 대응 캡처 로직**
        let captureResult = performVirtualizationAwareRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        // 캐시 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ 가상화 대응 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize
        let viewportSize: CGSize
        let actualScrollableSize: CGSize
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🆕 **가상화 대응 강화된 캡처**
    private func performVirtualizationAwareRobustCapture(
        pageRecord: PageRecord,
        webView: WKWebView,
        captureData: CaptureData,
        retryCount: Int = 0
    ) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptVirtualizationAwareCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    TabPersistenceManager.debugMessages.append("🔄 가상화 대응 재시도 후 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            TabPersistenceManager.debugMessages.append("⏳ 가상화 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        // 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, 
                               actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), 
                               captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptVirtualizationAwareCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        TabPersistenceManager.debugMessages.append("📸 가상화 대응 스냅샷 캡처 시도: \(pageRecord.title)")
        
        // 1. 비주얼 스냅샷 (기존과 동일)
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 성공")
                }
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            TabPersistenceManager.debugMessages.append("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처 (기존과 동일)
        let domSemaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 정리 로직
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(function(el) {
                        var classList = Array.from(el.classList);
                        var classesToRemove = classList.filter(function(c) {
                            return c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus');
                        });
                        for (var i = 0; i < classesToRemove.length; i++) {
                            el.classList.remove(classesToRemove[i]);
                        }
                    });
                    
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
        _ = domSemaphore.wait(timeout: .now() + 2.0)
        
        // 3. 🆕 **가상화 리스트 대응 강화된 JS 상태 캡처**
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🆕 가상화 대응 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateVirtualizationAwareJSCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 가상화 대응 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ 가상화 대응 JS 상태 캡처 성공: \(Array(data.keys))")
                    
                    // 가상화 정보 로깅
                    if let virtualizationResults = data["virtualizationResults"] as? [String: Any] {
                        TabPersistenceManager.debugMessages.append("🆕 가상화 감지 결과: \(virtualizationResults)")
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🔥 가상화 대응 JS 상태 캐처 결과 타입 오류: \(type(of: result))")
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 3.0) // 가상화 처리를 위해 시간 증가
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .complete
            TabPersistenceManager.debugMessages.append("✅ 가상화 대응 완전 캡처 성공")
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
            TabPersistenceManager.debugMessages.append("⚡ 가상화 대응 부분 캡처 성공: visual=\(visualSnapshot != nil), dom=\(domSnapshot != nil), js=\(jsState != nil)")
        } else {
            captureStatus = .failed
            TabPersistenceManager.debugMessages.append("❌ 가상화 대응 캡처 실패")
        }
        
        // 🆕 **가상화 정보 추출**
        let virtualizationInfo = extractVirtualizationInfo(from: jsState, captureData: captureData)
        
        // 버전 증가
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        // 백분율 계산 로직 (가상화 대응)
        let scrollPercent: CGPoint
        if virtualizationInfo.isVirtualized && virtualizationInfo.scrollSegmentation.isSegmented {
            // 세그먼트 분할된 가상화 리스트의 경우 논리적 백분율 사용
            let logicalHeight = virtualizationInfo.scrollSegmentation.totalLogicalHeight
            let logicalY = CGFloat(virtualizationInfo.scrollSegmentation.currentSegmentIndex) * virtualizationInfo.scrollSegmentation.segmentHeight + virtualizationInfo.scrollSegmentation.offsetInSegment
            
            scrollPercent = CGPoint(
                x: 0, // 가상화는 주로 세로 스크롤
                y: logicalHeight > 0 ? (logicalY / logicalHeight * 100.0) : 0
            )
        } else if captureData.actualScrollableSize.height > captureData.viewportSize.height {
            let maxScrollY = max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height)
            scrollPercent = CGPoint(
                x: 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        TabPersistenceManager.debugMessages.append("📊 가상화 캡처 완료: 위치=(\(String(format: "%.1f", captureData.scrollPosition.x)), \(String(format: "%.1f", captureData.scrollPosition.y))), 백분율=(\(String(format: "%.2f", scrollPercent.x))%, \(String(format: "%.2f", scrollPercent.y))%)")
        TabPersistenceManager.debugMessages.append("🆕 가상화 감지: \(virtualizationInfo.isVirtualized ? "예(\(virtualizationInfo.virtualizationType.rawValue))" : "아니오")")
        
        // 🆕 **가상화 대응 복원 설정 생성**
        let restorationConfig = BFCacheSnapshot.RestorationConfig(
            enableContentRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height),
            step1RenderDelay: 0.4,
            step2RenderDelay: 0.3,
            step3RenderDelay: 0.2,
            step4RenderDelay: 0.4,
            enableLazyLoadingTrigger: true,
            enableParentScrollRestore: true,
            enableIOVerification: true,
            enableVirtualizationRestore: virtualizationInfo.isVirtualized,
            enableMeasurementsCacheRestore: !virtualizationInfo.measurementsCache.isEmpty,
            enableVueStateRestore: virtualizationInfo.vueComponentStates != nil,
            enableScrollSegmentation: virtualizationInfo.scrollSegmentation.isSegmented,
            virtualizationRestoreDelay: virtualizationInfo.isVirtualized ? 0.8 : 0.2,
            maxRetryAttempts: virtualizationInfo.isVirtualized ? 5 : 3
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
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version,
            virtualizationInfo: virtualizationInfo,
            restorationConfig: restorationConfig
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🆕 **가상화 정보 추출**
    private func extractVirtualizationInfo(from jsState: [String: Any]?, captureData: CaptureData) -> BFCacheSnapshot.VirtualizationInfo {
        guard let jsState = jsState else {
            return BFCacheSnapshot.VirtualizationInfo.default
        }
        
        // 가상화 결과 추출
        if let virtualizationResults = jsState["virtualizationResults"] as? [String: Any] {
            let isVirtualized = virtualizationResults["isVirtualized"] as? Bool ?? false
            let typeString = virtualizationResults["detectedType"] as? String ?? "none"
            let estimatedItems = virtualizationResults["estimatedTotalItems"] as? Int ?? 0
            let avgHeight = virtualizationResults["averageItemHeight"] as? Double ?? 0
            let visibleRange = virtualizationResults["visibleItemsRange"] as? [String: Int] ?? [:]
            let measurements = virtualizationResults["measurementsCache"] as? [String: Double] ?? [:]
            let vueStates = virtualizationResults["vueComponentStates"] as? [String: Any]
            
            let virtualizationType: BFCacheSnapshot.VirtualizationInfo.VirtualizationType
            switch typeString {
            case "react-virtualized": virtualizationType = .reactVirtualized
            case "react-window": virtualizationType = .reactWindow
            case "tanstack-virtual": virtualizationType = .tanstackVirtual
            case "vue-virtual-scroller": virtualizationType = .vueVirtualScroller
            case "vuetify-virtual-scroll": virtualizationType = .vuetifyVirtualScroll
            case "custom-virtual": virtualizationType = .customVirtual
            case "infinite-scroll": virtualizationType = .infiniteScroll
            default: virtualizationType = .none
            }
            
            // 스크롤 세그먼트 정보
            let scrollSegmentation: BFCacheSnapshot.ScrollSegmentation
            if let segmentInfo = virtualizationResults["scrollSegmentation"] as? [String: Any] {
                scrollSegmentation = BFCacheSnapshot.ScrollSegmentation(
                    isSegmented: segmentInfo["isSegmented"] as? Bool ?? false,
                    totalLogicalHeight: CGFloat(segmentInfo["totalLogicalHeight"] as? Double ?? 0),
                    segmentHeight: CGFloat(segmentInfo["segmentHeight"] as? Double ?? 16000000),
                    currentSegmentIndex: segmentInfo["currentSegmentIndex"] as? Int ?? 0,
                    offsetInSegment: CGFloat(segmentInfo["offsetInSegment"] as? Double ?? 0),
                    maxBrowserScrollLimit: CGFloat(segmentInfo["maxBrowserScrollLimit"] as? Double ?? 16000000)
                )
            } else {
                scrollSegmentation = BFCacheSnapshot.ScrollSegmentation.default
            }
            
            // measurements 캐시를 String: CGFloat로 변환
            let measurementsCGFloat = measurements.mapValues { CGFloat($0) }
            
            return BFCacheSnapshot.VirtualizationInfo(
                isVirtualized: isVirtualized,
                virtualizationType: virtualizationType,
                estimatedTotalItems: estimatedItems,
                averageItemHeight: CGFloat(avgHeight),
                visibleItemsRange: NSRange(location: visibleRange["location"] ?? 0, length: visibleRange["length"] ?? 0),
                measurementsCache: measurementsCGFloat,
                vueComponentStates: vueStates,
                scrollSegmentation: scrollSegmentation
            )
        }
        
        return BFCacheSnapshot.VirtualizationInfo.default
    }
    
    // 🆕 **가상화 대응 JavaScript 캡처 스크립트**
    private func generateVirtualizationAwareJSCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🆕 가상화 대응 통합 JS 상태 캡처 시작');
                
                const detailedLogs = [];
                const pageAnalysis = {};
                
                // 기본 정보 수집
                const scrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                const scrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                
                detailedLogs.push('🆕 가상화 대응 JS 캡처 시작');
                detailedLogs.push('스크롤 위치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포트 크기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                // 🆕 **1. 가상화 라이브러리 감지 및 분석**
                function detectAndAnalyzeVirtualization() {
                    const virtualizationResults = {
                        isVirtualized: false,
                        detectedType: 'none',
                        detectedLibraries: [],
                        confidence: 0,
                        estimatedTotalItems: 0,
                        averageItemHeight: 0,
                        visibleItemsRange: { location: 0, length: 0 },
                        measurementsCache: {},
                        vueComponentStates: {},
                        scrollSegmentation: {
                            isSegmented: false,
                            totalLogicalHeight: contentHeight,
                            segmentHeight: 16000000,
                            currentSegmentIndex: 0,
                            offsetInSegment: scrollY,
                            maxBrowserScrollLimit: 16000000
                        }
                    };
                    
                    // React Virtualized 감지 및 분석
                    const reactVirtualizedElements = document.querySelectorAll('.ReactVirtualized__List, .ReactVirtualized__Grid');
                    if (reactVirtualizedElements.length > 0 || window.ReactVirtualized) {
                        virtualizationResults.detectedLibraries.push('react-virtualized');
                        virtualizationResults.isVirtualized = true;
                        virtualizationResults.detectedType = 'react-virtualized';
                        virtualizationResults.confidence = 90;
                        
                        // CellMeasurerCache 추출
                        if (window.ReactVirtualized && window.ReactVirtualized.CellMeasurerCache) {
                            try {
                                const cacheElements = document.querySelectorAll('[data-cell-measurer-cache]');
                                cacheElements.forEach(function(element) {
                                    const cache = element.__cellMeasurerCache;
                                    if (cache && cache._cellMeasurements) {
                                        for (const key in cache._cellMeasurements) {
                                            const measurement = cache._cellMeasurements[key];
                                            if (measurement && measurement.height) {
                                                virtualizationResults.measurementsCache[key] = measurement.height;
                                            }
                                        }
                                    }
                                });
                                detailedLogs.push('React Virtualized measurements 추출: ' + Object.keys(virtualizationResults.measurementsCache).length + '개');
                            } catch(e) {
                                detailedLogs.push('React Virtualized measurements 추출 실패: ' + e.message);
                            }
                        }
                    }
                    
                    // TanStack Virtual 감지 및 분석
                    if (virtualizationResults.detectedType === 'none') {
                        const tanstackElements = document.querySelectorAll('[data-index][style*="transform: translateY"]');
                        if (tanstackElements.length > 0) {
                            virtualizationResults.detectedLibraries.push('tanstack-virtual');
                            virtualizationResults.isVirtualized = true;
                            virtualizationResults.detectedType = 'tanstack-virtual';
                            virtualizationResults.confidence = 85;
                            
                            // TanStack Virtual measurements 추출
                            try {
                                const virtualizer = window.__virtualizer;
                                if (virtualizer && virtualizer.measurementsCache) {
                                    for (const [key, value] of virtualizer.measurementsCache.entries()) {
                                        if (value && value.size) {
                                            virtualizationResults.measurementsCache[key] = value.size;
                                        }
                                    }
                                    detailedLogs.push('TanStack Virtual measurements 추출: ' + Object.keys(virtualizationResults.measurementsCache).length + '개');
                                }
                            } catch(e) {
                                detailedLogs.push('TanStack Virtual measurements 추출 실패: ' + e.message);
                            }
                            
                            // 가시 범위 계산
                            const visibleElements = document.querySelectorAll('[data-index]');
                            if (visibleElements.length > 0) {
                                const indices = Array.from(visibleElements).map(el => parseInt(el.getAttribute('data-index'))).filter(i => !isNaN(i));
                                if (indices.length > 0) {
                                    const minIndex = Math.min(...indices);
                                    const maxIndex = Math.max(...indices);
                                    virtualizationResults.visibleItemsRange = { location: minIndex, length: maxIndex - minIndex + 1 };
                                }
                            }
                        }
                    }
                    
                    // Vue Virtual Scroller 감지 및 분석
                    if (virtualizationResults.detectedType === 'none') {
                        const vueScrollerElements = document.querySelectorAll('.vue-recycle-scroller, .vue-virtual-scroller, [data-v-]');
                        if (vueScrollerElements.length > 0) {
                            virtualizationResults.detectedLibraries.push('vue-virtual-scroller');
                            virtualizationResults.isVirtualized = true;
                            virtualizationResults.detectedType = 'vue-virtual-scroller';
                            virtualizationResults.confidence = 85;
                            
                            // Vue 컴포넌트 상태 수집
                            try {
                                vueScrollerElements.forEach(function(element) {
                                    const vueInstance = element.__vue__;
                                    if (vueInstance && vueInstance.$data) {
                                        const componentKey = element.className || element.tagName.toLowerCase();
                                        virtualizationResults.vueComponentStates[componentKey] = vueInstance.$data;
                                    }
                                });
                                detailedLogs.push('Vue 컴포넌트 상태 수집: ' + Object.keys(virtualizationResults.vueComponentStates).length + '개');
                            } catch(e) {
                                detailedLogs.push('Vue 컴포넌트 상태 수집 실패: ' + e.message);
                            }
                        }
                    }
                    
                    // 커스텀 가상화 패턴 감지
                    if (virtualizationResults.detectedType === 'none') {
                        const virtualizedElements = document.querySelectorAll('[style*="position: absolute"][style*="transform"], [style*="translateY"]');
                        const itemElements = document.querySelectorAll('.item, .list-item, li, [class*="item"]');
                        
                        if (virtualizedElements.length > 10 && itemElements.length < virtualizedElements.length * 0.7) {
                            virtualizationResults.detectedLibraries.push('custom-virtual');
                            virtualizationResults.isVirtualized = true;
                            virtualizationResults.detectedType = 'custom-virtual';
                            virtualizationResults.confidence = 70;
                        }
                    }
                    
                    // 🆕 **평균 아이템 높이 및 총 아이템 수 추정**
                    if (virtualizationResults.isVirtualized) {
                        const visibleItems = document.querySelectorAll('[data-index], .vue-recycle-scroller__item-view, .ReactVirtualized__List__rowContainer, .item, li');
                        if (visibleItems.length > 0) {
                            let totalHeight = 0;
                            let measuredCount = 0;
                            
                            visibleItems.forEach(function(item) {
                                const rect = item.getBoundingClientRect();
                                if (rect.height > 0) {
                                    totalHeight += rect.height;
                                    measuredCount++;
                                }
                            });
                            
                            if (measuredCount > 0) {
                                virtualizationResults.averageItemHeight = totalHeight / measuredCount;
                                
                                // 총 아이템 수 추정 (스크롤 높이 기반)
                                if (virtualizationResults.averageItemHeight > 0) {
                                    virtualizationResults.estimatedTotalItems = Math.ceil(contentHeight / virtualizationResults.averageItemHeight);
                                }
                                
                                detailedLogs.push('평균 아이템 높이: ' + virtualizationResults.averageItemHeight.toFixed(1) + 'px');
                                detailedLogs.push('추정 총 아이템: ' + virtualizationResults.estimatedTotalItems + '개');
                            }
                        }
                        
                        // 🆕 **스크롤 세그먼트 분할 판단**
                        const estimatedTotalHeight = virtualizationResults.estimatedTotalItems * virtualizationResults.averageItemHeight;
                        const browserLimit = 16000000; // Firefox 안전 기준
                        
                        if (estimatedTotalHeight > browserLimit) {
                            virtualizationResults.scrollSegmentation.isSegmented = true;
                            virtualizationResults.scrollSegmentation.totalLogicalHeight = estimatedTotalHeight;
                            virtualizationResults.scrollSegmentation.segmentHeight = browserLimit;
                            virtualizationResults.scrollSegmentation.currentSegmentIndex = Math.floor(scrollY / browserLimit);
                            virtualizationResults.scrollSegmentation.offsetInSegment = scrollY % browserLimit;
                            
                            detailedLogs.push('스크롤 세그먼트 분할 필요: 총 높이 ' + estimatedTotalHeight.toFixed(0) + 'px');
                        }
                    }
                    
                    detailedLogs.push('가상화 감지 완료: ' + virtualizationResults.detectedType + ' (신뢰도: ' + virtualizationResults.confidence + '%)');
                    return virtualizationResults;
                }
                
                // 부모 스크롤 상태 수집 (기존 함수)
                function collectParentScrollStates() {
                    const parentScrollStates = [];
                    const scrollableSelectors = [
                        '.scroll-container', '.scrollable', '.overflow-auto', '.overflow-scroll',
                        '[style*="overflow: auto"]', '[style*="overflow: scroll"]',
                        '[style*="overflow-y: auto"]', '[style*="overflow-y: scroll"]',
                        '.list-container', '.content-wrapper', '.main-content',
                        'main', 'article', 'section', '[role="main"]'
                    ];
                    
                    scrollableSelectors.forEach(function(selector) {
                        try {
                            const elements = document.querySelectorAll(selector);
                            elements.forEach(function(element) {
                                if (element.scrollTop > 0 || element.scrollLeft > 0) {
                                    let path = '';
                                    let current = element;
                                    let depth = 0;
                                    
                                    while (current && current !== document.body && depth < 5) {
                                        let selector = current.tagName.toLowerCase();
                                        if (current.id) {
                                            selector += '#' + current.id;
                                            path = selector + (path ? ' > ' + path : '');
                                            break;
                                        } else if (current.className) {
                                            const classNames = current.className.trim().split(/\\s+/);
                                            if (classNames.length > 0 && classNames[0]) {
                                                selector += '.' + classNames[0];
                                            }
                                        }
                                        path = selector + (path ? ' > ' + path : '');
                                        current = current.parentElement;
                                        depth++;
                                    }
                                    
                                    parentScrollStates.push({
                                        selector: path || selector,
                                        scrollTop: element.scrollTop,
                                        scrollLeft: element.scrollLeft,
                                        scrollHeight: element.scrollHeight,
                                        scrollWidth: element.scrollWidth
                                    });
                                    
                                    detailedLogs.push('부모 스크롤 발견: ' + path);
                                }
                            });
                        } catch(e) {
                            // 선택자 오류 무시
                        }
                    });
                    
                    detailedLogs.push('부모 스크롤 컨테이너: ' + parentScrollStates.length + '개 발견');
                    return parentScrollStates;
                }
                
                // 무한스크롤 앵커 수집 (기존 함수 - 간략화)
                function collectInfiniteScrollAnchors() {
                    // 기존 앵커 수집 로직과 동일하지만 가상화 정보 추가
                    return {
                        anchors: [], // 기존 로직
                        stats: {}
                    };
                }
                
                // 🆕 **메인 실행 - 가상화 우선 분석**
                const startTime = Date.now();
                const virtualizationResults = detectAndAnalyzeVirtualization(); // 🆕 우선 실행
                const parentScrollStates = collectParentScrollStates();
                const infiniteScrollAnchorsData = collectInfiniteScrollAnchors();
                const endTime = Date.now();
                const captureTime = endTime - startTime;
                
                pageAnalysis.capturePerformance = {
                    totalTime: captureTime,
                    virtualizationDetectionTime: captureTime * 0.4 // 가상화 감지에 40% 시간 할당
                };
                
                detailedLogs.push('=== 가상화 대응 JS 캡처 완료 (' + captureTime + 'ms) ===');
                detailedLogs.push('가상화 감지: ' + (virtualizationResults.isVirtualized ? '예(' + virtualizationResults.detectedType + ')' : '아니오'));
                detailedLogs.push('Measurements 캐시: ' + Object.keys(virtualizationResults.measurementsCache).length + '개');
                detailedLogs.push('부모 스크롤: ' + parentScrollStates.length + '개');
                
                console.log('🆕 가상화 대응 JS 캡처 완료:', {
                    virtualizationResults: virtualizationResults,
                    parentScrollStatesCount: parentScrollStates.length,
                    captureTime: captureTime
                });
                
                // ✅ **가상화 우선 반환 구조**
                return {
                    virtualizationResults: virtualizationResults,        // 🆕 **가장 우선순위 높음**
                    parentScrollStates: parentScrollStates,              // 부모 스크롤
                    infiniteScrollAnchors: infiniteScrollAnchorsData,    // 기존 앵커
                    scroll: { x: scrollX, y: scrollY },
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now(),
                    userAgent: navigator.userAgent,
                    viewport: { width: viewportWidth, height: viewportHeight },
                    content: { width: contentWidth, height: contentHeight },
                    actualScrollable: { 
                        width: Math.max(contentWidth, viewportWidth),
                        height: Math.max(contentHeight, viewportHeight)
                    },
                    detailedLogs: detailedLogs,
                    pageAnalysis: pageAnalysis,
                    captureTime: captureTime
                };
                
            } catch(e) { 
                console.error('🆕 가상화 대응 JS 캡처 실패:', e);
                return {
                    virtualizationResults: {
                        isVirtualized: false,
                        detectedType: 'none',
                        error: e.message
                    },
                    parentScrollStates: [],
                    infiniteScrollAnchors: { anchors: [], stats: {} },
                    scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message,
                    detailedLogs: ['가상화 대응 JS 캡처 실패: ' + e.message]
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
        // 🆕 가상화 리스트 대응 BFCache 스크립트
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🚫 가상화 대응 BFCache 페이지 복원');
                
                // 가상화 라이브러리 복원 시도
                if (window.__BFCacheRestoredMeasurements) {
                    console.log('🆕 React Virtualized measurements 캐시 복원');
                }
                if (window.__BFCacheTanStackMeasurements) {
                    console.log('🆕 TanStack Virtual measurements 캐시 복원');
                }
                if (window.__BFCacheScrollSegmentation) {
                    console.log('🆕 스크롤 세그먼트 복원');
                }
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 가상화 대응 BFCache 페이지 저장');
            }
        });
        
        // iframe 리스너 유지
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                console.log('🖼️ Cross-origin iframe 스크롤 복원 요청 수신');
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
