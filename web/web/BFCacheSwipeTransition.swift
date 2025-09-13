//
//  BFCacheSnapshotManager.swift
//  📸 **순차적 4단계 BFCache 복원 시스템 + Vue.js 특화 무한스크롤 복원**
//  🎯 **Step 1**: 저장 콘텐츠 높이 복원 (동적 사이트만)
//  📏 **Step 2**: 상대좌표 기반 스크롤 복원 (최우선)
//  🔍 **Step 3**: 4요소 패키지 앵커 정밀 복원
//  ✅ **Step 4**: 최종 검증 및 미세 보정
//  🅥 **Vue.js 특화**: 반응형 컴포넌트 감지 & 무한스크롤 복원
//  ⏰ **렌더링 대기**: 각 단계별 필수 대기시간 적용
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용

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
    
    // 🔄 **순차 실행 설정**
    let restorationConfig: RestorationConfig
    
    // 🅥 **Vue.js 특화 설정**
    let vueConfig: VueRestorationConfig
    
    struct RestorationConfig: Codable {
        let enableContentRestore: Bool      // Step 1 활성화
        let enablePercentRestore: Bool      // Step 2 활성화
        let enableAnchorRestore: Bool       // Step 3 활성화
        let enableFinalVerification: Bool   // Step 4 활성화
        let savedContentHeight: CGFloat     // 저장 시점 콘텐츠 높이
        let step1RenderDelay: Double        // Step 1 후 렌더링 대기 (0.8초)
        let step2RenderDelay: Double        // Step 2 후 렌더링 대기 (0.3초)
        let step3RenderDelay: Double        // Step 3 후 렌더링 대기 (0.5초)
        let step4RenderDelay: Double        // Step 4 후 렌더링 대기 (0.3초)
        
        static let `default` = RestorationConfig(
            enableContentRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: 0,
            step1RenderDelay: 0.8,
            step2RenderDelay: 0.3,
            step3RenderDelay: 0.5,
            step4RenderDelay: 0.3
        )
    }
    
    // 🅥 **Vue.js 특화 복원 설정**
    struct VueRestorationConfig: Codable {
        let isVueApp: Bool                  // Vue.js 앱 여부
        let enableVueInfiniteScroll: Bool   // Vue 무한스크롤 복원 활성화
        let enableVueReactive: Bool         // Vue 반응형 시스템 복원 활성화
        let enableVueRouter: Bool           // Vue Router 스크롤 복원 활성화
        let savedInfiniteScrollData: String? // 무한스크롤 데이터 상태 (JSON)
        let savedPageNumber: Int            // 현재 페이지 번호
        let savedComponentStates: String?   // Vue 컴포넌트 상태들 (JSON)
        let vueRenderDelay: Double          // Vue 컴포넌트 렌더링 대기시간
        let infiniteScrollDelay: Double     // 무한스크롤 복원 대기시간
        let reactiveUpdateDelay: Double     // 반응형 업데이트 대기시간
        
        static let `default` = VueRestorationConfig(
            isVueApp: false,
            enableVueInfiniteScroll: true,
            enableVueReactive: true,
            enableVueRouter: true,
            savedInfiniteScrollData: nil,
            savedPageNumber: 1,
            savedComponentStates: nil,
            vueRenderDelay: 0.5,
            infiniteScrollDelay: 1.0,
            reactiveUpdateDelay: 0.3
        )
    }
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
        case vueEnhanced    // Vue.js 특화 캡처 성공
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
        case restorationConfig
        case vueConfig
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
        restorationConfig = try container.decodeIfPresent(RestorationConfig.self, forKey: .restorationConfig) ?? RestorationConfig.default
        vueConfig = try container.decodeIfPresent(VueRestorationConfig.self, forKey: .vueConfig) ?? VueRestorationConfig.default
        
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
        try container.encode(restorationConfig, forKey: .restorationConfig)
        try container.encode(vueConfig, forKey: .vueConfig)
        
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
         restorationConfig: RestorationConfig = RestorationConfig.default,
         vueConfig: VueRestorationConfig = VueRestorationConfig.default) {
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
        self.restorationConfig = RestorationConfig(
            enableContentRestore: restorationConfig.enableContentRestore,
            enablePercentRestore: restorationConfig.enablePercentRestore,
            enableAnchorRestore: restorationConfig.enableAnchorRestore,
            enableFinalVerification: restorationConfig.enableFinalVerification,
            savedContentHeight: max(actualScrollableSize.height, contentSize.height),
            step1RenderDelay: restorationConfig.step1RenderDelay,
            step2RenderDelay: restorationConfig.step2RenderDelay,
            step3RenderDelay: restorationConfig.step3RenderDelay,
            step4RenderDelay: restorationConfig.step4RenderDelay
        )
        self.vueConfig = vueConfig
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // MARK: - 🎯 **핵심: 순차적 4단계 + Vue.js 특화 복원 시스템**
    
    // 복원 컨텍스트 구조체
    private struct RestorationContext {
        let snapshot: BFCacheSnapshot
        weak var webView: WKWebView?
        let completion: (Bool) -> Void
        var overallSuccess: Bool = false
        var vueDetected: Bool = false        // Vue.js 앱 감지 여부
        var infiniteScrollDetected: Bool = false  // 무한스크롤 감지 여부
    }
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 순차적 4단계 + Vue.js 특화 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 저장 콘텐츠 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")
        TabPersistenceManager.debugMessages.append("🅥 Vue.js 설정: 무한스크롤=\(vueConfig.enableVueInfiniteScroll), 반응형=\(vueConfig.enableVueReactive), 라우터=\(vueConfig.enableVueRouter)")
        TabPersistenceManager.debugMessages.append("⏰ 렌더링 대기시간: Step1=\(restorationConfig.step1RenderDelay)s, Step2=\(restorationConfig.step2RenderDelay)s, Step3=\(restorationConfig.step3RenderDelay)s, Step4=\(restorationConfig.step4RenderDelay)s")
        TabPersistenceManager.debugMessages.append("⏰ Vue 대기시간: 렌더링=\(vueConfig.vueRenderDelay)s, 무한스크롤=\(vueConfig.infiniteScrollDelay)s, 반응형=\(vueConfig.reactiveUpdateDelay)s")
        
        // 복원 컨텍스트 생성
        let context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: completion
        )
        
        // 🅥 Vue.js 감지부터 시작
        detectVueAndProceed(context: context)
    }
    
    // MARK: - 🅥 Vue.js 감지 및 진행
    private func detectVueAndProceed(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🅥 [Vue 감지] Vue.js 앱 감지 시작")
        
        let vueDetectionScript = generateVueDetectionScript()
        
        context.webView?.evaluateJavaScript(vueDetectionScript) { result, error in
            var updatedContext = context
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🅥 [Vue 감지] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                let isVue = (resultDict["isVueApp"] as? Bool) ?? false
                let hasInfiniteScroll = (resultDict["hasInfiniteScroll"] as? Bool) ?? false
                let vueVersion = resultDict["vueVersion"] as? String ?? "unknown"
                let hasVueRouter = (resultDict["hasVueRouter"] as? Bool) ?? false
                let componentCount = (resultDict["componentCount"] as? Int) ?? 0
                
                updatedContext.vueDetected = isVue
                updatedContext.infiniteScrollDetected = hasInfiniteScroll
                
                TabPersistenceManager.debugMessages.append("🅥 [Vue 감지] Vue.js 앱: \(isVue ? "감지됨" : "미감지")")
                TabPersistenceManager.debugMessages.append("🅥 [Vue 감지] Vue 버전: \(vueVersion)")
                TabPersistenceManager.debugMessages.append("🅥 [Vue 감지] Vue Router: \(hasVueRouter ? "있음" : "없음")")
                TabPersistenceManager.debugMessages.append("🅥 [Vue 감지] 컴포넌트 수: \(componentCount)개")
                TabPersistenceManager.debugMessages.append("🅥 [Vue 감지] 무한스크롤: \(hasInfiniteScroll ? "감지됨" : "미감지")")
                
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            // Vue.js 감지 완료 후 적절한 복원 경로 선택
            if updatedContext.vueDetected && self.vueConfig.enableVueInfiniteScroll {
                TabPersistenceManager.debugMessages.append("🅥 [Vue 감지] Vue.js 특화 복원 경로 선택")
                self.executeVueSpecificRestoration(context: updatedContext)
            } else {
                TabPersistenceManager.debugMessages.append("🅥 [Vue 감지] 표준 복원 경로 선택")
                self.executeStep1_RestoreContentHeight(context: updatedContext)
            }
        }
    }
    
    // MARK: - 🅥 Vue.js 특화 복원 프로세스
    private func executeVueSpecificRestoration(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🅥 [Vue 특화] Vue.js 특화 복원 프로세스 시작")
        
        // Vue.js 특화 복원 순서:
        // 1. Vue 컴포넌트 상태 복원
        // 2. 무한스크롤 데이터 복원 (필요시)
        // 3. Vue Router 스크롤 복원 (필요시)
        // 4. 표준 4단계 복원 실행
        
        executeVueStep1_ComponentStateRestore(context: context)
    }
    
    // MARK: - 🅥 Vue Step 1: 컴포넌트 상태 복원
    private func executeVueStep1_ComponentStateRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🅥 [Vue Step 1] Vue 컴포넌트 상태 복원 시작")
        
        guard vueConfig.enableVueReactive else {
            TabPersistenceManager.debugMessages.append("🅥 [Vue Step 1] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + vueConfig.reactiveUpdateDelay) {
                self.executeVueStep2_InfiniteScrollRestore(context: context)
            }
            return
        }
        
        let js = generateVueComponentStateRestoreScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var vueStep1Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🅥 [Vue Step 1] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                vueStep1Success = (resultDict["success"] as? Bool) ?? false
                
                if let restoredComponents = resultDict["restoredComponents"] as? Int {
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 1] 복원된 컴포넌트: \(restoredComponents)개")
                }
                if let reactiveUpdates = resultDict["reactiveUpdates"] as? Int {
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 1] 반응형 업데이트: \(reactiveUpdates)회")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("🅥 [Vue Step 1] 완료: \(vueStep1Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Vue Step 1] 반응형 업데이트 대기: \(self.vueConfig.reactiveUpdateDelay)초")
            
            // 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.vueConfig.reactiveUpdateDelay) {
                self.executeVueStep2_InfiniteScrollRestore(context: context)
            }
        }
    }
    
    // MARK: - 🅥 Vue Step 2: 무한스크롤 데이터 복원
    private func executeVueStep2_InfiniteScrollRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🅥 [Vue Step 2] Vue 무한스크롤 데이터 복원 시작")
        
        guard vueConfig.enableVueInfiniteScroll && context.infiniteScrollDetected else {
            TabPersistenceManager.debugMessages.append("🅥 [Vue Step 2] 무한스크롤 미감지 또는 비활성화 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + vueConfig.infiniteScrollDelay) {
                self.executeVueStep3_RouterScrollRestore(context: context)
            }
            return
        }
        
        let js = generateVueInfiniteScrollRestoreScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var vueStep2Success = false
            var updatedContext = context
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🅥 [Vue Step 2] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                vueStep2Success = (resultDict["success"] as? Bool) ?? false
                
                if let restoredPages = resultDict["restoredPages"] as? Int {
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 2] 복원된 페이지: \(restoredPages)페이지")
                }
                if let restoredItems = resultDict["restoredItems"] as? Int {
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 2] 복원된 아이템: \(restoredItems)개")
                }
                if let scrollPosition = resultDict["scrollPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 2] 무한스크롤 위치: Y=\(String(format: "%.1f", scrollPosition["y"] ?? 0))px")
                }
                if let componentData = resultDict["componentData"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 2] 컴포넌트 데이터 복원: \(componentData.keys.count)개 속성")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(8) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
                
                // Vue 무한스크롤 복원 성공 시 우선 성공으로 간주
                if vueStep2Success {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 2] ✅ Vue 무한스크롤 복원 성공 - 우선 성공으로 간주")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🅥 [Vue Step 2] 완료: \(vueStep2Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Vue Step 2] 무한스크롤 렌더링 대기: \(self.vueConfig.infiniteScrollDelay)초")
            
            // 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.vueConfig.infiniteScrollDelay) {
                self.executeVueStep3_RouterScrollRestore(context: updatedContext)
            }
        }
    }
    
    // MARK: - 🅥 Vue Step 3: Vue Router 스크롤 복원
    private func executeVueStep3_RouterScrollRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🅥 [Vue Step 3] Vue Router 스크롤 복원 시작")
        
        guard vueConfig.enableVueRouter else {
            TabPersistenceManager.debugMessages.append("🅥 [Vue Step 3] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + vueConfig.vueRenderDelay) {
                self.executeStep1_RestoreContentHeight(context: context)
            }
            return
        }
        
        let js = generateVueRouterScrollRestoreScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var vueStep3Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🅥 [Vue Step 3] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                vueStep3Success = (resultDict["success"] as? Bool) ?? false
                
                if let routerDetected = resultDict["routerDetected"] as? Bool {
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 3] Vue Router 감지: \(routerDetected ? "있음" : "없음")")
                }
                if let scrollBehavior = resultDict["scrollBehavior"] as? String {
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 3] ScrollBehavior: \(scrollBehavior)")
                }
                if let routerScrollPosition = resultDict["routerScrollPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("🅥 [Vue Step 3] 라우터 스크롤 위치: X=\(String(format: "%.1f", routerScrollPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", routerScrollPosition["y"] ?? 0))px")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("🅥 [Vue Step 3] 완료: \(vueStep3Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Vue Step 3] Vue 렌더링 대기: \(self.vueConfig.vueRenderDelay)초")
            
            // Vue 특화 복원 완료 후 표준 4단계 복원 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.vueConfig.vueRenderDelay) {
                TabPersistenceManager.debugMessages.append("🅥 [Vue 완료] Vue 특화 복원 완료 - 표준 4단계 복원 시작")
                self.executeStep1_RestoreContentHeight(context: context)
            }
        }
    }
    
    // MARK: - Step 1: 저장 콘텐츠 높이 복원
    private func executeStep1_RestoreContentHeight(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📦 [Step 1] 저장 콘텐츠 높이 복원 시작")
        
        guard restorationConfig.enableContentRestore else {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step1RenderDelay) {
                self.executeStep2_PercentScroll(context: context)
            }
            return
        }
        
        let js = generateStep1_ContentRestoreScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step1Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step1Success = (resultDict["success"] as? Bool) ?? false
                
                if let currentHeight = resultDict["currentHeight"] as? Double {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 현재 높이: \(String(format: "%.0f", currentHeight))px")
                }
                if let targetHeight = resultDict["targetHeight"] as? Double {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 목표 높이: \(String(format: "%.0f", targetHeight))px")
                }
                if let restoredHeight = resultDict["restoredHeight"] as? Double {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 복원된 높이: \(String(format: "%.0f", restoredHeight))px")
                }
                if let percentage = resultDict["percentage"] as? Double {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 복원률: \(String(format: "%.1f", percentage))%")
                }
                if let isStatic = resultDict["isStaticSite"] as? Bool, isStatic {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 정적 사이트 - 콘텐츠 복원 불필요")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 완료: \(step1Success ? "성공" : "실패") - 실패해도 계속 진행")
            TabPersistenceManager.debugMessages.append("⏰ [Step 1] 렌더링 대기: \(self.restorationConfig.step1RenderDelay)초")
            
            // 성공/실패 관계없이 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step1RenderDelay) {
                self.executeStep2_PercentScroll(context: context)
            }
        }
    }
    
    // MARK: - Step 2: 상대좌표 기반 스크롤 (최우선)
    private func executeStep2_PercentScroll(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📏 [Step 2] 상대좌표 기반 스크롤 복원 시작 (최우선)")
        
        guard restorationConfig.enablePercentRestore else {
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step2RenderDelay) {
                self.executeStep3_AnchorRestore(context: context)
            }
            return
        }
        
        let js = generateStep2_PercentScrollScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step2Success = false
            var updatedContext = context
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📏 [Step 2] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step2Success = (resultDict["success"] as? Bool) ?? false
                
                if let targetPercent = resultDict["targetPercent"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] 목표 백분율: X=\(String(format: "%.2f", targetPercent["x"] ?? 0))%, Y=\(String(format: "%.2f", targetPercent["y"] ?? 0))%")
                }
                if let calculatedPosition = resultDict["calculatedPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] 계산된 위치: X=\(String(format: "%.1f", calculatedPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", calculatedPosition["y"] ?? 0))px")
                }
                if let actualPosition = resultDict["actualPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] 실제 위치: X=\(String(format: "%.1f", actualPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", actualPosition["y"] ?? 0))px")
                }
                if let difference = resultDict["difference"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] 위치 차이: X=\(String(format: "%.1f", difference["x"] ?? 0))px, Y=\(String(format: "%.1f", difference["y"] ?? 0))px")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
                
                // 상대좌표 복원 성공 시 전체 성공으로 간주 (Vue 성공이 없었다면)
                if step2Success && !updatedContext.overallSuccess {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] ✅ 상대좌표 복원 성공 - 전체 복원 성공으로 간주")
                }
            }
            
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 완료: \(step2Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 2] 렌더링 대기: \(self.restorationConfig.step2RenderDelay)초")
            
            // 성공/실패 관계없이 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step2RenderDelay) {
                self.executeStep3_AnchorRestore(context: updatedContext)
            }
        }
    }
    
    // MARK: - Step 3: 4요소 패키지 앵커 복원
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 4요소 패키지 앵커 정밀 복원 시작")
        
        guard restorationConfig.enableAnchorRestore else {
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step3RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
            return
        }
        
        // 4요소 패키지 데이터 확인
        var fourElementPackageDataJSON = "null"
        if let jsState = self.jsState,
           let fourElementPackageData = jsState["fourElementPackageAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(fourElementPackageData) {
            fourElementPackageDataJSON = dataJSON
        }
        
        let js = generateStep3_AnchorRestoreScript(packageDataJSON: fourElementPackageDataJSON)
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step3Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🔍 [Step 3] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step3Success = (resultDict["success"] as? Bool) ?? false
                
                if let anchorCount = resultDict["anchorCount"] as? Int {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 사용 가능한 앵커: \(anchorCount)개")
                }
                if let matchedAnchor = resultDict["matchedAnchor"] as? [String: Any] {
                    if let package = matchedAnchor["package"] as? [String: String] {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭된 앵커: id=\(package["id"] ?? ""), type=\(package["type"] ?? ""), kw=\(package["kw"] ?? "")")
                    }
                    if let method = matchedAnchor["method"] as? String {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭 방법: \(method)")
                    }
                }
                if let restoredPosition = resultDict["restoredPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 복원된 위치: X=\(String(format: "%.1f", restoredPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", restoredPosition["y"] ?? 0))px")
                }
                if let targetDifference = resultDict["targetDifference"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 목표와의 차이: X=\(String(format: "%.1f", targetDifference["x"] ?? 0))px, Y=\(String(format: "%.1f", targetDifference["y"] ?? 0))px")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(10) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 완료: \(step3Success ? "성공" : "실패") - 실패해도 계속 진행")
            TabPersistenceManager.debugMessages.append("⏰ [Step 3] 렌더링 대기: \(self.restorationConfig.step3RenderDelay)초")
            
            // 성공/실패 관계없이 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step3RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
        }
    }
    
    // MARK: - Step 4: 최종 검증 및 미세 보정
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
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step4Success = (resultDict["success"] as? Bool) ?? false
                
                if let finalPosition = resultDict["finalPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 위치: X=\(String(format: "%.1f", finalPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
                }
                if let targetPosition = resultDict["targetPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("✅ [Step 4] 목표 위치: X=\(String(format: "%.1f", targetPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", targetPosition["y"] ?? 0))px")
                }
                if let finalDifference = resultDict["finalDifference"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 차이: X=\(String(format: "%.1f", finalDifference["x"] ?? 0))px, Y=\(String(format: "%.1f", finalDifference["y"] ?? 0))px")
                }
                if let withinTolerance = resultDict["withinTolerance"] as? Bool {
                    TabPersistenceManager.debugMessages.append("✅ [Step 4] 허용 오차 내: \(withinTolerance ? "예" : "아니오")")
                }
                if let correctionApplied = resultDict["correctionApplied"] as? Bool, correctionApplied {
                    TabPersistenceManager.debugMessages.append("✅ [Step 4] 미세 보정 적용됨")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 완료: \(step4Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 4] 렌더링 대기: \(self.restorationConfig.step4RenderDelay)초")
            
            // 최종 대기 후 완료 콜백
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step4RenderDelay) {
                let finalSuccess = context.overallSuccess || step4Success
                let resultDescription = context.vueDetected ? 
                    (context.overallSuccess ? "Vue 특화 복원 성공" : "표준 복원 적용") : 
                    (finalSuccess ? "표준 복원 성공" : "복원 실패")
                    
                TabPersistenceManager.debugMessages.append("🎯 전체 BFCache 복원 완료: \(resultDescription)")
                context.completion(finalSuccess)
            }
        }
    }
    
    // MARK: - 🅥 Vue.js 특화 JavaScript 생성 메서드들
    
    private func generateVueDetectionScript() -> String {
        return """
        (function() {
            try {
                const logs = [];
                logs.push('[Vue 감지] Vue.js 앱 감지 시작');
                
                // Vue.js 감지 로직
                let isVueApp = false;
                let vueVersion = 'unknown';
                let hasVueRouter = false;
                let componentCount = 0;
                let hasInfiniteScroll = false;
                
                // Vue 2 감지
                if (window.Vue) {
                    isVueApp = true;
                    vueVersion = 'Vue 2.x';
                    logs.push('Vue 2.x 글로벌 인스턴스 감지');
                    
                    try {
                        if (window.Vue.version) {
                            vueVersion = 'Vue ' + window.Vue.version;
                        }
                    } catch(e) {}
                }
                
                // Vue 3 감지
                if (!isVueApp && window.__VUE__) {
                    isVueApp = true;
                    vueVersion = 'Vue 3.x';
                    logs.push('Vue 3.x 인스턴스 감지');
                }
                
                // data-v- 속성으로 Vue 컴포넌트 감지
                const vueElements = document.querySelectorAll('[data-v-]');
                if (vueElements.length > 0) {
                    isVueApp = true;
                    componentCount = vueElements.length;
                    logs.push('Vue 컴포넌트 스타일 스코프 감지: ' + componentCount + '개');
                    
                    // 컴포넌트 이름 패턴 분석
                    const componentPatterns = ['ArticleList', 'CommentList', 'InfiniteScroll', 'VirtualList'];
                    for (let i = 0; i < componentPatterns.length; i++) {
                        const pattern = componentPatterns[i];
                        const elements = document.querySelectorAll('[class*="' + pattern.toLowerCase() + '"]');
                        if (elements.length > 0) {
                            logs.push('Vue 컴포넌트 패턴 감지: ' + pattern + ' (' + elements.length + '개)');
                            if (pattern.includes('List') || pattern.includes('Infinite')) {
                                hasInfiniteScroll = true;
                            }
                        }
                    }
                }
                
                // Vue Router 감지
                if (window.VueRouter || (window.Vue && window.Vue.router)) {
                    hasVueRouter = true;
                    logs.push('Vue Router 감지됨');
                } else {
                    // 라우터 패턴 확인 (hash 또는 history mode)
                    const currentHash = window.location.hash;
                    const hasRouterHash = currentHash.startsWith('#/');
                    if (hasRouterHash) {
                        hasVueRouter = true;
                        logs.push('Vue Router hash mode 감지됨');
                    }
                }
                
                // 무한스크롤 패턴 감지
                if (!hasInfiniteScroll) {
                    // 일반적인 무한스크롤 요소들
                    const infiniteScrollSelectors = [
                        '.infinite-scroll', '.endless-scroll', '.auto-load',
                        '[v-infinite-scroll]', '[data-infinite]',
                        '.list-container', '.feed-container', '.scroll-container'
                    ];
                    
                    for (let i = 0; i < infiniteScrollSelectors.length; i++) {
                        const selector = infiniteScrollSelectors[i];
                        try {
                            const elements = document.querySelectorAll(selector);
                            if (elements.length > 0) {
                                hasInfiniteScroll = true;
                                logs.push('무한스크롤 요소 감지: ' + selector + ' (' + elements.length + '개)');
                                break;
                            }
                        } catch(e) {}
                    }
                }
                
                // Vue 인스턴스 직접 탐지 시도
                if (!isVueApp) {
                    try {
                        const allElements = document.querySelectorAll('*');
                        for (let i = 0; i < Math.min(100, allElements.length); i++) {
                            const el = allElements[i];
                            if (el.__vue__ || el._vnode || el.__vueParentComponent) {
                                isVueApp = true;
                                logs.push('요소에서 Vue 인스턴스 발견');
                                break;
                            }
                        }
                    } catch(e) {
                        logs.push('Vue 인스턴스 탐지 중 오류: ' + e.message);
                    }
                }
                
                // 네이버 카페 특화 감지
                if (window.location.hostname.includes('cafe.naver.com')) {
                    logs.push('네이버 카페 도메인 감지 - Vue.js 사용 가능성 높음');
                    if (!isVueApp) {
                        // 네이버 카페에서 Vue.js 사용하는 것으로 알려져 있으므로 추가 검사
                        const cafeElements = document.querySelectorAll('.article-board, .comment-list, [class*="List"]');
                        if (cafeElements.length > 0) {
                            isVueApp = true;
                            vueVersion = 'Vue (네이버 카페)';
                            hasInfiniteScroll = true;
                            logs.push('네이버 카페 Vue 컴포넌트 패턴 확인됨');
                        }
                    }
                }
                
                logs.push('Vue 감지 결과: ' + (isVueApp ? '감지됨' : '미감지'));
                logs.push('버전: ' + vueVersion);
                logs.push('라우터: ' + (hasVueRouter ? '있음' : '없음'));
                logs.push('컴포넌트 수: ' + componentCount);
                logs.push('무한스크롤: ' + (hasInfiniteScroll ? '감지됨' : '미감지'));
                
                return {
                    isVueApp: isVueApp,
                    vueVersion: vueVersion,
                    hasVueRouter: hasVueRouter,
                    componentCount: componentCount,
                    hasInfiniteScroll: hasInfiniteScroll,
                    logs: logs
                };
                
            } catch(e) {
                return {
                    isVueApp: false,
                    vueVersion: 'unknown',
                    hasVueRouter: false,
                    componentCount: 0,
                    hasInfiniteScroll: false,
                    error: e.message,
                    logs: ['[Vue 감지] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    private func generateVueComponentStateRestoreScript() -> String {
        let savedComponentStates = vueConfig.savedComponentStates ?? "{}"
        
        return """
        (function() {
            try {
                const logs = [];
                const savedStates = \(savedComponentStates);
                let restoredComponents = 0;
                let reactiveUpdates = 0;
                
                logs.push('[Vue Step 1] Vue 컴포넌트 상태 복원 시작');
                
                // Vue 2 상태 복원
                if (window.Vue && window.Vue.version) {
                    logs.push('Vue 2 상태 복원 시도');
                    
                    // 모든 Vue 인스턴스에 접근
                    const allElements = document.querySelectorAll('[data-v-]');
                    for (let i = 0; i < allElements.length; i++) {
                        const el = allElements[i];
                        const vueInstance = el.__vue__;
                        
                        if (vueInstance && vueInstance.$data) {
                            try {
                                // 저장된 상태가 있으면 복원
                                if (savedStates[i] && savedStates[i].data) {
                                    Object.assign(vueInstance.$data, savedStates[i].data);
                                    restoredComponents++;
                                    reactiveUpdates++;
                                    logs.push('컴포넌트[' + i + '] 상태 복원됨');
                                }
                                
                                // 강제 업데이트
                                if (vueInstance.$forceUpdate) {
                                    vueInstance.$forceUpdate();
                                    reactiveUpdates++;
                                }
                            } catch(e) {
                                logs.push('컴포넌트[' + i + '] 복원 실패: ' + e.message);
                            }
                        }
                    }
                }
                
                // Vue 3 상태 복원 (간접적)
                if (window.__VUE__) {
                    logs.push('Vue 3 상태 복원 시도 (제한적)');
                    
                    // reactive 데이터 업데이트 시도
                    try {
                        // DOM 업데이트 강제 실행
                        if (window.Vue && window.Vue.nextTick) {
                            window.Vue.nextTick(function() {
                                logs.push('Vue nextTick 실행됨');
                                reactiveUpdates++;
                            });
                        }
                    } catch(e) {
                        logs.push('Vue 3 nextTick 실패: ' + e.message);
                    }
                }
                
                // 일반적인 상태 복원 (컴포넌트별)
                const listContainers = document.querySelectorAll('.list-container, .feed-container, [class*="List"]');
                for (let i = 0; i < listContainers.length; i++) {
                    const container = listContainers[i];
                    
                    // 리스트 아이템 수 확인
                    const listItems = container.querySelectorAll('li, .item, [class*="item"]');
                    if (listItems.length > 0) {
                        logs.push('리스트 컨테이너[' + i + '] 아이템 수: ' + listItems.length);
                        restoredComponents++;
                    }
                }
                
                const success = restoredComponents > 0 || reactiveUpdates > 0;
                logs.push('Vue 컴포넌트 상태 복원 ' + (success ? '성공' : '실패'));
                
                return {
                    success: success,
                    restoredComponents: restoredComponents,
                    reactiveUpdates: reactiveUpdates,
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    restoredComponents: 0,
                    reactiveUpdates: 0,
                    error: e.message,
                    logs: ['[Vue Step 1] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    private func generateVueInfiniteScrollRestoreScript() -> String {
        let savedPageNumber = vueConfig.savedPageNumber
        let savedScrollData = vueConfig.savedInfiniteScrollData ?? "{}"
        
        return """
        (function() {
            try {
                const logs = [];
                const targetPageNumber = \(savedPageNumber);
                const savedData = \(savedScrollData);
                let restoredPages = 0;
                let restoredItems = 0;
                let componentDataRestored = false;
                
                logs.push('[Vue Step 2] Vue 무한스크롤 데이터 복원 시작');
                logs.push('목표 페이지: ' + targetPageNumber);
                
                // 현재 스크롤 위치 확인
                const currentScrollY = window.scrollY || window.pageYOffset || 0;
                const currentScrollX = window.scrollX || window.pageXOffset || 0;
                
                logs.push('현재 스크롤 위치: X=' + currentScrollX.toFixed(1) + 'px, Y=' + currentScrollY.toFixed(1) + 'px');
                
                // Vue 무한스크롤 컴포넌트 찾기
                const infiniteScrollSelectors = [
                    '.infinite-scroll', '.endless-scroll', '.auto-load',
                    '[v-infinite-scroll]', '[data-infinite]',
                    '.list-container', '.feed-container', '.scroll-container',
                    '.article-list', '.comment-list', '[class*="List"]'
                ];
                
                let infiniteScrollContainer = null;
                for (let i = 0; i < infiniteScrollSelectors.length; i++) {
                    const selector = infiniteScrollSelectors[i];
                    try {
                        const containers = document.querySelectorAll(selector);
                        if (containers.length > 0) {
                            infiniteScrollContainer = containers[0];
                            logs.push('무한스크롤 컨테이너 발견: ' + selector);
                            break;
                        }
                    } catch(e) {}
                }
                
                if (!infiniteScrollContainer) {
                    logs.push('무한스크롤 컨테이너 미발견 - 기본 복원 시도');
                    
                    // 기본 리스트 컨테이너 찾기
                    const listElements = document.querySelectorAll('ul, ol, .list, [role="list"]');
                    if (listElements.length > 0) {
                        infiniteScrollContainer = listElements[0];
                        logs.push('기본 리스트 컨테이너 사용');
                    }
                }
                
                if (infiniteScrollContainer) {
                    // 현재 로드된 아이템 수 확인
                    const currentItems = infiniteScrollContainer.querySelectorAll('li, .item, [class*="item"], .article, .post');
                    const currentItemCount = currentItems.length;
                    logs.push('현재 로드된 아이템: ' + currentItemCount + '개');
                    
                    // 목표 페이지까지 데이터 로드가 필요한지 확인
                    const estimatedItemsPerPage = 20; // 일반적인 페이지당 아이템 수
                    const expectedItemCount = targetPageNumber * estimatedItemsPerPage;
                    
                    logs.push('예상 필요 아이템: ' + expectedItemCount + '개');
                    
                    if (currentItemCount < expectedItemCount) {
                        logs.push('추가 데이터 로드 필요 - 무한스크롤 트리거 시도');
                        
                        // 무한스크롤 트리거 시도
                        const loadingTriggers = [
                            '.load-more', '.loading-trigger', '.infinite-trigger',
                            '[data-load-more]', '.next-page'
                        ];
                        
                        let triggered = false;
                        for (let i = 0; i < loadingTriggers.length; i++) {
                            const triggerSelector = loadingTriggers[i];
                            try {
                                const triggers = document.querySelectorAll(triggerSelector);
                                for (let j = 0; j < triggers.length; j++) {
                                    const trigger = triggers[j];
                                    if (trigger && typeof trigger.click === 'function') {
                                        trigger.click();
                                        triggered = true;
                                        logs.push('로딩 트리거 클릭: ' + triggerSelector);
                                        break;
                                    }
                                }
                                if (triggered) break;
                            } catch(e) {}
                        }
                        
                        // 스크롤 이벤트로 무한스크롤 트리거
                        if (!triggered) {
                            try {
                                const containerHeight = infiniteScrollContainer.scrollHeight || infiniteScrollContainer.offsetHeight;
                                const viewportHeight = window.innerHeight;
                                
                                // 컨테이너 하단으로 스크롤하여 무한스크롤 트리거
                                const triggerPosition = Math.max(0, containerHeight - viewportHeight - 100);
                                window.scrollTo(0, triggerPosition);
                                
                                // 스크롤 이벤트 발생
                                window.dispatchEvent(new Event('scroll', { bubbles: true }));
                                
                                logs.push('스크롤 트리거 실행: Y=' + triggerPosition.toFixed(0) + 'px');
                                triggered = true;
                                
                                // 잠시 대기 후 원래 위치로 복원
                                setTimeout(function() {
                                    window.scrollTo(currentScrollX, currentScrollY);
                                    logs.push('원래 스크롤 위치로 복원');
                                }, 100);
                                
                            } catch(e) {
                                logs.push('스크롤 트리거 실패: ' + e.message);
                            }
                        }
                        
                        if (triggered) {
                            restoredPages = Math.max(1, targetPageNumber - 1);
                            restoredItems = currentItemCount;
                        }
                    } else {
                        logs.push('충분한 데이터가 이미 로드됨');
                        restoredPages = targetPageNumber;
                        restoredItems = currentItemCount;
                    }
                    
                    // Vue 컴포넌트 데이터 직접 접근 시도
                    try {
                        const vueElement = infiniteScrollContainer.closest('[data-v-]') || infiniteScrollContainer;
                        const vueInstance = vueElement.__vue__;
                        
                        if (vueInstance && vueInstance.$data) {
                            // 페이지 번호 설정
                            if (vueInstance.$data.page !== undefined) {
                                vueInstance.$data.page = targetPageNumber;
                                logs.push('Vue 컴포넌트 페이지 번호 설정: ' + targetPageNumber);
                                componentDataRestored = true;
                            }
                            
                            if (vueInstance.$data.currentPage !== undefined) {
                                vueInstance.$data.currentPage = targetPageNumber;
                                logs.push('Vue 컴포넌트 현재 페이지 설정: ' + targetPageNumber);
                                componentDataRestored = true;
                            }
                            
                            // 무한스크롤 상태 설정
                            if (vueInstance.$data.hasMore !== undefined) {
                                vueInstance.$data.hasMore = true;
                                logs.push('Vue 컴포넌트 hasMore 상태 설정');
                                componentDataRestored = true;
                            }
                            
                            if (vueInstance.$data.loading !== undefined) {
                                vueInstance.$data.loading = false;
                                logs.push('Vue 컴포넌트 loading 상태 해제');
                                componentDataRestored = true;
                            }
                            
                            // 강제 업데이트
                            if (vueInstance.$forceUpdate) {
                                vueInstance.$forceUpdate();
                                logs.push('Vue 컴포넌트 강제 업데이트 실행');
                            }
                        }
                    } catch(e) {
                        logs.push('Vue 컴포넌트 데이터 접근 실패: ' + e.message);
                    }
                }
                
                // sessionStorage에서 무한스크롤 상태 복원 시도
                try {
                    const savedScrollState = sessionStorage.getItem('infiniteScrollState');
                    if (savedScrollState) {
                        const scrollState = JSON.parse(savedScrollState);
                        if (scrollState.page && scrollState.page >= targetPageNumber) {
                            logs.push('sessionStorage에서 무한스크롤 상태 복원: 페이지 ' + scrollState.page);
                            restoredPages = Math.max(restoredPages, scrollState.page);
                            componentDataRestored = true;
                        }
                    }
                } catch(e) {
                    logs.push('sessionStorage 복원 실패: ' + e.message);
                }
                
                const success = restoredPages > 0 || restoredItems > 0 || componentDataRestored;
                logs.push('Vue 무한스크롤 복원 ' + (success ? '성공' : '실패'));
                
                return {
                    success: success,
                    restoredPages: restoredPages,
                    restoredItems: restoredItems,
                    scrollPosition: { x: currentScrollX, y: currentScrollY },
                    componentData: componentDataRestored,
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    restoredPages: 0,
                    restoredItems: 0,
                    scrollPosition: { x: 0, y: 0 },
                    componentData: false,
                    error: e.message,
                    logs: ['[Vue Step 2] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    private func generateVueRouterScrollRestoreScript() -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                let routerDetected = false;
                let scrollBehaviorSet = false;
                let routerScrollApplied = false;
                
                logs.push('[Vue Step 3] Vue Router 스크롤 복원 시작');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // Vue Router 감지 및 스크롤 동작 설정
                if (window.VueRouter) {
                    routerDetected = true;
                    logs.push('Vue Router 글로벌 인스턴스 감지됨');
                    
                    try {
                        // Vue Router의 scrollBehavior 설정 시도
                        if (window.VueRouter.prototype) {
                            const originalScrollBehavior = window.VueRouter.prototype.scrollBehavior;
                            
                            window.VueRouter.prototype.scrollBehavior = function (to, from, savedPosition) {
                                logs.push('Vue Router scrollBehavior 실행됨');
                                
                                // 저장된 위치가 있으면 그것을 사용
                                if (savedPosition) {
                                    logs.push('Vue Router 저장된 위치 사용: X=' + savedPosition.x + ', Y=' + savedPosition.y);
                                    return savedPosition;
                                }
                                
                                // 목표 위치로 스크롤
                                const targetPosition = { x: targetX, y: targetY };
                                logs.push('Vue Router 목표 위치로 스크롤: X=' + targetX + ', Y=' + targetY);
                                return targetPosition;
                            };
                            
                            scrollBehaviorSet = true;
                            logs.push('Vue Router scrollBehavior 설정 완료');
                        }
                    } catch(e) {
                        logs.push('Vue Router scrollBehavior 설정 실패: ' + e.message);
                    }
                }
                
                // Vue 2 라우터 인스턴스 접근
                if (window.Vue && window.Vue.router) {
                    routerDetected = true;
                    logs.push('Vue 2 라우터 인스턴스 감지됨');
                    
                    try {
                        const router = window.Vue.router;
                        if (router.options) {
                            // scrollBehavior 설정
                            router.options.scrollBehavior = function (to, from, savedPosition) {
                                logs.push('Vue 2 Router scrollBehavior 실행됨');
                                
                                if (savedPosition) {
                                    return savedPosition;
                                }
                                
                                return { x: targetX, y: targetY };
                            };
                            
                            scrollBehaviorSet = true;
                            logs.push('Vue 2 Router scrollBehavior 설정 완료');
                        }
                    } catch(e) {
                        logs.push('Vue 2 Router 설정 실패: ' + e.message);
                    }
                }
                
                // Vue 3 라우터 접근 시도
                try {
                    const appElements = document.querySelectorAll('[data-v-]');
                    for (let i = 0; i < appElements.length; i++) {
                        const el = appElements[i];
                        const vueInstance = el.__vue__ || el._vnode;
                        
                        if (vueInstance && vueInstance.$router) {
                            routerDetected = true;
                            logs.push('Vue 3 라우터 인스턴스 발견');
                            
                            try {
                                // 라우터 히스토리 조작 시도
                                const router = vueInstance.$router;
                                if (router.options && router.options.scrollBehavior) {
                                    logs.push('기존 scrollBehavior 발견됨');
                                }
                                
                                scrollBehaviorSet = true;
                            } catch(e) {
                                logs.push('Vue 3 라우터 조작 실패: ' + e.message);
                            }
                            break;
                        }
                    }
                } catch(e) {
                    logs.push('Vue 3 라우터 탐지 실패: ' + e.message);
                }
                
                // 브라우저 히스토리 상태 조작
                try {
                    if (window.history && window.history.scrollRestoration) {
                        window.history.scrollRestoration = 'manual';
                        logs.push('브라우저 스크롤 복원을 수동 모드로 설정');
                        
                        // popstate 이벤트 리스너 추가
                        const handlePopState = function(event) {
                            setTimeout(function() {
                                window.scrollTo(targetX, targetY);
                                logs.push('popstate 이벤트로 스크롤 복원 실행');
                            }, 50);
                        };
                        
                        window.addEventListener('popstate', handlePopState);
                        routerScrollApplied = true;
                        
                        // 현재 상태에 스크롤 위치 저장
                        if (window.history.replaceState) {
                            const currentState = window.history.state || {};
                            currentState.scrollX = targetX;
                            currentState.scrollY = targetY;
                            window.history.replaceState(currentState, document.title, window.location.href);
                            logs.push('히스토리 상태에 스크롤 위치 저장');
                        }
                    }
                } catch(e) {
                    logs.push('브라우저 히스토리 조작 실패: ' + e.message);
                }
                
                // 직접 스크롤 적용 (fallback)
                if (!routerScrollApplied) {
                    try {
                        window.scrollTo(targetX, targetY);
                        routerScrollApplied = true;
                        logs.push('직접 스크롤 적용됨');
                    } catch(e) {
                        logs.push('직접 스크롤 적용 실패: ' + e.message);
                    }
                }
                
                const success = routerDetected && (scrollBehaviorSet || routerScrollApplied);
                logs.push('Vue Router 스크롤 복원 ' + (success ? '성공' : '실패'));
                
                return {
                    success: success,
                    routerDetected: routerDetected,
                    scrollBehavior: scrollBehaviorSet ? '설정됨' : '미설정',
                    routerScrollPosition: { x: targetX, y: targetY },
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    routerDetected: false,
                    scrollBehavior: '오류',
                    routerScrollPosition: { x: 0, y: 0 },
                    error: e.message,
                    logs: ['[Vue Step 3] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // MARK: - 기존 JavaScript 생성 메서드들 (기존 로직 유지)
    
    private func generateStep1_ContentRestoreScript() -> String {
        let targetHeight = restorationConfig.savedContentHeight
        
        return """
        (function() {
            try {
                const logs = [];
                const targetHeight = parseFloat('\(targetHeight)');
                const currentHeight = Math.max(
                    document.documentElement.scrollHeight,
                    document.body.scrollHeight
                );
                
                logs.push('[Step 1] 콘텐츠 높이 복원 시작');
                logs.push('현재 높이: ' + currentHeight.toFixed(0) + 'px');
                logs.push('목표 높이: ' + targetHeight.toFixed(0) + 'px');
                
                // 정적 사이트 판단 (90% 이상 이미 로드됨)
                const percentage = (currentHeight / targetHeight) * 100;
                const isStaticSite = percentage >= 90;
                
                if (isStaticSite) {
                    logs.push('정적 사이트 - 콘텐츠 이미 충분함');
                    return {
                        success: true,
                        isStaticSite: true,
                        currentHeight: currentHeight,
                        targetHeight: targetHeight,
                        restoredHeight: currentHeight,
                        percentage: percentage,
                        logs: logs
                    };
                }
                
                // 동적 사이트 - 콘텐츠 로드 시도
                logs.push('동적 사이트 - 콘텐츠 로드 시도');
                
                // 더보기 버튼 찾기
                const loadMoreButtons = document.querySelectorAll(
                    '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                    'button[class*="more"], .load-more, .show-more'
                );
                
                let clicked = 0;
                for (let i = 0; i < Math.min(5, loadMoreButtons.length); i++) {
                    const btn = loadMoreButtons[i];
                    if (btn && typeof btn.click === 'function') {
                        btn.click();
                        clicked++;
                    }
                }
                
                if (clicked > 0) {
                    logs.push('더보기 버튼 ' + clicked + '개 클릭');
                }
                
                // 페이지 하단 스크롤로 무한스크롤 트리거
                const maxScrollY = Math.max(0, currentHeight - window.innerHeight);
                window.scrollTo(0, maxScrollY);
                window.dispatchEvent(new Event('scroll', { bubbles: true }));
                logs.push('무한스크롤 트리거 시도');
                
                // 복원 후 높이 측정
                const restoredHeight = Math.max(
                    document.documentElement.scrollHeight,
                    document.body.scrollHeight
                );
                
                const finalPercentage = (restoredHeight / targetHeight) * 100;
                const success = finalPercentage >= 80; // 80% 이상 복원 시 성공
                
                logs.push('복원된 높이: ' + restoredHeight.toFixed(0) + 'px');
                logs.push('복원률: ' + finalPercentage.toFixed(1) + '%');
                
                return {
                    success: success,
                    isStaticSite: false,
                    currentHeight: currentHeight,
                    targetHeight: targetHeight,
                    restoredHeight: restoredHeight,
                    percentage: finalPercentage,
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
    
    private func generateStep2_PercentScrollScript() -> String {
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetPercentX = parseFloat('\(targetPercentX)');
                const targetPercentY = parseFloat('\(targetPercentY)');
                
                logs.push('[Step 2] 상대좌표 기반 스크롤 복원');
                logs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                
                // 현재 콘텐츠 크기와 뷰포트 크기
                const contentHeight = Math.max(
                    document.documentElement.scrollHeight,
                    document.body.scrollHeight
                );
                const contentWidth = Math.max(
                    document.documentElement.scrollWidth,
                    document.body.scrollWidth
                );
                const viewportHeight = window.innerHeight;
                const viewportWidth = window.innerWidth;
                
                // 최대 스크롤 가능 거리
                const maxScrollY = Math.max(0, contentHeight - viewportHeight);
                const maxScrollX = Math.max(0, contentWidth - viewportWidth);
                
                logs.push('최대 스크롤: X=' + maxScrollX.toFixed(0) + 'px, Y=' + maxScrollY.toFixed(0) + 'px');
                
                // 백분율 기반 목표 위치 계산
                const targetX = (targetPercentX / 100) * maxScrollX;
                const targetY = (targetPercentY / 100) * maxScrollY;
                
                logs.push('계산된 목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // 스크롤 실행
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
                
                // 허용 오차 50px 이내면 성공
                const success = diffY <= 50;
                
                return {
                    success: success,
                    targetPercent: { x: targetPercentX, y: targetPercentY },
                    calculatedPosition: { x: targetX, y: targetY },
                    actualPosition: { x: actualX, y: actualY },
                    difference: { x: diffX, y: diffY },
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
    
    private func generateStep3_AnchorRestoreScript(packageDataJSON: String) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const fourElementPackageData = \(packageDataJSON);
                
                logs.push('[Step 3] 4요소 패키지 앵커 복원');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // 앵커 데이터 확인
                if (!fourElementPackageData || !fourElementPackageData.anchors || fourElementPackageData.anchors.length === 0) {
                    logs.push('앵커 데이터 없음 - 스킵');
                    return {
                        success: false,
                        anchorCount: 0,
                        logs: logs
                    };
                }
                
                const anchors = fourElementPackageData.anchors;
                logs.push('사용 가능한 앵커: ' + anchors.length + '개');
                
                // 완전한 4요소 패키지 앵커 필터링
                const completeAnchors = anchors.filter(function(anchor) {
                    if (!anchor.fourElementPackage) return false;
                    const pkg = anchor.fourElementPackage;
                    return pkg.id && pkg.type && pkg.ts && pkg.kw;
                });
                
                logs.push('완전한 4요소 패키지: ' + completeAnchors.length + '개');
                
                let foundElement = null;
                let matchedAnchor = null;
                let matchMethod = '';
                
                // 앵커 매칭 시도
                for (let i = 0; i < completeAnchors.length && !foundElement; i++) {
                    const anchor = completeAnchors[i];
                    const pkg = anchor.fourElementPackage;
                    
                    // ID로 찾기
                    if (pkg.id && pkg.id !== 'unknown') {
                        const element = document.getElementById(pkg.id);
                        if (element) {
                            foundElement = element;
                            matchedAnchor = anchor;
                            matchMethod = 'id';
                            logs.push('ID로 매칭: ' + pkg.id);
                            break;
                        }
                        
                        // data-id로 찾기
                        const dataElement = document.querySelector('[data-id="' + pkg.id + '"]');
                        if (dataElement) {
                            foundElement = dataElement;
                            matchedAnchor = anchor;
                            matchMethod = 'data-id';
                            logs.push('data-id로 매칭: ' + pkg.id);
                            break;
                        }
                    }
                    
                    // 키워드로 찾기
                    if (pkg.kw && pkg.kw !== 'unknown') {
                        const allElements = document.querySelectorAll('*');
                        for (let j = 0; j < allElements.length; j++) {
                            const el = allElements[j];
                            const text = (el.textContent || '').trim();
                            if (text.includes(pkg.kw)) {
                                foundElement = el;
                                matchedAnchor = anchor;
                                matchMethod = 'keyword';
                                logs.push('키워드로 매칭: ' + pkg.kw);
                                break;
                            }
                        }
                    }
                }
                
                if (foundElement && matchedAnchor) {
                    // 요소로 스크롤
                    foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                    
                    // 오프셋 보정
                    if (matchedAnchor.offsetFromTop) {
                        window.scrollBy(0, -matchedAnchor.offsetFromTop);
                    }
                    
                    const actualX = window.scrollX || window.pageXOffset || 0;
                    const actualY = window.scrollY || window.pageYOffset || 0;
                    const diffX = Math.abs(actualX - targetX);
                    const diffY = Math.abs(actualY - targetY);
                    
                    logs.push('앵커 복원 후 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                    logs.push('목표와의 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                    
                    return {
                        success: diffY <= 50,
                        anchorCount: completeAnchors.length,
                        matchedAnchor: {
                            package: matchedAnchor.fourElementPackage,
                            method: matchMethod
                        },
                        restoredPosition: { x: actualX, y: actualY },
                        targetDifference: { x: diffX, y: diffY },
                        logs: logs
                    };
                }
                
                logs.push('앵커 매칭 실패');
                return {
                    success: false,
                    anchorCount: completeAnchors.length,
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
    
    private func generateStep4_FinalVerificationScript() -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const tolerance = 30;
                
                logs.push('[Step 4] 최종 검증 및 미세 보정');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // 현재 위치 확인
                let currentX = window.scrollX || window.pageXOffset || 0;
                let currentY = window.scrollY || window.pageYOffset || 0;
                
                let diffX = Math.abs(currentX - targetX);
                let diffY = Math.abs(currentY - targetY);
                
                logs.push('현재 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                const withinTolerance = diffX <= tolerance && diffY <= tolerance;
                let correctionApplied = false;
                
                // 허용 오차 초과 시 미세 보정
                if (!withinTolerance) {
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
                
                const success = diffY <= 50;
                
                return {
                    success: success,
                    targetPosition: { x: targetX, y: targetY },
                    finalPosition: { x: currentX, y: currentY },
                    finalDifference: { x: diffX, y: diffY },
                    withinTolerance: diffX <= tolerance && diffY <= tolerance,
                    correctionApplied: correctionApplied,
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

// MARK: - BFCacheTransitionSystem 캐처/복원 확장 (Vue.js 특화 추가)
extension BFCacheTransitionSystem {
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🚀 4요소 패키지 캡처 + Vue.js 상태 캡처)**
    
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
        TabPersistenceManager.debugMessages.append("👁️ 보이는 요소 + Vue.js 상태 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
        
        TabPersistenceManager.debugMessages.append("👁️ Vue.js + 보이는 요소 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
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
        
        // 🔧 **개선된 캡처 로직 - Vue.js 특화 캡처 포함**
        let captureResult = performRobustVueCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
        )
        
        // 🔥 **캡처된 jsState 상세 로깅 (Vue.js 정보 포함)**
        if let jsState = captureResult.snapshot.jsState {
            TabPersistenceManager.debugMessages.append("🔥 캡처된 jsState 키: \(Array(jsState.keys))")
            
            // Vue.js 상태 정보 로깅
            if let vueState = jsState["vueState"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🅥 캡처된 Vue 상태 키: \(Array(vueState.keys))")
                
                if let isVueApp = vueState["isVueApp"] as? Bool {
                    TabPersistenceManager.debugMessages.append("🅥 Vue.js 앱 여부: \(isVueApp)")
                }
                if let vueVersion = vueState["vueVersion"] as? String {
                    TabPersistenceManager.debugMessages.append("🅥 Vue 버전: \(vueVersion)")
                }
                if let infiniteScrollData = vueState["infiniteScrollData"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("🅥 무한스크롤 데이터: \(infiniteScrollData.keys.count)개 키")
                    
                    if let currentPage = infiniteScrollData["currentPage"] as? Int {
                        TabPersistenceManager.debugMessages.append("🅥 현재 페이지: \(currentPage)")
                    }
                    if let loadedItems = infiniteScrollData["loadedItems"] as? Int {
                        TabPersistenceManager.debugMessages.append("🅥 로드된 아이템: \(loadedItems)개")
                    }
                }
                if let componentStates = vueState["componentStates"] as? [[String: Any]] {
                    TabPersistenceManager.debugMessages.append("🅥 컴포넌트 상태: \(componentStates.count)개")
                }
            }
            
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
        
        TabPersistenceManager.debugMessages.append("✅ Vue.js + 보이는 요소 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize      // ⚡ 콘텐츠 크기 추가
        let viewportSize: CGSize     // ⚡ 뷰포트 크기 추가
        let actualScrollableSize: CGSize  // ♾️ 실제 스크롤 가능 크기 추가
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔧 **Vue.js 특화 캡처 로직**
    private func performRobustVueCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptVueCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    TabPersistenceManager.debugMessages.append("🔄 재시도 후 Vue 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기 - 🔧 기존 80ms 유지
            TabPersistenceManager.debugMessages.append("⏳ Vue 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08) // 🔧 기존 80ms 유지
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptVueCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        TabPersistenceManager.debugMessages.append("📸 Vue.js 특화 스냅샷 캡처 시도: \(pageRecord.title)")
        
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
        
        // 3. ✅ **새로운: Vue.js + 보이는 요소 통합 캡처**
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🅥 Vue.js + 보이는 요소 통합 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateVueEnhancedVisibleCaptureScript() // 🅥 **새로운: Vue + 보이는 요소 통합 캡처**
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 Vue JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ Vue JS 상태 캡처 성공: \(Array(data.keys))")
                    
                    // 📊 **Vue.js 특화 상세 캡처 결과 로깅**
                    if let vueState = data["vueState"] as? [String: Any] {
                        TabPersistenceManager.debugMessages.append("🅥 Vue 상태 캡처됨: \(Array(vueState.keys))")
                        
                        if let isVueApp = vueState["isVueApp"] as? Bool {
                            TabPersistenceManager.debugMessages.append("🅥 Vue.js 앱: \(isVueApp ? "감지됨" : "미감지")")
                        }
                        if let infiniteScrollData = vueState["infiniteScrollData"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("🅥 무한스크롤 데이터: \(infiniteScrollData.keys.count)개 키")
                        }
                    }
                    
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
                            TabPersistenceManager.debugMessages.append("👁️ Vue JS 캡처된 앵커: \(anchors.count)개 (완전 패키지: \(completePackageAnchors.count)개, 보이는 것: \(visibleAnchors.count)개)")
                        }
                        if let stats = packageAnchors["stats"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("📊 Vue 보이는 요소 JS 캡처 통계: \(stats)")
                        }
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🔥 Vue JS 상태 캡처 결과 타입 오류: \(type(of: result))")
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 3.0) // 🅥 Vue 캡처는 더 긴 타임아웃 (3초)
        
        // 캡처 상태 결정 (Vue.js 특화)
        let captureStatus: BFCacheSnapshot.CaptureStatus
        var vueConfig = BFCacheSnapshot.VueRestorationConfig.default
        
        // Vue.js 상태가 캡처되었는지 확인
        let hasVueState = jsState?["vueState"] != nil
        
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            if hasVueState {
                captureStatus = .vueEnhanced
                TabPersistenceManager.debugMessages.append("✅ Vue.js 특화 완전 캡처 성공")
                
                // Vue.js 설정 업데이트
                if let vueState = jsState?["vueState"] as? [String: Any] {
                    let isVueApp = (vueState["isVueApp"] as? Bool) ?? false
                    let hasInfiniteScroll = (vueState["hasInfiniteScroll"] as? Bool) ?? false
                    let currentPage = (vueState["currentPage"] as? Int) ?? 1
                    
                    vueConfig = BFCacheSnapshot.VueRestorationConfig(
                        isVueApp: isVueApp,
                        enableVueInfiniteScroll: hasInfiniteScroll,
                        enableVueReactive: isVueApp,
                        enableVueRouter: isVueApp,
                        savedInfiniteScrollData: convertToJSONString(vueState["infiniteScrollData"] ?? [:]),
                        savedPageNumber: currentPage,
                        savedComponentStates: convertToJSONString(vueState["componentStates"] ?? []),
                        vueRenderDelay: 0.5,
                        infiniteScrollDelay: 1.0,
                        reactiveUpdateDelay: 0.3
                    )
                }
            } else {
                captureStatus = .complete
                TabPersistenceManager.debugMessages.append("✅ 표준 완전 캡처 성공")
            }
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
        
        TabPersistenceManager.debugMessages.append("📊 Vue 캡처 완료: 위치=(\(String(format: "%.1f", captureData.scrollPosition.x)), \(String(format: "%.1f", captureData.scrollPosition.y))), 백분율=(\(String(format: "%.2f", scrollPercent.x))%, \(String(format: "%.2f", scrollPercent.y))%)")
        
        // 🔄 **순차 실행 설정 생성**
        let restorationConfig = BFCacheSnapshot.RestorationConfig(
            enableContentRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height),
            step1RenderDelay: 0.8,
            step2RenderDelay: 0.3,
            step3RenderDelay: 0.5,
            step4RenderDelay: 0.3
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
            restorationConfig: restorationConfig,
            vueConfig: vueConfig
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🅥 **새로운: Vue.js + 보이는 요소 통합 캡처 JavaScript 생성**
    private func generateVueEnhancedVisibleCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🅥 Vue.js + 보이는 요소 통합 캡처 시작');
                
                // 📊 **상세 로그 수집**
                const detailedLogs = [];
                const captureStats = {};
                const pageAnalysis = {};
                const vueAnalysis = {};
                
                // 기본 정보 수집
                const scrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                const scrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                
                detailedLogs.push('🅥 Vue.js + 보이는 요소 통합 캡처 시작');
                detailedLogs.push('스크롤 위치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포트 크기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                console.log('🅥 기본 정보:', {
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                // 🅥 **Step 1: Vue.js 앱 감지 및 상태 수집**
                let isVueApp = false;
                let vueVersion = 'unknown';
                let hasVueRouter = false;
                let hasInfiniteScroll = false;
                let currentPage = 1;
                let componentStates = [];
                let infiniteScrollData = {};
                let vueInstances = [];
                
                detailedLogs.push('🅥 [Step 1] Vue.js 감지 및 상태 수집 시작');
                
                // Vue 2 감지
                if (window.Vue) {
                    isVueApp = true;
                    vueVersion = 'Vue 2.x';
                    detailedLogs.push('Vue 2.x 글로벌 인스턴스 감지');
                    
                    try {
                        if (window.Vue.version) {
                            vueVersion = 'Vue ' + window.Vue.version;
                        }
                    } catch(e) {}
                }
                
                // Vue 3 감지
                if (!isVueApp && window.__VUE__) {
                    isVueApp = true;
                    vueVersion = 'Vue 3.x';
                    detailedLogs.push('Vue 3.x 인스턴스 감지');
                }
                
                // data-v- 속성으로 Vue 컴포넌트 감지
                const vueElements = document.querySelectorAll('[data-v-]');
                if (vueElements.length > 0) {
                    isVueApp = true;
                    detailedLogs.push('Vue 컴포넌트 스타일 스코프 감지: ' + vueElements.length + '개');
                    
                    // Vue 인스턴스 수집
                    for (let i = 0; i < Math.min(10, vueElements.length); i++) {
                        const el = vueElements[i];
                        const vueInstance = el.__vue__;
                        
                        if (vueInstance && vueInstance.$data) {
                            try {
                                const instanceData = {
                                    index: i,
                                    componentName: vueInstance.$options.name || 'Anonymous',
                                    data: {},
                                    props: {},
                                    computed: {}
                                };
                                
                                // 데이터 수집 (안전하게)
                                if (vueInstance.$data) {
                                    Object.keys(vueInstance.$data).forEach(function(key) {
                                        try {
                                            const value = vueInstance.$data[key];
                                            // 기본 타입만 저장
                                            if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
                                                instanceData.data[key] = value;
                                            } else if (Array.isArray(value)) {
                                                instanceData.data[key] = value.length; // 배열 길이만 저장
                                            } else if (value && typeof value === 'object') {
                                                instanceData.data[key] = Object.keys(value).length; // 객체 키 수만 저장
                                            }
                                        } catch(e) {}
                                    });
                                }
                                
                                componentStates.push(instanceData);
                                vueInstances.push(vueInstance);
                                
                                detailedLogs.push('Vue 컴포넌트[' + i + '] 상태 수집: ' + instanceData.componentName);
                                
                                // 무한스크롤 관련 데이터 감지
                                if (vueInstance.$data.page || vueInstance.$data.currentPage) {
                                    currentPage = vueInstance.$data.page || vueInstance.$data.currentPage || 1;
                                    hasInfiniteScroll = true;
                                    detailedLogs.push('무한스크롤 페이지 감지: ' + currentPage);
                                }
                                
                                if (vueInstance.$data.items || vueInstance.$data.list || vueInstance.$data.data) {
                                    const items = vueInstance.$data.items || vueInstance.$data.list || vueInstance.$data.data;
                                    if (Array.isArray(items)) {
                                        infiniteScrollData.loadedItems = items.length;
                                        hasInfiniteScroll = true;
                                        detailedLogs.push('무한스크롤 아이템 감지: ' + items.length + '개');
                                    }
                                }
                                
                                if (vueInstance.$data.hasMore !== undefined) {
                                    infiniteScrollData.hasMore = vueInstance.$data.hasMore;
                                    hasInfiniteScroll = true;
                                }
                                
                                if (vueInstance.$data.loading !== undefined) {
                                    infiniteScrollData.loading = vueInstance.$data.loading;
                                }
                                
                            } catch(e) {
                                detailedLogs.push('Vue 컴포넌트[' + i + '] 상태 수집 실패: ' + e.message);
                            }
                        }
                    }
                }
                
                // Vue Router 감지
                if (window.VueRouter || (window.Vue && window.Vue.router)) {
                    hasVueRouter = true;
                    detailedLogs.push('Vue Router 감지됨');
                } else {
                    // 라우터 패턴 확인 (hash 또는 history mode)
                    const currentHash = window.location.hash;
                    const hasRouterHash = currentHash.startsWith('#/');
                    if (hasRouterHash) {
                        hasVueRouter = true;
                        detailedLogs.push('Vue Router hash mode 감지됨');
                    }
                }
                
                // 무한스크롤 패턴 추가 감지
                if (!hasInfiniteScroll) {
                    const infiniteScrollSelectors = [
                        '.infinite-scroll', '.endless-scroll', '.auto-load',
                        '[v-infinite-scroll]', '[data-infinite]',
                        '.list-container', '.feed-container', '.scroll-container',
                        '.article-list', '.comment-list', '[class*="List"]'
                    ];
                    
                    for (let i = 0; i < infiniteScrollSelectors.length; i++) {
                        const selector = infiniteScrollSelectors[i];
                        try {
                            const elements = document.querySelectorAll(selector);
                            if (elements.length > 0) {
                                hasInfiniteScroll = true;
                                detailedLogs.push('무한스크롤 요소 감지: ' + selector + ' (' + elements.length + '개)');
                                break;
                            }
                        } catch(e) {}
                    }
                }
                
                // 네이버 카페 특화 감지
                if (window.location.hostname.includes('cafe.naver.com')) {
                    detailedLogs.push('네이버 카페 도메인 감지 - Vue.js 무한스크롤 최적화');
                    if (!isVueApp) {
                        isVueApp = true;
                        vueVersion = 'Vue (네이버 카페)';
                        hasInfiniteScroll = true;
                        detailedLogs.push('네이버 카페 Vue 패턴 확인됨');
                    }
                    
                    // 네이버 카페 특화 무한스크롤 데이터 수집
                    const cafeArticles = document.querySelectorAll('.article-board .article, .article-list .item');
                    if (cafeArticles.length > 0) {
                        infiniteScrollData.loadedItems = cafeArticles.length;
                        infiniteScrollData.hasMore = true;
                        detailedLogs.push('네이버 카페 게시글 수집: ' + cafeArticles.length + '개');
                    }
                }
                
                // Vue 상태 정리
                if (hasInfiniteScroll) {
                    infiniteScrollData.currentPage = currentPage;
                    infiniteScrollData.detectedAt = Date.now();
                }
                
                vueAnalysis.isVueApp = isVueApp;
                vueAnalysis.vueVersion = vueVersion;
                vueAnalysis.hasVueRouter = hasVueRouter;
                vueAnalysis.hasInfiniteScroll = hasInfiniteScroll;
                vueAnalysis.currentPage = currentPage;
                vueAnalysis.componentCount = componentStates.length;
                vueAnalysis.infiniteScrollData = infiniteScrollData;
                vueAnalysis.componentStates = componentStates;
                
                detailedLogs.push('🅥 [Step 1] Vue 감지 완료: ' + (isVueApp ? '감지됨' : '미감지'));
                detailedLogs.push('🅥 Vue 버전: ' + vueVersion);
                detailedLogs.push('🅥 라우터: ' + (hasVueRouter ? '있음' : '없음'));
                detailedLogs.push('🅥 무한스크롤: ' + (hasInfiniteScroll ? '감지됨' : '미감지'));
                detailedLogs.push('🅥 컴포넌트 수: ' + componentStates.length);
                
                // 👁️ **Step 2: 실제 보이는 영역 계산 (정확한 뷰포트)**
                const actualViewportRect = {
                    top: scrollY,
                    left: scrollX,
                    bottom: scrollY + viewportHeight,
                    right: scrollX + viewportWidth,
                    width: viewportWidth,
                    height: viewportHeight
                };
                
                detailedLogs.push('👁️ [Step 2] 실제 보이는 영역 계산');
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
                    
                    // 🧹 **의미없는 텍스트 패턴들**
                    const meaninglessPatterns = [
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
                    
                    for (let i = 0; i < meaninglessPatterns.length; i++) {
                        const pattern = meaninglessPatterns[i];
                        if (pattern.test(cleanText)) {
                            return false;
                        }
                    }
                    
                    return true;
                }
                
                detailedLogs.push('👁️ [Step 2] 가시성 및 품질 함수 로드 완료');
                
                // 👁️ **Step 3: 핵심 개선: 보이는 요소만 4요소 패키지 앵커 수집**
                function collectVisibleFourElementPackageAnchors() {
                    const anchors = [];
                    const visibilityStats = {
                        totalCandidates: 0,
                        visibilityChecked: 0,
                        actuallyVisible: 0,
                        qualityFiltered: 0,
                        finalAnchors: 0
                    };
                    
                    detailedLogs.push('👁️ [Step 3] 보이는 뷰포트 영역: ' + actualViewportRect.top.toFixed(1) + ' ~ ' + actualViewportRect.bottom.toFixed(1) + 'px');
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
                    
                    // 👁️ **뷰포트 중심에서 가까운 순으로 정렬하여 상위 20개 선택**
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
                    
                    const selectedElements = visibleElements.slice(0, 20); // 👁️ 20개로 제한
                    visibilityStats.finalAnchors = selectedElements.length;
                    
                    detailedLogs.push('뷰포트 중심 기준 정렬 후 상위 ' + selectedElements.length + '개 선택');
                    
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
                        
                        // 클래스명/태그명 기반 타입 추론
                        if (className.includes('comment') || className.includes('reply')) {
                            contentType = 'comment';
                            packageScore += 15;
                        } else if (className.includes('post') || className.includes('article')) {
                            contentType = 'post';
                            packageScore += 15;
                        } else if (tagName === 'article') {
                            contentType = 'article';
                            packageScore += 12;
                        } else if (tagName === 'li') {
                            contentType = 'item';
                            packageScore += 10;
                        } else {
                            contentType = tagName; // 태그명을 타입으로
                            packageScore += 3;
                        }
                        
                        fourElementPackage.type = contentType;
                        detailedLogs.push('   👁️ 4요소[type]: "' + contentType + '"');
                        
                        // ③ **타임스탬프 (ts)**
                        let timestamp = new Date().toISOString();
                        packageScore += 2;
                        fourElementPackage.ts = timestamp;
                        detailedLogs.push('   👁️ 4요소[ts]: "' + timestamp + '"');
                        
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
                        
                        // 고유 ID 보너스
                        if (uniqueId && !uniqueId.startsWith('auto_')) qualityScore += 10; // 실제 고유 ID
                        
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
                
                // 👁️ **메인 실행 - Vue.js + 보이는 요소 통합 데이터 수집**
                const startTime = Date.now();
                const packageAnchorsData = collectVisibleFourElementPackageAnchors();
                const endTime = Date.now();
                const captureTime = endTime - startTime;
                
                captureStats.captureTime = captureTime;
                pageAnalysis.capturePerformance = {
                    totalTime: captureTime,
                    anchorsPerSecond: packageAnchorsData.anchors.length > 0 ? (packageAnchorsData.anchors.length / (captureTime / 1000)).toFixed(2) : 0
                };
                
                detailedLogs.push('=== Vue.js + 보이는 요소 통합 캡처 완료 (' + captureTime + 'ms) ===');
                detailedLogs.push('최종 Vue 상태: Vue앱=' + isVueApp + ', 무한스크롤=' + hasInfiniteScroll + ', 페이지=' + currentPage);
                detailedLogs.push('최종 보이는 4요소 패키지 앵커: ' + packageAnchorsData.anchors.length + '개');
                detailedLogs.push('처리 성능: ' + pageAnalysis.capturePerformance.anchorsPerSecond + ' 앵커/초');
                
                console.log('🅥 Vue.js + 보이는 요소 통합 캡처 완료:', {
                    vueState: vueAnalysis,
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
                    vueState: vueAnalysis,                          // 🅥 **Vue.js 상태 정보**
                    fourElementPackageAnchors: packageAnchorsData,  // 🎯 **보이는 요소만 4요소 패키지 데이터**
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
                console.error('🅥 Vue.js + 보이는 요소 통합 캡처 실패:', e);
                return {
                    vueState: { isVueApp: false, error: e.message },
                    fourElementPackageAnchors: { anchors: [], stats: {} },
                    scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message,
                    detailedLogs: ['Vue.js + 보이는 요소 통합 캡처 실패: ' + e.message],
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
