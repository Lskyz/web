//
//  BFCacheSnapshotManager.swift
//  📸 **프레임워크별 가상화 리스트 복원 시스템**
//  🎯 **Step 1**: 프레임워크 감지 및 가상화 리스트 식별
//  📏 **Step 2**: 프레임워크별 맞춤 복원 전략 실행  
//  🔍 **Step 3**: 가상 스크롤 포지션 정밀 복원
//  ✅ **Step 4**: 최종 검증 및 미세 보정
//  ⏰ **렌더링 대기**: 각 단계별 필수 대기시간 적용
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용
//  🚀 **프레임워크별 최적화**: Vue, React, Next.js, Angular 등 맞춤 복원
//  🎨 **가상화 라이브러리 감지**: react-window, tanstack-virtual, vue-virtual-scroller 등

import UIKit
import WebKit
import SwiftUI

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 프레임워크 타입 정의
enum FrameworkType: String, Codable {
    case vue = "vue"
    case react = "react"
    case nextjs = "nextjs"
    case angular = "angular"
    case svelte = "svelte"
    case vanilla = "vanilla"
    case unknown = "unknown"
}

// MARK: - 가상화 라이브러리 타입
enum VirtualizationLibrary: String, Codable {
    case reactWindow = "react-window"
    case reactVirtualized = "react-virtualized"
    case tanstackVirtual = "tanstack-virtual"
    case vueVirtualScroller = "vue-virtual-scroller"
    case vueVirtualScrollList = "vue-virtual-scroll-list"
    case angularCdkScrolling = "angular-cdk-scrolling"
    case virtualScroll = "virtual-scroll"
    case none = "none"
}

