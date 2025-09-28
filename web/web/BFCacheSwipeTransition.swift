//
//  BFCacheSnapshotManager.swift
//  📸 **순차적 4단계 BFCache 복원 시스템**
//  🎯 **Step 3**: 앵커 기반 복원 (최우선) - 동적 사이트 우선
//  📏 **Step 2**: 상대좌표 기반 스크롤 복원 (보조)
//  📦 **Step 1**: 저장 콘텐츠 높이 복원 (정적 사이트용)
//  ✅ **Step 4**: 최종 검증 및 미세 보정
//  ⏰ **렌더링 대기**: 각 단계별 필수 대기시간 적용
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용
//  🎯 **스크롤러 자동 검출**: 실제 스크롤 가능 요소 감지
//  🔧 **비동기 구조 유지**: Promise 체이닝으로 타입 오류 해결

import UIKit
import WebKit
import SwiftUI

// MARK: - 📸 **무한스크롤 전용 앵커 조합 BFCache 페이지 스냅샷**
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
            step1RenderDelay: 0.2,
            step2RenderDelay: 0.2,
            step3RenderDelay: 0.3,
            step4RenderDelay: 0.4
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
        case restorationConfig
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
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // MARK: - 🎯 **핵심: 순차적 4단계 복원 시스템 - 우선순위 재배치**
    
    // 복원 컨텍스트 구조체
    private struct RestorationContext {
        let snapshot: BFCacheSnapshot
        weak var webView: WKWebView?
        let completion: (Bool) -> Void
        var overallSuccess: Bool = false
    }
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 순차적 4단계 BFCache 복원 시작 (앵커 우선)")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 저장 콘텐츠 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")
        TabPersistenceManager.debugMessages.append("⏰ 렌더링 대기시간: Step3=\(restorationConfig.step3RenderDelay)s, Step2=\(restorationConfig.step2RenderDelay)s, Step1=\(restorationConfig.step1RenderDelay)s, Step4=\(restorationConfig.step4RenderDelay)s")
        
        // 복원 컨텍스트 생성
        let context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: completion
        )
        
        // 🎯 **변경: Step 3(앵커)를 최우선으로 실행**
        executeStep3_AnchorRestore(context: context)
    }
    
    // MARK: - Step 3: 무한스크롤 전용 앵커 복원 (최우선)
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🔍 [Step 3 - 최우선] 무한스크롤 전용 앵커 정밀 복원 시작")
        
        guard restorationConfig.enableAnchorRestore else {
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step3RenderDelay) {
                self.executeStep2_PercentScroll(context: context)
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
        
        let js = generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: infiniteScrollAnchorDataJSON)
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step3Success = false
            var updatedContext = context
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🔍 [Step 3] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step3Success = (resultDict["success"] as? Bool) ?? false
                
                if let anchorCount = resultDict["anchorCount"] as? Int {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 사용 가능한 앵커: \(anchorCount)개")
                }
                if let matchedAnchor = resultDict["matchedAnchor"] as? [String: Any] {
                    if let anchorType = matchedAnchor["anchorType"] as? String {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭된 앵커 타입: \(anchorType)")
                    }
                    if let method = matchedAnchor["matchMethod"] as? String {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭 방법: \(method)")
                    }
                    if let confidence = matchedAnchor["confidence"] as? Double {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭 신뢰도: \(String(format: "%.1f", confidence))%")
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
                
                // 앵커 복원 성공 시 전체 성공으로 간주
                if step3Success {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] ✅ 앵커 복원 성공 - 전체 복원 성공으로 간주")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 완료: \(step3Success ? "성공" : "실패") - 다음 단계 진행")
            TabPersistenceManager.debugMessages.append("⏰ [Step 3] 렌더링 대기: \(self.restorationConfig.step3RenderDelay)초")
            
            // 성공/실패 관계없이 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step3RenderDelay) {
                self.executeStep2_PercentScroll(context: updatedContext)
            }
        }
    }
    
    // MARK: - Step 2: 상대좌표 기반 스크롤 (보조)
    private func executeStep2_PercentScroll(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📏 [Step 2 - 보조] 상대좌표 기반 스크롤 복원 시작")
        
        // 이미 앵커로 성공했으면 스킵
        if context.overallSuccess {
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 이미 앵커 복원 성공 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step2RenderDelay) {
                self.executeStep1_RestoreContentHeight(context: context)
            }
            return
        }
        
        guard restorationConfig.enablePercentRestore else {
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step2RenderDelay) {
                self.executeStep1_RestoreContentHeight(context: context)
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
                
                // 백분율 복원 성공 시 (앵커가 실패한 경우만)
                if step2Success && !updatedContext.overallSuccess {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] ✅ 백분율 복원 성공")
                }
            }
            
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 완료: \(step2Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 2] 렌더링 대기: \(self.restorationConfig.step2RenderDelay)초")
            
            // 성공/실패 관계없이 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step2RenderDelay) {
                self.executeStep1_RestoreContentHeight(context: updatedContext)
            }
        }
    }
    
    // MARK: - Step 1: 저장 콘텐츠 높이 복원 (정적 사이트용)
    private func executeStep1_RestoreContentHeight(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📦 [Step 1 - 정적용] 저장 콘텐츠 높이 복원 시작")
        
        // 이미 성공했으면 스킵
        if context.overallSuccess {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 이미 복원 성공 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step1RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
            return
        }
        
        guard restorationConfig.enableContentRestore else {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 비활성화됨 - 스킵")
            // 렌더링 대기 후 다음 단계
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step1RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
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
                TabPersistenceManager.debugMessages.append("🎯 전체 BFCache 복원 완료: \(finalSuccess ? "성공" : "실패")")
                context.completion(finalSuccess)
            }
        }
    }
    
    // MARK: - 🎯 JavaScript 생성 메서드들 - Promise 체이닝 방식
    
    // 🎯 **공통 유틸리티 스크립트 생성 - 비동기 유지**
    private func generateCommonUtilityScript() -> String {
        return """
        // 🎯 **스크롤러 자동 검출 및 공통 유틸리티**
        
        // 캐시된 스크롤러
        window._bfcacheCachedScroller = null;
        
        function detectSingleScroller() {
            if (window._bfcacheCachedScroller && document.contains(window._bfcacheCachedScroller)) {
                return window._bfcacheCachedScroller;
            }
            
            // 후보 요소들 수집
            const candidates = [
                document.scrollingElement,
                document.documentElement,
                document.body
            ];
            
            // overflow 스타일이 있는 요소들 추가
            document.querySelectorAll('[style*="overflow"], [class*="scroll"], .container, .wrapper').forEach(el => {
                if (el && !candidates.includes(el)) {
                    candidates.push(el);
                }
            });
            
            let bestElement = candidates[0];
            let bestScore = 0;
            
            candidates.forEach(el => {
                if (!el) return;
                const hasVerticalScroll = el.scrollHeight > el.clientHeight;
                const hasHorizontalScroll = el.scrollWidth > el.clientWidth;
                const score = (el.scrollHeight - el.clientHeight) + (el.scrollWidth - el.clientWidth);
                
                if (score > bestScore && (hasVerticalScroll || hasHorizontalScroll)) {
                    bestElement = el;
                    bestScore = score;
                }
            });
            
            window._bfcacheCachedScroller = bestElement || document.scrollingElement || document.documentElement;
            return window._bfcacheCachedScroller;
        }
        
        function getROOT() { 
            return detectSingleScroller();
        }
        
        function getMaxScroll() { 
            const r = getROOT(); 
            return { 
                x: Math.max(0, r.scrollWidth - (r.clientWidth || window.innerWidth)),
                y: Math.max(0, r.scrollHeight - (r.clientHeight || window.innerHeight))
            }; 
        }
        
        // 비동기 안정화 대기 (requestAnimationFrame 기반)
        async function waitForStableLayout(options = {}) {
            const { frames = 6, timeout = 1500, threshold = 2 } = options;
            const ROOT = getROOT();
            let last = ROOT.scrollHeight;
            let stable = 0;
            const startTime = Date.now();
            
            return new Promise((resolve) => {
                function check() {
                    const h = ROOT.scrollHeight;
                    if (Math.abs(h - last) <= threshold) {
                        stable++;
                    } else {
                        stable = 0;
                    }
                    last = h;
                    
                    if (stable >= frames || Date.now() - startTime > timeout) {
                        resolve();
                    } else {
                        requestAnimationFrame(check);
                    }
                }
                requestAnimationFrame(check);
            });
        }
        
        // 비동기 정밀 스크롤
        async function preciseScrollTo(x, y) {
            const ROOT = getROOT();
            
            ROOT.scrollLeft = x;
            ROOT.scrollTop = y;
            
            await new Promise(r => requestAnimationFrame(r));
            
            ROOT.scrollLeft = x;
            ROOT.scrollTop = y;
            
            await new Promise(r => requestAnimationFrame(r));
            
            return { x: ROOT.scrollLeft || 0, y: ROOT.scrollTop || 0 };
        }
        
        function fixedHeaderHeight() {
            const cands = document.querySelectorAll('header, [class*="header"], [class*="gnb"], [class*="navbar"], [class*="nav-bar"]');
            let h = 0;
            cands.forEach(el => {
                const cs = getComputedStyle(el);
                if (cs.position === 'fixed' || cs.position === 'sticky') {
                    h = Math.max(h, el.getBoundingClientRect().height);
                }
            });
            return h;
        }
        
        // 비동기 프리롤 (무한스크롤 트리거)
        async function prerollInfinite(maxSteps = 6) {
            const ROOT = getROOT();
            for (let i = 0; i < maxSteps; i++) {
                const before = ROOT.scrollHeight;
                ROOT.scrollTop = before;
                window.dispatchEvent(new Event('scroll', { bubbles: true }));
                
                await new Promise(r => requestAnimationFrame(r));
                
                const after = ROOT.scrollHeight;
                if (after - before < 64) break;
            }
            
            await waitForStableLayout();
        }
        
        // 🎯 **환경 안정화 (한 번만 실행)**
        (function hardenEnv() {
            if (window._bfcacheEnvHardened) return;
            window._bfcacheEnvHardened = true;
            
            try { 
                history.scrollRestoration = 'manual'; 
            } catch(e) {}
            
            const style = document.createElement('style');
            style.textContent = \`
                html, body { 
                    overflow-anchor: none !important; 
                    scroll-behavior: auto !important; 
                    -webkit-text-size-adjust: 100% !important; 
                }
            \`;
            document.documentElement.appendChild(style);
        })();
        """
    }
    
    private func generateStep1_ContentRestoreScript() -> String {
        let targetHeight = restorationConfig.savedContentHeight
        
        return """
        // Promise 체이닝 방식으로 수정
        (async function() {
            \(generateCommonUtilityScript())
            
            const logs = [];
            const targetHeight = parseFloat('\(targetHeight)');
            const ROOT = getROOT();
            const currentHeight = ROOT.scrollHeight;
            
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
            
            // 동적 사이트 - 콘텐츠 로드 시도 (비동기)
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
            
            // 비동기 무한스크롤 트리거
            await prerollInfinite(3);
            
            const restoredHeight = ROOT.scrollHeight;
            const finalPercentage = (restoredHeight / targetHeight) * 100;
            const success = finalPercentage >= 80;
            
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
        })().then(result => result).catch(e => ({
            success: false,
            error: e.message,
            logs: ['[Step 1] 오류: ' + e.message]
        }))
        """
    }
    
    private func generateStep2_PercentScrollScript() -> String {
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        
        return """
        // Promise 체이닝 방식으로 수정
        (async function() {
            \(generateCommonUtilityScript())
            
            const logs = [];
            const targetPercentX = parseFloat('\(targetPercentX)');
            const targetPercentY = parseFloat('\(targetPercentY)');
            
            logs.push('[Step 2] 상대좌표 기반 스크롤 복원');
            logs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
            
            // 비동기 안정화 대기
            await waitForStableLayout({ frames: 3, timeout: 1000 });
            
            const ROOT = getROOT();
            const max = getMaxScroll();
            
            logs.push('최대 스크롤: X=' + max.x.toFixed(0) + 'px, Y=' + max.y.toFixed(0) + 'px');
            
            // 백분율 기반 목표 위치 계산
            const targetX = (targetPercentX / 100) * max.x;
            const targetY = (targetPercentY / 100) * max.y;
            
            logs.push('계산된 목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
            
            // 비동기 정밀 스크롤
            const result = await preciseScrollTo(targetX, targetY);
            
            const diffX = Math.abs(result.x - targetX);
            const diffY = Math.abs(result.y - targetY);
            
            logs.push('실제 위치: X=' + result.x.toFixed(1) + 'px, Y=' + result.y.toFixed(1) + 'px');
            logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
            
            // 무한스크롤은 허용 오차 크게 (100px)
            const success = diffY <= 100;
            
            return {
                success: success,
                targetPercent: { x: targetPercentX, y: targetPercentY },
                calculatedPosition: { x: targetX, y: targetY },
                actualPosition: { x: result.x, y: result.y },
                difference: { x: diffX, y: diffY },
                logs: logs
            };
        })().then(result => result).catch(e => ({
            success: false,
            error: e.message,
            logs: ['[Step 2] 오류: ' + e.message]
        }))
        """
    }
    
    private func generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: String) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        // Promise 체이닝 방식으로 수정
        (async function() {
            \(generateCommonUtilityScript())
            
            const logs = [];
            const targetX = parseFloat('\(targetX)');
            const targetY = parseFloat('\(targetY)');
            const infiniteScrollAnchorData = \(anchorDataJSON);
            
            logs.push('[Step 3] 무한스크롤 전용 앵커 복원 (최우선)');
            logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
            
            // overflow-anchor 비활성화
            document.documentElement.style.overflowAnchor = 'none';
            
            // 앵커 데이터 확인
            if (!infiniteScrollAnchorData || !infiniteScrollAnchorData.anchors || infiniteScrollAnchorData.anchors.length === 0) {
                logs.push('무한스크롤 앵커 데이터 없음 - 프리롤 시도');
                
                // 앵커가 없으면 프리롤 수행
                await prerollInfinite(5);
                
                document.documentElement.style.overflowAnchor = '';
                return {
                    success: false,
                    anchorCount: 0,
                    logs: logs
                };
            }
            
            const anchors = infiniteScrollAnchorData.anchors;
            logs.push('사용 가능한 앵커: ' + anchors.length + '개');
            
            // 앵커 등장 감시 (비동기 루프)
            let foundElement = null;
            let matchedAnchor = null;
            let matchMethod = '';
            let confidence = 0;
            const deadline = performance.now() + 6000; // 6초 제한
            
            // 프리롤하면서 앵커 찾기
            async function findAnchorsWithPreroll() {
                const ROOT = getROOT();
                let prerollCount = 0;
                
                while (performance.now() < deadline && !foundElement && prerollCount < 10) {
                    // 현재 DOM에서 앵커 찾기
                    foundElement = await findFirstMatchingAnchor();
                    
                    if (!foundElement) {
                        // 바닥으로 스크롤하여 동적 로딩 트리거
                        const before = ROOT.scrollHeight;
                        ROOT.scrollTop = ROOT.scrollHeight;
                        window.dispatchEvent(new Event('scroll', { bubbles: true }));
                        
                        await new Promise(r => requestAnimationFrame(r));
                        await new Promise(r => setTimeout(r, 100)); // 100ms 대기
                        
                        const after = ROOT.scrollHeight;
                        if (after - before < 64) break; // 더 이상 로드되지 않음
                        
                        prerollCount++;
                        logs.push('프리롤 ' + prerollCount + '회: 높이 ' + before + ' → ' + after);
                    }
                }
                
                return foundElement;
            }
            
            // 앵커 매칭 함수
            async function findFirstMatchingAnchor() {
                // Vue Component 앵커 우선
                const vueAnchors = anchors.filter(a => a.anchorType === 'vueComponent');
                for (let anchor of vueAnchors) {
                    const el = findVueElement(anchor);
                    if (el) {
                        matchedAnchor = anchor;
                        matchMethod = 'vue_component';
                        confidence = 95;
                        return el;
                    }
                }
                
                // Content Hash 앵커
                const hashAnchors = anchors.filter(a => a.anchorType === 'contentHash');
                for (let anchor of hashAnchors) {
                    const el = findHashElement(anchor);
                    if (el) {
                        matchedAnchor = anchor;
                        matchMethod = 'content_hash';
                        confidence = 80;
                        return el;
                    }
                }
                
                // Virtual Index 앵커
                const indexAnchors = anchors.filter(a => a.anchorType === 'virtualIndex');
                for (let anchor of indexAnchors) {
                    const el = findIndexElement(anchor);
                    if (el) {
                        matchedAnchor = anchor;
                        matchMethod = 'virtual_index';
                        confidence = 60;
                        return el;
                    }
                }
                
                return null;
            }
            
            function findVueElement(anchor) {
                if (!anchor.vueComponent) return null;
                const vueComp = anchor.vueComponent;
                
                if (vueComp.dataV) {
                    const elements = document.querySelectorAll('[' + vueComp.dataV + ']');
                    for (let el of elements) {
                        if (vueComp.name && el.className.includes(vueComp.name)) {
                            return el;
                        }
                    }
                }
                return null;
            }
            
            function findHashElement(anchor) {
                if (!anchor.contentHash) return null;
                const hash = anchor.contentHash;
                
                if (hash.text && hash.text.length > 20) {
                    const searchText = hash.text.substring(0, 50);
                    const allElements = document.querySelectorAll('*');
                    for (let el of allElements) {
                        if ((el.textContent || '').includes(searchText)) {
                            return el;
                        }
                    }
                }
                return null;
            }
            
            function findIndexElement(anchor) {
                if (!anchor.virtualIndex) return null;
                const vIdx = anchor.virtualIndex;
                
                if (vIdx.listIndex !== undefined) {
                    const listElements = document.querySelectorAll('li, .item, .list-item');
                    if (vIdx.listIndex < listElements.length) {
                        return listElements[vIdx.listIndex];
                    }
                }
                return null;
            }
            
            // 앵커 찾기 실행
            foundElement = await findAnchorsWithPreroll();
            
            if (foundElement && matchedAnchor) {
                const ROOT = getROOT();
                const rect = foundElement.getBoundingClientRect();
                const isRootElement = (ROOT === document.documentElement || ROOT === document.body);
                
                // 절대 위치 계산 (스크롤러에 따라 다르게)
                const scrollTop = isRootElement ? window.pageYOffset : ROOT.scrollTop;
                const scrollLeft = isRootElement ? window.pageXOffset : ROOT.scrollLeft;
                
                const absY = scrollTop + rect.top;
                const headerHeight = fixedHeaderHeight();
                const finalY = Math.max(0, absY - headerHeight);
                
                // 오프셋 보정
                let adjustedY = finalY;
                if (matchedAnchor.offsetFromTop) {
                    adjustedY = Math.max(0, finalY - matchedAnchor.offsetFromTop);
                }
                
                // 스크롤 실행
                await preciseScrollTo(scrollLeft, adjustedY);
                
                const actualX = ROOT.scrollLeft || 0;
                const actualY = ROOT.scrollTop || 0;
                const diffX = Math.abs(actualX - targetX);
                const diffY = Math.abs(actualY - targetY);
                
                logs.push('앵커 복원 후 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                logs.push('목표와의 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                logs.push('매칭 신뢰도: ' + confidence + '%');
                
                document.documentElement.style.overflowAnchor = '';
                
                return {
                    success: diffY <= 150, // 무한스크롤은 150px 허용
                    anchorCount: anchors.length,
                    matchedAnchor: {
                        anchorType: matchedAnchor.anchorType,
                        matchMethod: matchMethod,
                        confidence: confidence
                    },
                    restoredPosition: { x: actualX, y: actualY },
                    targetDifference: { x: diffX, y: diffY },
                    logs: logs
                };
            }
            
            document.documentElement.style.overflowAnchor = '';
            logs.push('무한스크롤 앵커 매칭 실패');
            
            return {
                success: false,
                anchorCount: anchors.length,
                logs: logs
            };
        })().then(result => result).catch(e => {
            document.documentElement.style.overflowAnchor = '';
            return {
                success: false,
                error: e.message,
                logs: ['[Step 3] 오류: ' + e.message]
            };
        })
        """
    }
    
    private func generateStep4_FinalVerificationScript() -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        // Promise 체이닝 방식으로 수정
        (async function() {
            \(generateCommonUtilityScript())
            
            const logs = [];
            const targetX = parseFloat('\(targetX)');
            const targetY = parseFloat('\(targetY)');
            const tolerance = 50; // 허용 오차 증가
            
            logs.push('[Step 4] 최종 검증 및 미세 보정');
            logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
            
            const ROOT = getROOT();
            
            // 현재 위치 확인
            let currentX = ROOT.scrollLeft || 0;
            let currentY = ROOT.scrollTop || 0;
            
            let diffX = Math.abs(currentX - targetX);
            let diffY = Math.abs(currentY - targetY);
            
            logs.push('현재 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
            logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
            
            const withinTolerance = diffX <= tolerance && diffY <= tolerance;
            let correctionApplied = false;
            
            // 허용 오차 초과 시 미세 보정
            if (!withinTolerance) {
                logs.push('허용 오차 초과 - 미세 보정 적용');
                
                await preciseScrollTo(targetX, targetY);
                correctionApplied = true;
                
                // 보정 후 위치 재측정
                currentX = ROOT.scrollLeft || 0;
                currentY = ROOT.scrollTop || 0;
                diffX = Math.abs(currentX - targetX);
                diffY = Math.abs(currentY - targetY);
                
                logs.push('보정 후 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                logs.push('보정 후 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
            }
            
            const success = diffY <= 100; // 최종 허용 오차
            
            return {
                success: success,
                targetPosition: { x: targetX, y: targetY },
                finalPosition: { x: currentX, y: currentY },
                finalDifference: { x: diffX, y: diffY },
                withinTolerance: diffX <= tolerance && diffY <= tolerance,
                correctionApplied: correctionApplied,
                logs: logs
            };
        })().then(result => result).catch(e => ({
            success: false,
            error: e.message,
            logs: ['[Step 4] 오류: ' + e.message]
        }))
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
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 - 다중 구역 앵커 캡처**
    
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
        TabPersistenceManager.debugMessages.append("🚀 다중 구역 앵커 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
        
        TabPersistenceManager.debugMessages.append("🚀 다중 구역 앵커 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            // 캡처 데이터 수집
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                contentSize: webView.scrollView.contentSize,
                viewportSize: webView.bounds.size,
                actualScrollableSize: CGSize(
                    width: max(webView.scrollView.contentSize.width, webView.scrollView.bounds.width),
                    height: max(webView.scrollView.contentSize.height, webView.scrollView.bounds.height)
                ),
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            return
        }
        
        // 🔧 **개선된 캡처 로직 - 실패 시 재시도**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        // 🔥 **캡처된 jsState 상세 로깅**
        if let jsState = captureResult.snapshot.jsState {
            TabPersistenceManager.debugMessages.append("🔥 캡처된 jsState 키: \(Array(jsState.keys))")
            
            if let infiniteScrollAnchors = jsState["infiniteScrollAnchors"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🚀 캡처된 다중 구역 앵커 데이터 키: \(Array(infiniteScrollAnchors.keys))")
                
                if let anchors = infiniteScrollAnchors["anchors"] as? [[String: Any]] {
                    // 앵커 타입별 카운트
                    let vueComponentCount = anchors.filter { ($0["anchorType"] as? String) == "vueComponent" }.count
                    let contentHashCount = anchors.filter { ($0["anchorType"] as? String) == "contentHash" }.count
                    let virtualIndexCount = anchors.filter { ($0["anchorType"] as? String) == "virtualIndex" }.count
                    
                    TabPersistenceManager.debugMessages.append("🚀 앵커 타입별: Vue=\(vueComponentCount), Hash=\(contentHashCount), Index=\(virtualIndexCount)")
                    
                    // 구역별 분포 확인
                    if let zones = infiniteScrollAnchors["zones"] as? [String] {
                        TabPersistenceManager.debugMessages.append("📊 캡처 구역: \(zones.joined(separator: ", "))")
                    }
                }
            }
        }
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ 다중 구역 앵커 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize
        let viewportSize: CGSize
        let actualScrollableSize: CGSize
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔧 **실패 복구 기능 추가된 캡처**
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
            
            // 재시도 전 잠시 대기
            TabPersistenceManager.debugMessages.append("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08)
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
        
        // 1. 비주얼 스냅샷 (메인 스레드)
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
        
        // 2. DOM 캡처
        let domSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 시작")
        
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
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
                    return html.length > 500000 ? html.substring(0, 500000) : html;
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
        _ = domSemaphore.wait(timeout: .now() + 5.0)
        
        // 3. **다중 구역 앵커 JS 상태 캡처**
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 다중 구역 앵커 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateMultiZoneAnchorCaptureScript() // 🎯 **수정된: 다중 구역 앵커 캡처**
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                    
                    // 📊 **상세 캡처 결과 로깅**
                    if let infiniteScrollAnchors = data["infiniteScrollAnchors"] as? [String: Any] {
                        if let anchors = infiniteScrollAnchors["anchors"] as? [[String: Any]] {
                            TabPersistenceManager.debugMessages.append("🚀 JS 캡처된 앵커: 총 \(anchors.count)개")
                        }
                        if let zones = infiniteScrollAnchors["zones"] as? [String] {
                            TabPersistenceManager.debugMessages.append("📊 캡처 구역: \(zones.joined(separator: ", "))")
                        }
                    }
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 3.0)
        
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
        
        // 백분율 계산
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.height > captureData.viewportSize.height || captureData.actualScrollableSize.width > captureData.viewportSize.width {
            let maxScrollX = max(0, captureData.actualScrollableSize.width - captureData.viewportSize.width)
            let maxScrollY = max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height)
            
            scrollPercent = CGPoint(
                x: maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        TabPersistenceManager.debugMessages.append("📊 캡처 완료: 위치=(\(String(format: "%.1f", captureData.scrollPosition.x)), \(String(format: "%.1f", captureData.scrollPosition.y))), 백분율=(\(String(format: "%.2f", scrollPercent.x))%, \(String(format: "%.2f", scrollPercent.y))%)")
        
        // 🔄 **순차 실행 설정 생성**
        let restorationConfig = BFCacheSnapshot.RestorationConfig(
            enableContentRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height),
            step1RenderDelay: 0.2,
            step2RenderDelay: 0.3,
            step3RenderDelay: 0.3,
            step4RenderDelay: 0.4
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
            restorationConfig: restorationConfig
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🚀 **수정: 다중 구역 앵커 캡처 스크립트**
    private func generateMultiZoneAnchorCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 다중 구역 앵커 캡처 시작');
                
                // 스크롤러 자동 검출
                function detectSingleScroller() {
                    const candidates = [
                        document.scrollingElement,
                        document.documentElement,
                        document.body
                    ];
                    
                    document.querySelectorAll('[style*="overflow"], [class*="scroll"]').forEach(el => {
                        if (el && !candidates.includes(el)) candidates.push(el);
                    });
                    
                    let best = candidates[0];
                    let bestScore = 0;
                    
                    candidates.forEach(el => {
                        if (!el) return;
                        const score = (el.scrollHeight - el.clientHeight) + (el.scrollWidth - el.clientWidth);
                        if (score > bestScore) {
                            best = el;
                            bestScore = score;
                        }
                    });
                    
                    return best || document.scrollingElement || document.documentElement;
                }
                
                function getROOT() {
                    return detectSingleScroller();
                }
                
                const ROOT = getROOT();
                const scrollY = parseFloat(ROOT.scrollTop) || 0;
                const scrollX = parseFloat(ROOT.scrollLeft) || 0;
                const viewportHeight = parseFloat(ROOT.clientHeight || window.innerHeight) || 0;
                const viewportWidth = parseFloat(ROOT.clientWidth || window.innerWidth) || 0;
                const contentHeight = parseFloat(ROOT.scrollHeight) || 0;
                const contentWidth = parseFloat(ROOT.scrollWidth) || 0;
                
                // 실제 보이는 영역
                const actualViewportRect = {
                    top: scrollY,
                    left: scrollX,
                    bottom: scrollY + viewportHeight,
                    right: scrollX + viewportWidth,
                    width: viewportWidth,
                    height: viewportHeight
                };
                
                // 가시성 판단
                function isElementVisible(element) {
                    if (!element || !element.getBoundingClientRect) return false;
                    
                    const rect = element.getBoundingClientRect();
                    if (rect.width === 0 || rect.height === 0) return false;
                    
                    const elementTop = scrollY + rect.top;
                    const elementBottom = scrollY + rect.bottom;
                    
                    // 뷰포트 내에 있거나 근처에 있는지
                    const margin = viewportHeight * 0.5; // 뷰포트의 50% 마진
                    return elementBottom > (actualViewportRect.top - margin) && 
                           elementTop < (actualViewportRect.bottom + margin);
                }
                
                // 의미있는 텍스트 필터링
                function isQualityText(text) {
                    if (!text || typeof text !== 'string') return false;
                    const cleanText = text.trim();
                    if (cleanText.length < 10) return false;
                    return true;
                }
                
                // 간단 해시
                function simpleHash(str) {
                    let hash = 0;
                    if (str.length === 0) return hash.toString(36);
                    for (let i = 0; i < str.length; i++) {
                        const char = str.charCodeAt(i);
                        hash = ((hash << 5) - hash) + char;
                        hash = hash & hash;
                    }
                    return Math.abs(hash).toString(36);
                }
                
                // data-v-* 속성 찾기
                function findDataVAttribute(element) {
                    if (!element || !element.attributes) return null;
                    
                    for (let i = 0; i < element.attributes.length; i++) {
                        const attr = element.attributes[i];
                        if (attr.name.startsWith('data-v-')) {
                            return attr.name;
                        }
                    }
                    return null;
                }
                
                // 🎯 **다중 구역 앵커 수집**
                function collectMultiZoneAnchors() {
                    const anchors = [];
                    const zones = [];
                    
                    // 구역 정의 (상단 20%, 중앙 60%, 하단 20%)
                    const zoneRanges = [
                        { name: 'top', start: 0.0, end: 0.3 },
                        { name: 'middle', start: 0.3, end: 0.7 },
                        { name: 'bottom', start: 0.7, end: 1.0 }
                    ];
                    
                    // 콘텐츠 요소 수집
                    const contentSelectors = [
                        'li', 'tr', '.item', '.list-item', '.card', '.post',
                        '.comment', '.feed', '[class*="item"]', '[data-testid]',
                        '[data-v-]'
                    ];
                    
                    let allElements = [];
                    contentSelectors.forEach(selector => {
                        try {
                            document.querySelectorAll(selector).forEach(el => {
                                if (!allElements.includes(el) && isElementVisible(el)) {
                                    allElements.push(el);
                                }
                            });
                        } catch(e) {}
                    });
                    
                    console.log('가시 요소 수집:', allElements.length, '개');
                    
                    // 각 구역별로 앵커 선택
                    zoneRanges.forEach(zone => {
                        const zoneTop = actualViewportRect.top + (viewportHeight * zone.start);
                        const zoneBottom = actualViewportRect.top + (viewportHeight * zone.end);
                        
                        const zoneElements = allElements.filter(el => {
                            const rect = el.getBoundingClientRect();
                            const elementTop = scrollY + rect.top;
                            const elementBottom = scrollY + rect.bottom;
                            
                            return elementTop >= zoneTop && elementTop <= zoneBottom;
                        });
                        
                        // 각 구역에서 최대 10개 선택
                        const selectedElements = zoneElements.slice(0, 10);
                        
                        selectedElements.forEach((element, index) => {
                            const rect = element.getBoundingClientRect();
                            const text = (element.textContent || '').trim();
                            const dataV = findDataVAttribute(element);
                            
                            if (text.length > 10) {
                                const anchor = {
                                    anchorType: dataV ? 'vueComponent' : 'contentHash',
                                    zone: zone.name,
                                    absolutePosition: { 
                                        top: scrollY + rect.top, 
                                        left: scrollX + rect.left 
                                    },
                                    viewportPosition: { 
                                        top: rect.top, 
                                        left: rect.left 
                                    },
                                    offsetFromTop: scrollY - (scrollY + rect.top),
                                    size: { 
                                        width: rect.width, 
                                        height: rect.height 
                                    },
                                    textContent: text.substring(0, 100),
                                    anchorIndex: anchors.length,
                                    zoneIndex: index
                                };
                                
                                if (dataV) {
                                    anchor.vueComponent = {
                                        dataV: dataV,
                                        name: element.className.split(' ')[0] || 'unknown',
                                        index: index
                                    };
                                } else {
                                    anchor.contentHash = {
                                        shortHash: simpleHash(text),
                                        text: text.substring(0, 100),
                                        length: text.length
                                    };
                                }
                                
                                anchors.push(anchor);
                            }
                        });
                        
                        if (selectedElements.length > 0) {
                            zones.push(zone.name + '(' + selectedElements.length + ')');
                        }
                    });
                    
                    return {
                        anchors: anchors,
                        zones: zones,
                        stats: {
                            totalCandidates: allElements.length,
                            finalAnchors: anchors.length,
                            zoneDistribution: zones
                        }
                    };
                }
                
                // 메인 실행
                const infiniteScrollAnchorsData = collectMultiZoneAnchors();
                
                console.log('🚀 다중 구역 앵커 캡처 완료:', {
                    anchorsCount: infiniteScrollAnchorsData.anchors.length,
                    zones: infiniteScrollAnchorsData.zones
                });
                
                return {
                    infiniteScrollAnchors: infiniteScrollAnchorsData,
                    scroll: { x: scrollX, y: scrollY },
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now(),
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
                console.error('🚀 다중 구역 앵커 캡처 실패:', e);
                return {
                    infiniteScrollAnchors: { anchors: [], zones: [], stats: {} },
                    scroll: { x: 0, y: 0 },
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