// MARK: - 📸 **프레임워크별 맞춤 BFCache 페이지 스냅샷**
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
    
    // 🎯 **프레임워크 정보**
    let frameworkInfo: FrameworkInfo
    
    // 🔄 **순차 실행 설정**
    let restorationConfig: RestorationConfig
    
    struct FrameworkInfo: Codable {
        let type: FrameworkType
        let version: String?
        let virtualizationLib: VirtualizationLibrary
        let hasVirtualScroll: Bool
        let virtualScrollInfo: VirtualScrollInfo?
        let detectedLibraries: [String]
    }
    
    struct VirtualScrollInfo: Codable {
        let containerSelector: String?
        let itemSelector: String?
        let scrollOffset: Int
        let startIndex: Int
        let endIndex: Int
        let itemCount: Int
        let estimatedItemSize: Double
        let overscan: Int
        let scrollDirection: String // "vertical" or "horizontal"
        let measurementCache: [String: Any]?
        let visibleRange: [Int]
        
        enum CodingKeys: String, CodingKey {
            case containerSelector, itemSelector, scrollOffset, startIndex
            case endIndex, itemCount, estimatedItemSize, overscan
            case scrollDirection, measurementCache, visibleRange
        }
        
        // Direct initializer
        init(containerSelector: String?,
             itemSelector: String?,
             scrollOffset: Int,
             startIndex: Int,
             endIndex: Int,
             itemCount: Int,
             estimatedItemSize: Double,
             overscan: Int,
             scrollDirection: String,
             measurementCache: [String: Any]?,
             visibleRange: [Int]) {
            self.containerSelector = containerSelector
            self.itemSelector = itemSelector
            self.scrollOffset = scrollOffset
            self.startIndex = startIndex
            self.endIndex = endIndex
            self.itemCount = itemCount
            self.estimatedItemSize = estimatedItemSize
            self.overscan = overscan
            self.scrollDirection = scrollDirection
            self.measurementCache = measurementCache
            self.visibleRange = visibleRange
        }
        
        // Custom encoding/decoding for measurementCache
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            containerSelector = try container.decodeIfPresent(String.self, forKey: .containerSelector)
            itemSelector = try container.decodeIfPresent(String.self, forKey: .itemSelector)
            scrollOffset = try container.decode(Int.self, forKey: .scrollOffset)
            startIndex = try container.decode(Int.self, forKey: .startIndex)
            endIndex = try container.decode(Int.self, forKey: .endIndex)
            itemCount = try container.decode(Int.self, forKey: .itemCount)
            estimatedItemSize = try container.decode(Double.self, forKey: .estimatedItemSize)
            overscan = try container.decode(Int.self, forKey: .overscan)
            scrollDirection = try container.decode(String.self, forKey: .scrollDirection)
            visibleRange = try container.decode([Int].self, forKey: .visibleRange)
            
            if let cacheData = try container.decodeIfPresent(Data.self, forKey: .measurementCache) {
                measurementCache = try JSONSerialization.jsonObject(with: cacheData) as? [String: Any]
            } else {
                measurementCache = nil
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(containerSelector, forKey: .containerSelector)
            try container.encodeIfPresent(itemSelector, forKey: .itemSelector)
            try container.encode(scrollOffset, forKey: .scrollOffset)
            try container.encode(startIndex, forKey: .startIndex)
            try container.encode(endIndex, forKey: .endIndex)
            try container.encode(itemCount, forKey: .itemCount)
            try container.encode(estimatedItemSize, forKey: .estimatedItemSize)
            try container.encode(overscan, forKey: .overscan)
            try container.encode(scrollDirection, forKey: .scrollDirection)
            try container.encode(visibleRange, forKey: .visibleRange)
            
            if let cache = measurementCache {
                let cacheData = try JSONSerialization.data(withJSONObject: cache)
                try container.encode(cacheData, forKey: .measurementCache)
            }
        }
    }
    
    struct RestorationConfig: Codable {
        let enableFrameworkDetection: Bool   // Step 1 활성화
        let enableVirtualScrollRestore: Bool // Step 2 활성화  
        let enableAnchorRestore: Bool        // Step 3 활성화
        let enableFinalVerification: Bool    // Step 4 활성화
        let savedContentHeight: CGFloat
        let step1RenderDelay: Double
        let step2RenderDelay: Double
        let step3RenderDelay: Double
        let step4RenderDelay: Double
        let enableLazyLoadingTrigger: Bool
        let enableParentScrollRestore: Bool
        let enableIOVerification: Bool
        let frameworkSpecificDelay: Double   // 프레임워크별 추가 대기
        
        static let `default` = RestorationConfig(
            enableFrameworkDetection: true,
            enableVirtualScrollRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: 0,
            step1RenderDelay: 0.3,
            step2RenderDelay: 0.3,
            step3RenderDelay: 0.3,
            step4RenderDelay: 0.2,
            enableLazyLoadingTrigger: true,
            enableParentScrollRestore: true,
            enableIOVerification: true,
            frameworkSpecificDelay: 0.2
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
        case frameworkInfo, restorationConfig
    }
    
    // Custom encoding/decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        scrollPositionPercent = try container.decodeIfPresent(CGPoint.self, forKey: .scrollPositionPercent) ?? CGPoint.zero
        contentSize = try container.decodeIfPresent(CGSize.self, forKey: .contentSize) ?? CGSize.zero
        viewportSize = try container.decodeIfPresent(CGSize.self, forKey: .viewportSize) ?? CGSize.zero
        actualScrollableSize = try container.decodeIfPresent(CGSize.self, forKey: .actualScrollableSize) ?? CGSize.zero
        frameworkInfo = try container.decode(FrameworkInfo.self, forKey: .frameworkInfo)
        restorationConfig = try container.decodeIfPresent(RestorationConfig.self, forKey: .restorationConfig) ?? RestorationConfig.default
        
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
        try container.encode(frameworkInfo, forKey: .frameworkInfo)
        try container.encode(restorationConfig, forKey: .restorationConfig)
        
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
    }
    
    // 직접 초기화용 init
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
         frameworkInfo: FrameworkInfo,
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
        self.frameworkInfo = frameworkInfo
        self.restorationConfig = RestorationConfig(
            enableFrameworkDetection: restorationConfig.enableFrameworkDetection,
            enableVirtualScrollRestore: restorationConfig.enableVirtualScrollRestore,
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
            frameworkSpecificDelay: restorationConfig.frameworkSpecificDelay
        )
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // MARK: - 🎯 **프레임워크별 순차적 복원 시스템**
    
    private struct RestorationContext {
        let snapshot: BFCacheSnapshot
        weak var webView: WKWebView?
        let completion: (Bool) -> Void
        var overallSuccess: Bool = false
    }
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 프레임워크별 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("🎨 감지된 프레임워크: \(frameworkInfo.type.rawValue) \(frameworkInfo.version ?? "")")
        TabPersistenceManager.debugMessages.append("📚 가상화 라이브러리: \(frameworkInfo.virtualizationLib.rawValue)")
        TabPersistenceManager.debugMessages.append("🎯 가상 스크롤 여부: \(frameworkInfo.hasVirtualScroll)")
        
        if let virtualInfo = frameworkInfo.virtualScrollInfo {
            TabPersistenceManager.debugMessages.append("📊 가상 스크롤 정보:")
            TabPersistenceManager.debugMessages.append("  - 표시 범위: \(virtualInfo.startIndex)-\(virtualInfo.endIndex)")
            TabPersistenceManager.debugMessages.append("  - 전체 아이템: \(virtualInfo.itemCount)")
            TabPersistenceManager.debugMessages.append("  - 스크롤 오프셋: \(virtualInfo.scrollOffset)")
        }
        
        let context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: completion
        )
        
        executeStep1_FrameworkDetectionAndPrepare(context: context)
    }
    
    // MARK: - Step 1: 프레임워크 감지 및 준비
    private func executeStep1_FrameworkDetectionAndPrepare(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🎨 [Step 1] 프레임워크별 복원 준비 시작")
        
        guard restorationConfig.enableFrameworkDetection else {
            TabPersistenceManager.debugMessages.append("🎨 [Step 1] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step1RenderDelay) {
                self.executeStep2_VirtualScrollRestore(context: context)
            }
            return
        }
        
        let js = generateStep1_FrameworkPrepareScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step1Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🎨 [Step 1] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step1Success = (resultDict["success"] as? Bool) ?? false
                
                if let framework = resultDict["framework"] as? String {
                    TabPersistenceManager.debugMessages.append("🎨 [Step 1] 현재 프레임워크: \(framework)")
                }
                
                if let virtualScrollDetected = resultDict["virtualScrollDetected"] as? Bool {
                    TabPersistenceManager.debugMessages.append("🎨 [Step 1] 가상 스크롤 감지: \(virtualScrollDetected)")
                }
                
                if let virtualLibrary = resultDict["virtualLibrary"] as? String {
                    TabPersistenceManager.debugMessages.append("🎨 [Step 1] 가상화 라이브러리: \(virtualLibrary)")
                }
                
                if let prepared = resultDict["prepared"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🎨 [Step 1] 준비 완료 항목: \(Array(prepared.keys))")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🎨 [Step 1] 완료: \(step1Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 1] 렌더링 대기: \(self.restorationConfig.step1RenderDelay)초")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step1RenderDelay) {
                self.executeStep2_VirtualScrollRestore(context: context)
            }
        }
    }
    
    // MARK: - Step 2: 가상 스크롤 복원
    private func executeStep2_VirtualScrollRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🎯 [Step 2] 가상 스크롤 복원 시작")
        
        guard restorationConfig.enableVirtualScrollRestore,
              frameworkInfo.hasVirtualScroll,
              let virtualInfo = frameworkInfo.virtualScrollInfo else {
            TabPersistenceManager.debugMessages.append("🎯 [Step 2] 가상 스크롤 없음 - 일반 스크롤 복원")
            executeNormalScrollRestore(context: context)
            return
        }
        
        let virtualDataJSON: String
        if let measurementCache = virtualInfo.measurementCache,
           let jsonData = try? JSONSerialization.data(withJSONObject: measurementCache),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            virtualDataJSON = jsonString
        } else {
            virtualDataJSON = "{}"
        }
        
        let js = generateStep2_VirtualScrollRestoreScript(
            virtualInfo: virtualInfo,
            virtualDataJSON: virtualDataJSON
        )
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step2Success = false
            var updatedContext = context
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🎯 [Step 2] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step2Success = (resultDict["success"] as? Bool) ?? false
                
                if let restoredOffset = resultDict["restoredOffset"] as? Int {
                    TabPersistenceManager.debugMessages.append("🎯 [Step 2] 복원된 오프셋: \(restoredOffset)")
                }
                
                if let visibleRange = resultDict["visibleRange"] as? [Int] {
                    TabPersistenceManager.debugMessages.append("🎯 [Step 2] 표시 범위: \(visibleRange)")
                }
                
                if let itemsRendered = resultDict["itemsRendered"] as? Int {
                    TabPersistenceManager.debugMessages.append("🎯 [Step 2] 렌더링된 아이템: \(itemsRendered)")
                }
                
                if step2Success {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("🎯 [Step 2] ✅ 가상 스크롤 복원 성공")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🎯 [Step 2] 완료: \(step2Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 2] 렌더링 대기: \(self.restorationConfig.step2RenderDelay)초")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step2RenderDelay) {
                self.executeStep3_AnchorRestore(context: updatedContext)
            }
        }
    }
    
    // 일반 스크롤 복원 (가상 스크롤이 없는 경우)
    private func executeNormalScrollRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📏 일반 스크롤 복원 시작")
        
        let js = generateNormalScrollRestoreScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var success = false
            var updatedContext = context
            
            if let resultDict = result as? [String: Any] {
                success = (resultDict["success"] as? Bool) ?? false
                if success {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("📏 ✅ 일반 스크롤 복원 성공")
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step2RenderDelay) {
                self.executeStep3_AnchorRestore(context: updatedContext)
            }
        }
    }
    
    // MARK: - Step 3: 앵커 복원
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 앵커 기반 정밀 복원 시작")
        
        guard restorationConfig.enableAnchorRestore else {
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step3RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
            return
        }
        
        var anchorDataJSON = "null"
        if let jsState = self.jsState,
           let anchorData = jsState["infiniteScrollAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(anchorData) {
            anchorDataJSON = dataJSON
        }
        
        let js = generateStep3_AnchorRestoreScript(anchorDataJSON: anchorDataJSON)
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step3Success = false
            
            if let resultDict = result as? [String: Any] {
                step3Success = (resultDict["success"] as? Bool) ?? false
                
                if let anchorCount = resultDict["anchorCount"] as? Int {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 사용 가능한 앵커: \(anchorCount)개")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 완료: \(step3Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 3] 렌더링 대기: \(self.restorationConfig.step3RenderDelay)초")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step3RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
        }
    }
    
    // MARK: - Step 4: 최종 검증
    private func executeStep4_FinalVerification(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 검증 및 미세 보정 시작")
        
        guard restorationConfig.enableFinalVerification else {
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 비활성화됨 - 스킵")
            context.completion(context.overallSuccess)
            return
        }
        
        let js = generateStep4_FinalVerificationScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step4Success = false
            
            if let resultDict = result as? [String: Any] {
                step4Success = (resultDict["success"] as? Bool) ?? false
                
                if let finalPosition = resultDict["finalPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 위치: Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
                }
            }
            
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 완료: \(step4Success ? "성공" : "실패")")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step4RenderDelay) {
                let finalSuccess = context.overallSuccess || step4Success
                TabPersistenceManager.debugMessages.append("🎯 전체 BFCache 복원 완료: \(finalSuccess ? "성공" : "실패")")
                context.completion(finalSuccess)
            }
        }
    }
    
    // MARK: - JavaScript 생성 메서드들
    
    private func generateStep1_FrameworkPrepareScript() -> String {
        return """
        (function() {
            try {
                const logs = [];
                
                // 프레임워크 감지 함수
                function detectFramework() {
                    // Vue 감지
                    if (typeof window.Vue !== 'undefined' || window.__VUE__) {
                        const version = window.Vue?.version || window.__VUE__?.version || 'unknown';
                        return { name: 'vue', version: version };
                    }
                    
                    // React 감지
                    if (window.React || window._react) {
                        return { name: 'react', version: window.React?.version || 'unknown' };
                    }
                    
                    // React DOM roots (React 18+)
                    const allElements = document.querySelectorAll('*');
                    for (let element of allElements) {
                        if (element._reactRootContainer || element.__reactContainer) {
                            return { name: 'react', version: '18+' };
                        }
                    }
                    
                    // Next.js 감지
                    if (window.__NEXT_DATA__ || document.getElementById('__next')) {
                        return { name: 'nextjs', version: window.__NEXT_DATA__?.buildId || 'unknown' };
                    }
                    
                    // Angular 감지
                    if (window.ng || window.getAllAngularTestabilities) {
                        return { name: 'angular', version: window.ng?.VERSION?.full || 'unknown' };
                    }
                    
                    // Svelte 감지
                    if (window.__svelte) {
                        return { name: 'svelte', version: 'unknown' };
                    }
                    
                    return { name: 'vanilla', version: null };
                }
                
                // 가상화 라이브러리 감지
                function detectVirtualizationLibrary() {
                    // React Window
                    if (document.querySelector('[data-react-window]') || 
                        document.querySelector('[style*="position: absolute"][style*="top:"][style*="height:"]')) {
                        return 'react-window';
                    }
                    
                    // React Virtualized
                    if (document.querySelector('.ReactVirtualized__Grid') ||
                        document.querySelector('.ReactVirtualized__List')) {
                        return 'react-virtualized';
                    }
                    
                    // TanStack Virtual
                    if (document.querySelector('[data-tanstack-virtual]') ||
                        (window.TanStack && window.TanStack.Virtual)) {
                        return 'tanstack-virtual';
                    }
                    
                    // Vue Virtual Scroller
                    if (document.querySelector('.vue-recycle-scroller') ||
                        document.querySelector('.vue-virtual-scroller')) {
                        return 'vue-virtual-scroller';
                    }
                    
                    // Angular CDK
                    if (document.querySelector('cdk-virtual-scroll-viewport')) {
                        return 'angular-cdk-scrolling';
                    }
                    
                    return 'none';
                }
                
                // 가상 스크롤 컨테이너 찾기
                function findVirtualScrollContainer() {
                    const selectors = [
                        // React Window/Virtualized
                        '[style*="overflow: auto"][style*="will-change"]',
                        '[style*="overflow: auto"][style*="position: relative"]',
                        '.ReactVirtualized__Grid',
                        '.ReactVirtualized__List',
                        
                        // Vue Virtual Scroller  
                        '.vue-recycle-scroller',
                        '.vue-virtual-scroller',
                        '.virtual-list',
                        
                        // Angular CDK
                        'cdk-virtual-scroll-viewport',
                        
                        // Generic
                        '[data-virtual-scroll]',
                        '[data-virtualized]',
                        '.virtual-scroll',
                        '.virtualized-list'
                    ];
                    
                    for (let selector of selectors) {
                        const container = document.querySelector(selector);
                        if (container) return container;
                    }
                    
                    return null;
                }
                
                const framework = detectFramework();
                const virtualLib = detectVirtualizationLibrary();
                const virtualContainer = findVirtualScrollContainer();
                
                logs.push('감지된 프레임워크: ' + framework.name + ' ' + (framework.version || ''));
                logs.push('가상화 라이브러리: ' + virtualLib);
                logs.push('가상 스크롤 컨테이너: ' + (virtualContainer ? '발견' : '없음'));
                
                // 프레임워크별 준비 작업
                const prepared = {};
                
                // Vue 준비
                if (framework.name === 'vue') {
                    if (window.Vue && window.Vue.nextTick) {
                        window.Vue.nextTick(() => {
                            console.log('Vue nextTick 실행됨');
                        });
                        prepared.vueNextTick = true;
                    }
                }
                
                // React 준비
                if (framework.name === 'react' || framework.name === 'nextjs') {
                    // React 컴포넌트 강제 업데이트 트리거
                    window.dispatchEvent(new Event('resize'));
                    prepared.reactResize = true;
                }
                
                // 가상 스크롤 준비
                if (virtualContainer) {
                    // 스크롤 이벤트 트리거로 가상화 라이브러리 활성화
                    virtualContainer.dispatchEvent(new Event('scroll', { bubbles: true }));
                    prepared.virtualScroll = true;
                }
                
                return {
                    success: true,
                    framework: framework.name,
                    frameworkVersion: framework.version,
                    virtualLibrary: virtualLib,
                    virtualScrollDetected: virtualContainer !== null,
                    prepared: prepared,
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
    
    private func generateStep2_VirtualScrollRestoreScript(virtualInfo: BFCacheSnapshot.VirtualScrollInfo, virtualDataJSON: String) -> String {
        return """
        (function() {
            try {
                const logs = [];
                const virtualInfo = {
                    scrollOffset: \(virtualInfo.scrollOffset),
                    startIndex: \(virtualInfo.startIndex),
                    endIndex: \(virtualInfo.endIndex),
                    itemCount: \(virtualInfo.itemCount),
                    estimatedItemSize: \(virtualInfo.estimatedItemSize),
                    overscan: \(virtualInfo.overscan),
                    direction: '\(virtualInfo.scrollDirection)'
                };
                const measurementCache = \(virtualDataJSON);
                
                logs.push('[Step 2] 가상 스크롤 복원 시작');
                logs.push('목표 오프셋: ' + virtualInfo.scrollOffset);
                logs.push('목표 범위: ' + virtualInfo.startIndex + '-' + virtualInfo.endIndex);
                
                // 가상 스크롤 컨테이너 찾기
                const container = document.querySelector('[style*="overflow: auto"]') ||
                                document.querySelector('.virtual-scroll') ||
                                document.querySelector('[data-virtual-scroll]');
                
                if (!container) {
                    logs.push('가상 스크롤 컨테이너를 찾을 수 없음');
                    return { success: false, logs: logs };
                }
                
                // 프레임워크별 복원 전략
                let restored = false;
                let restoredOffset = 0;
                let visibleRange = [];
                
                // React Window/Virtualized 복원
                if (window.React || window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
                    // React 컴포넌트 인스턴스 찾기
                    const fiber = container._reactInternalFiber || 
                                container._reactRootContainer?.current;
                    
                    if (fiber) {
                        // scrollOffset 직접 설정 시도
                        container.scrollTop = virtualInfo.scrollOffset;
                        
                        // 강제 리렌더링
                        window.dispatchEvent(new Event('resize'));
                        
                        restored = true;
                        restoredOffset = container.scrollTop;
                        logs.push('React 가상 스크롤 복원 완료');
                    }
                }
                
                // Vue Virtual Scroller 복원
                if (window.Vue || window.__VUE__) {
                    const vueInstance = container.__vue__ || container.__vueParentComponent;
                    
                    if (vueInstance && vueInstance.$refs) {
                        // Vue 가상 스크롤러 API 사용
                        if (vueInstance.scrollToPosition) {
                            vueInstance.scrollToPosition(virtualInfo.scrollOffset);
                            restored = true;
                            restoredOffset = virtualInfo.scrollOffset;
                            logs.push('Vue 가상 스크롤 복원 완료');
                        }
                    }
                }
                
                // TanStack Virtual 복원
                if (window.TanStack?.Virtual) {
                    // TanStack Virtual은 initialOffset을 통해 복원
                    container.scrollTop = virtualInfo.scrollOffset;
                    restored = true;
                    restoredOffset = container.scrollTop;
                    logs.push('TanStack Virtual 복원 완료');
                }
                
                // 일반 폴백 전략
                if (!restored) {
                    // 직접 스크롤 설정
                    container.scrollTop = virtualInfo.scrollOffset;
                    
                    // 가상 아이템 강제 렌더링
                    const itemHeight = virtualInfo.estimatedItemSize;
                    const containerHeight = container.clientHeight;
                    const startIndex = Math.floor(virtualInfo.scrollOffset / itemHeight);
                    const endIndex = Math.ceil((virtualInfo.scrollOffset + containerHeight) / itemHeight);
                    
                    visibleRange = [startIndex, endIndex];
                    restoredOffset = container.scrollTop;
                    
                    // 스크롤 이벤트 디스패치
                    container.dispatchEvent(new Event('scroll', { bubbles: true }));
                    
                    logs.push('폴백 전략으로 복원: ' + startIndex + '-' + endIndex);
                    restored = true;
                }
                
                // 측정 캐시 복원
                if (measurementCache && Object.keys(measurementCache).length > 0) {
                    // 캐시 데이터를 가상화 라이브러리에 주입
                    if (window.__virtualScrollCache) {
                        Object.assign(window.__virtualScrollCache, measurementCache);
                        logs.push('측정 캐시 복원됨: ' + Object.keys(measurementCache).length + '개');
                    }
                }
                
                // 렌더링된 아이템 수 계산
                const renderedItems = container.querySelectorAll('[style*="position: absolute"]').length ||
                                    container.querySelectorAll('.virtual-item').length;
                
                logs.push('렌더링된 아이템: ' + renderedItems + '개');
                logs.push('복원된 오프셋: ' + restoredOffset);
                
                return {
                    success: restored,
                    restoredOffset: restoredOffset,
                    visibleRange: visibleRange.length > 0 ? visibleRange : [virtualInfo.startIndex, virtualInfo.endIndex],
                    itemsRendered: renderedItems,
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
    
    private func generateNormalScrollRestoreScript() -> String {
        let targetY = scrollPosition.y
        let targetPercentY = scrollPositionPercent.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetY = \(targetY);
                const targetPercentY = \(targetPercentY);
                
                logs.push('일반 스크롤 복원');
                logs.push('목표 위치: Y=' + targetY + 'px (' + targetPercentY + '%)');
                
                // 콘텐츠 높이 확인 및 최대값 수정
                const contentHeight = Math.max(
                    document.documentElement.scrollHeight,
                    document.body.scrollHeight,
                    document.documentElement.offsetHeight,
                    document.body.offsetHeight
                );
                const viewportHeight = window.innerHeight;
                const maxScrollY = Math.max(0, contentHeight - viewportHeight);
                
                // 스크롤 가능 거리가 축소되었는지 확인
                if (maxScrollY < targetY) {
                    logs.push('⚠️ 최대 스크롤 거리 축소 감지: ' + maxScrollY + ' < ' + targetY);
                    
                    // 콘텐츠 로딩 트리거
                    window.scrollTo(0, maxScrollY);
                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                    window.dispatchEvent(new Event('scrollend', { bubbles: true }));
                    
                    // IntersectionObserver 트리거
                    if (window.IntersectionObserver) {
                        const sentinel = document.createElement('div');
                        sentinel.style.height = '1px';
                        document.body.appendChild(sentinel);
                        
                        const observer = new IntersectionObserver((entries) => {
                            entries.forEach(entry => {
                                if (entry.isIntersecting) {
                                    window.dispatchEvent(new Event('scroll'));
                                }
                            });
                        });
                        
                        observer.observe(sentinel);
                        setTimeout(() => {
                            document.body.removeChild(sentinel);
                        }, 100);
                    }
                }
                
                // 백분율 기반 복원 (축소된 경우 사용)
                const calculatedY = (targetPercentY / 100) * maxScrollY;
                const finalY = Math.min(targetY, calculatedY, maxScrollY);
                
                window.scrollTo(0, finalY);
                document.documentElement.scrollTop = finalY;
                document.body.scrollTop = finalY;
                
                const actualY = window.scrollY || window.pageYOffset || 0;
                const diffY = Math.abs(actualY - targetY);
                
                logs.push('복원된 위치: Y=' + actualY + 'px');
                logs.push('위치 차이: ' + diffY + 'px');
                
                return {
                    success: diffY <= 50,
                    targetPosition: { y: targetY },
                    actualPosition: { y: actualY },
                    difference: { y: diffY },
                    maxScroll: { y: maxScrollY },
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message
                };
            }
        })()
        """
    }
    
    private func generateStep3_AnchorRestoreScript(anchorDataJSON: String) -> String {
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetY = \(targetY);
                const anchorData = \(anchorDataJSON);
                
                logs.push('[Step 3] 앵커 기반 복원');
                
                if (!anchorData || !anchorData.anchors || anchorData.anchors.length === 0) {
                    logs.push('앵커 데이터 없음');
                    return { success: false, anchorCount: 0, logs: logs };
                }
                
                const anchors = anchorData.anchors;
                let foundElement = null;
                let matchedAnchor = null;
                
                // 앵커 매칭 시도
                for (let anchor of anchors) {
                    if (anchor.anchorType === 'vueComponent' && anchor.vueComponent) {
                        const selector = '[' + anchor.vueComponent.dataV + ']';
                        const elements = document.querySelectorAll(selector);
                        if (elements.length > 0) {
                            foundElement = elements[0];
                            matchedAnchor = anchor;
                            break;
                        }
                    } else if (anchor.anchorType === 'contentHash' && anchor.contentHash) {
                        const searchText = anchor.contentHash.text?.substring(0, 50);
                        if (searchText) {
                            const allElements = document.querySelectorAll('*');
                            for (let element of allElements) {
                                if (element.textContent?.includes(searchText)) {
                                    foundElement = element;
                                    matchedAnchor = anchor;
                                    break;
                                }
                            }
                        }
                    }
                }
                
                if (foundElement && matchedAnchor) {
                    foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                    
                    if (matchedAnchor.offsetFromTop) {
                        window.scrollBy(0, -matchedAnchor.offsetFromTop);
                    }
                    
                    const actualY = window.scrollY || window.pageYOffset || 0;
                    const diffY = Math.abs(actualY - targetY);
                    
                    logs.push('앵커 매칭 성공');
                    logs.push('복원 위치: ' + actualY);
                    
                    return {
                        success: diffY <= 100,
                        anchorCount: anchors.length,
                        restoredPosition: { y: actualY },
                        logs: logs
                    };
                }
                
                logs.push('앵커 매칭 실패');
                return {
                    success: false,
                    anchorCount: anchors.length,
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message
                };
            }
        })()
        """
    }
    
    private func generateStep4_FinalVerificationScript() -> String {
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetY = \(targetY);
                
                logs.push('[Step 4] 최종 검증');
                
                const currentY = window.scrollY || window.pageYOffset || 0;
                const diffY = Math.abs(currentY - targetY);
                
                if (diffY > 30) {
                    window.scrollTo(0, targetY);
                    logs.push('미세 보정 적용');
                }
                
                const finalY = window.scrollY || window.pageYOffset || 0;
                const finalDiffY = Math.abs(finalY - targetY);
                
                return {
                    success: finalDiffY <= 50,
                    targetPosition: { y: targetY },
                    finalPosition: { y: finalY },
                    difference: { y: finalDiffY },
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message
                };
            }
        })()
        """
    }
    
    // 유틸리티 메서드
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
    
    // MARK: - 🔧 **프레임워크 인식 캡처 작업**
    
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
        
        TabPersistenceManager.debugMessages.append("🎨 프레임워크 인식 캡처 시작: \(pageRecord.url.host ?? "unknown")")
        
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        guard let webView = task.webView else {
            TabPersistenceManager.debugMessages.append("❌ 웹뷰 해제됨 - 캡처 취소")
            return
        }
        
        TabPersistenceManager.debugMessages.append("🎨 캡처 실행: \(task.pageRecord.title)")
        
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨")
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
        
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        // 프레임워크 정보 로깅
        TabPersistenceManager.debugMessages.append("🎨 감지된 프레임워크: \(captureResult.snapshot.frameworkInfo.type.rawValue)")
        TabPersistenceManager.debugMessages.append("🎨 가상화 라이브러리: \(captureResult.snapshot.frameworkInfo.virtualizationLib.rawValue)")
        
        if let virtualInfo = captureResult.snapshot.frameworkInfo.virtualScrollInfo {
            TabPersistenceManager.debugMessages.append("🎯 가상 스크롤 정보:")
            TabPersistenceManager.debugMessages.append("  - 아이템 수: \(virtualInfo.itemCount)")
            TabPersistenceManager.debugMessages.append("  - 표시 범위: \(virtualInfo.startIndex)-\(virtualInfo.endIndex)")
            TabPersistenceManager.debugMessages.append("  - 스크롤 오프셋: \(virtualInfo.scrollOffset)")
        }
        
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize
        let viewportSize: CGSize
        let actualScrollableSize: CGSize
        let bounds: CGRect
        let isLoading: Bool
    }
    
    private func performRobustCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    TabPersistenceManager.debugMessages.append("🔄 재시도 후 캐처 성공 (시도: \(attempt + 1))")
                }
                return result
            }
            
            TabPersistenceManager.debugMessages.append("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1))")
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        // 기본 프레임워크 정보
        let defaultFrameworkInfo = BFCacheSnapshot.FrameworkInfo(
            type: .unknown,
            version: nil,
            virtualizationLib: .none,
            hasVirtualScroll: false,
            virtualScrollInfo: nil,
            detectedLibraries: []
        )
        
        return (BFCacheSnapshot(
            pageRecord: pageRecord,
            scrollPosition: captureData.scrollPosition,
            actualScrollableSize: captureData.actualScrollableSize,
            timestamp: Date(),
            captureStatus: .failed,
            version: 1,
            frameworkInfo: defaultFrameworkInfo
        ), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var frameworkInfo: BFCacheSnapshot.FrameworkInfo?
        let semaphore = DispatchSemaphore(value: 0)
        
        TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 시도")
        
        // 1. 비주얼 스냅샷
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
                }
                semaphore.signal()
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 3.0)
        
        // 2. DOM 캡처
        let domSemaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    var html = document.documentElement.outerHTML;
                    return html.length > 100000 ? html.substring(0, 100000) : html;
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                if let dom = result as? String {
                    domSnapshot = dom
                }
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 2.0)
        
        // 3. 프레임워크 감지 및 JS 상태 캡처
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🎨 프레임워크 감지 및 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateFrameworkDetectionAndCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    
                    // 프레임워크 정보 파싱
                    if let frameworkData = data["frameworkInfo"] as? [String: Any] {
                        let type = FrameworkType(rawValue: frameworkData["type"] as? String ?? "unknown") ?? .unknown
                        let version = frameworkData["version"] as? String
                        let virtLib = VirtualizationLibrary(rawValue: frameworkData["virtualizationLib"] as? String ?? "none") ?? .none
                        let hasVirtual = frameworkData["hasVirtualScroll"] as? Bool ?? false
                        let libraries = frameworkData["detectedLibraries"] as? [String] ?? []
                        
                        var virtualScrollInfo: BFCacheSnapshot.VirtualScrollInfo? = nil
                        if let virtualData = frameworkData["virtualScrollInfo"] as? [String: Any] {
                            virtualScrollInfo = BFCacheSnapshot.VirtualScrollInfo(
                                containerSelector: virtualData["containerSelector"] as? String,
                                itemSelector: virtualData["itemSelector"] as? String,
                                scrollOffset: virtualData["scrollOffset"] as? Int ?? 0,
                                startIndex: virtualData["startIndex"] as? Int ?? 0,
                                endIndex: virtualData["endIndex"] as? Int ?? 0,
                                itemCount: virtualData["itemCount"] as? Int ?? 0,
                                estimatedItemSize: virtualData["estimatedItemSize"] as? Double ?? 50,
                                overscan: virtualData["overscan"] as? Int ?? 5,
                                scrollDirection: virtualData["scrollDirection"] as? String ?? "vertical",
                                measurementCache: virtualData["measurementCache"] as? [String: Any],
                                visibleRange: virtualData["visibleRange"] as? [Int] ?? []
                            )
                        }
                        
                        frameworkInfo = BFCacheSnapshot.FrameworkInfo(
                            type: type,
                            version: version,
                            virtualizationLib: virtLib,
                            hasVirtualScroll: hasVirtual,
                            virtualScrollInfo: virtualScrollInfo,
                            detectedLibraries: libraries
                        )
                    }
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 2.0)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 버전 증가
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        // 백분율 계산
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.height > captureData.viewportSize.height {
            let maxScrollY = max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height)
            scrollPercent = CGPoint(
                x: 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        // 프레임워크 정보가 없으면 기본값 사용
        if frameworkInfo == nil {
            frameworkInfo = BFCacheSnapshot.FrameworkInfo(
                type: .unknown,
                version: nil,
                virtualizationLib: .none,
                hasVirtualScroll: false,
                virtualScrollInfo: nil,
                detectedLibraries: []
            )
        }
        
        // 복원 설정 생성
        let restorationConfig = BFCacheSnapshot.RestorationConfig(
            enableFrameworkDetection: true,
            enableVirtualScrollRestore: frameworkInfo?.hasVirtualScroll ?? false,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height),
            step1RenderDelay: 0.3,
            step2RenderDelay: 0.4,
            step3RenderDelay: 0.2,
            step4RenderDelay: 0.3,
            enableLazyLoadingTrigger: true,
            enableParentScrollRestore: true,
            enableIOVerification: true,
            frameworkSpecificDelay: 0.2
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
            frameworkInfo: frameworkInfo!,
            restorationConfig: restorationConfig
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // JavaScript 프레임워크 감지 및 캡처 스크립트
    private func generateFrameworkDetectionAndCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🎨 프레임워크 감지 및 상태 캡처 시작');
                
                const result = {
                    frameworkInfo: {},
                    infiniteScrollAnchors: null,
                    parentScrollStates: [],
                    scroll: { x: window.scrollX || 0, y: window.scrollY || 0 },
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now()
                };
                
                // 프레임워크 감지
                function detectFramework() {
                    // Vue 감지
                    if (typeof window.Vue !== 'undefined' || window.__VUE__) {
                        return {
                            type: 'vue',
                            version: window.Vue?.version || window.__VUE__?.version || null
                        };
                    }
                    
                    // React 감지
                    if (window.React || window._react || window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
                        return {
                            type: 'react',
                            version: window.React?.version || null
                        };
                    }
                    
                    // React DOM roots (React 18+)
                    const allElements = document.querySelectorAll('*');
                    for (let element of allElements) {
                        if (element._reactRootContainer || element.__reactContainer) {
                            return { type: 'react', version: '18+' };
                        }
                    }
                    
                    // Next.js 감지
                    if (window.__NEXT_DATA__ || document.getElementById('__next')) {
                        return {
                            type: 'nextjs',
                            version: window.__NEXT_DATA__?.buildId || null
                        };
                    }
                    
                    // Angular 감지
                    if (window.ng || window.getAllAngularTestabilities) {
                        return {
                            type: 'angular',
                            version: window.ng?.VERSION?.full || null
                        };
                    }
                    
                    // Svelte 감지
                    if (window.__svelte) {
                        return { type: 'svelte', version: null };
                    }
                    
                    return { type: 'vanilla', version: null };
                }
                
                // 가상화 라이브러리 감지
                function detectVirtualization() {
                    const detectedLibs = [];
                    let primaryLib = 'none';
                    
                    // React Window
                    if (document.querySelector('[style*="will-change: transform"][style*="position: absolute"]')) {
                        detectedLibs.push('react-window');
                        primaryLib = 'react-window';
                    }
                    
                    // React Virtualized
                    if (document.querySelector('.ReactVirtualized__Grid') ||
                        document.querySelector('.ReactVirtualized__List')) {
                        detectedLibs.push('react-virtualized');
                        if (primaryLib === 'none') primaryLib = 'react-virtualized';
                    }
                    
                    // TanStack Virtual
                    if (window.TanStack?.Virtual || document.querySelector('[data-tanstack-virtual]')) {
                        detectedLibs.push('tanstack-virtual');
                        if (primaryLib === 'none') primaryLib = 'tanstack-virtual';
                    }
                    
                    // Vue Virtual Scroller
                    if (document.querySelector('.vue-recycle-scroller') ||
                        document.querySelector('.vue-virtual-scroller')) {
                        detectedLibs.push('vue-virtual-scroller');
                        if (primaryLib === 'none') primaryLib = 'vue-virtual-scroller';
                    }
                    
                    // Angular CDK
                    if (document.querySelector('cdk-virtual-scroll-viewport')) {
                        detectedLibs.push('angular-cdk-scrolling');
                        if (primaryLib === 'none') primaryLib = 'angular-cdk-scrolling';
                    }
                    
                    return {
                        primary: primaryLib,
                        all: detectedLibs
                    };
                }
                
                // 가상 스크롤 정보 수집
                function collectVirtualScrollInfo() {
                    const container = document.querySelector('[style*="overflow: auto"][style*="will-change"]') ||
                                    document.querySelector('.virtual-scroll') ||
                                    document.querySelector('[data-virtual-scroll]');
                    
                    if (!container) return null;
                    
                    const items = container.querySelectorAll('[style*="position: absolute"]') ||
                                 container.querySelectorAll('.virtual-item');
                    
                    if (items.length === 0) return null;
                    
                    // 표시 범위 계산
                    const containerRect = container.getBoundingClientRect();
                    const scrollTop = container.scrollTop;
                    const scrollLeft = container.scrollLeft;
                    
                    let startIndex = Infinity;
                    let endIndex = -1;
                    const visibleItems = [];
                    
                    items.forEach((item, index) => {
                        const rect = item.getBoundingClientRect();
                        const relativeTop = rect.top - containerRect.top;
                        
                        if (relativeTop >= 0 && relativeTop <= containerRect.height) {
                            startIndex = Math.min(startIndex, index);
                            endIndex = Math.max(endIndex, index);
                            visibleItems.push(index);
                        }
                    });
                    
                    // 아이템 크기 추정
                    const firstItem = items[0];
                    const estimatedItemSize = firstItem ? 
                        (firstItem.offsetHeight || firstItem.clientHeight || 50) : 50;
                    
                    // 측정 캐시 수집 (간단한 버전)
                    const measurementCache = {};
                    items.forEach((item, index) => {
                        measurementCache[index] = {
                            height: item.offsetHeight || 0,
                            width: item.offsetWidth || 0
                        };
                    });
                    
                    return {
                        containerSelector: container.className || container.tagName.toLowerCase(),
                        itemSelector: items[0]?.className || 'virtual-item',
                        scrollOffset: scrollTop,
                        startIndex: startIndex === Infinity ? 0 : startIndex,
                        endIndex: endIndex === -1 ? items.length - 1 : endIndex,
                        itemCount: items.length,
                        estimatedItemSize: estimatedItemSize,
                        overscan: 5,
                        scrollDirection: 'vertical',
                        measurementCache: measurementCache,
                        visibleRange: visibleItems
                    };
                }
                
                // 부모 스크롤 상태 수집
                function collectParentScrollStates() {
                    const scrollableSelectors = [
                        '.scroll-container', '.scrollable', '[style*="overflow: auto"]',
                        '[style*="overflow: scroll"]', '[style*="overflow-y: auto"]'
                    ];
                    
                    const states = [];
                    scrollableSelectors.forEach(selector => {
                        const elements = document.querySelectorAll(selector);
                        elements.forEach(element => {
                            if (element.scrollTop > 0 || element.scrollLeft > 0) {
                                states.push({
                                    selector: selector,
                                    scrollTop: element.scrollTop,
                                    scrollLeft: element.scrollLeft
                                });
                            }
                        });
                    });
                    
                    return states;
                }
                
                // 앵커 수집 (기존 로직 유지)
                function collectAnchors() {
                    const anchors = [];
                    const viewportY = window.scrollY || 0;
                    const viewportHeight = window.innerHeight;
                    
                    // Vue 컴포넌트 앵커
                    document.querySelectorAll('[data-v-]').forEach((element, index) => {
                        const rect = element.getBoundingClientRect();
                        const absoluteTop = viewportY + rect.top;
                        
                        if (rect.top >= 0 && rect.top <= viewportHeight) {
                            anchors.push({
                                anchorType: 'vueComponent',
                                vueComponent: {
                                    dataV: element.getAttributeNames().find(attr => attr.startsWith('data-v-')),
                                    name: element.className,
                                    index: index
                                },
                                absolutePosition: { top: absoluteTop, left: rect.left },
                                offsetFromTop: viewportY - absoluteTop
                            });
                        }
                    });
                    
                    // 콘텐츠 해시 앵커
                    document.querySelectorAll('li, .item, .list-item').forEach((element, index) => {
                        const text = element.textContent?.trim();
                        if (text && text.length > 20) {
                            const rect = element.getBoundingClientRect();
                            const absoluteTop = viewportY + rect.top;
                            
                            if (rect.top >= 0 && rect.top <= viewportHeight) {
                                anchors.push({
                                    anchorType: 'contentHash',
                                    contentHash: {
                                        text: text.substring(0, 100),
                                        shortHash: text.substring(0, 8)
                                    },
                                    absolutePosition: { top: absoluteTop, left: rect.left },
                                    offsetFromTop: viewportY - absoluteTop
                                });
                            }
                        }
                    });
                    
                    return { anchors: anchors };
                }
                
                // 실행
                const framework = detectFramework();
                const virtualization = detectVirtualization();
                const virtualScrollInfo = collectVirtualScrollInfo();
                
                result.frameworkInfo = {
                    type: framework.type,
                    version: framework.version,
                    virtualizationLib: virtualization.primary,
                    hasVirtualScroll: virtualScrollInfo !== null,
                    virtualScrollInfo: virtualScrollInfo,
                    detectedLibraries: virtualization.all
                };
                
                result.parentScrollStates = collectParentScrollStates();
                result.infiniteScrollAnchors = collectAnchors();
                
                console.log('🎨 프레임워크 감지 완료:', result.frameworkInfo);
                
                return result;
                
            } catch(e) {
                console.error('🎨 프레임워크 감지 실패:', e);
                return {
                    frameworkInfo: { type: 'unknown', version: null },
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
                console.log('🎨 프레임워크 인식 BFCache 페이지 복원');
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 프레임워크 인식 BFCache 페이지 저장');
            }
        });
        
        // 가상 스크롤 측정 캐시 전역 변수
        window.__virtualScrollCache = window.__virtualScrollCache || {};
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
