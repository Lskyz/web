//
//  BFCacheSnapshotManager.swift
//  ?   **? 차??4? 계 BFCache 복원 ? 스??*
//  ?   **Step 1**: ? ??콘텐 ?? 이 복원 (? 적 ? 이? 만)
//  ?   **Step 2**: ?  ?좌표 기반 ? 크 ?복원 (최우??
//  ?   **Step 3**: 무한? 크 ?? 용 ? 커 ?  ? 복원
//  ??**Step 4**: 최종 검 ? ?미세 보정
//  ??**? 더 ??  ?*:  ?? 계 ?? 수 ? 기시 ?? 용
//  ?   **? ??? 전??*: Swift ? 환 기본 ? ? 만 ? 용

import UIKit
import WebKit
import SwiftUI

// MARK: - ?   **무한? 크 ?? 용 ? 커 조합 BFCache ? 이지 ? 냅??*
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint  // ??CGFloat 기반 ?  ? ? 크 ?
    let scrollPositionPercent: CGPoint  // ?   ?  ???? 치 (백분??
    let contentSize: CGSize  // ?   콘텐 ?? 기 ? 보
    let viewportSize: CGSize  // ?   뷰포??? 기 ? 보
    let actualScrollableSize: CGSize  // ? ️ **? 제 ? 크 ?가? 한 최 ? ? 기**
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // ?   **? 차 ? 행 ? 정**
    let restorationConfig: RestorationConfig
    
    struct RestorationConfig: Codable {
        let enableContentRestore: Bool      // Step 1 ? 성??
        let enablePercentRestore: Bool      // Step 2 ? 성??
        let enableAnchorRestore: Bool       // Step 3 ? 성??
        let enableFinalVerification: Bool   // Step 4 ? 성??
        let savedContentHeight: CGFloat     // ? ??? 점 콘텐 ?? 이
        let step1RenderDelay: Double        // Step 1 ??? 더 ??  ?(0.8 ?
        let step2RenderDelay: Double        // Step 2 ??? 더 ??  ?(0.3 ?
        let step3RenderDelay: Double        // Step 3 ??? 더 ??  ?(0.5 ?
        let step4RenderDelay: Double        // Step 4 ??? 더 ??  ?(0.3 ?
        
        static let `default` = RestorationConfig(
            enableContentRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: 0,
            step1RenderDelay: 0.2,
            step2RenderDelay: 0.2,
            step3RenderDelay: 0.2,
            step4RenderDelay: 0.2
        )
    }
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 ? 이??캡처 ? 공
        case partial        // ?  ? ?캡처 ? 공
        case visualOnly     // ?  ?지 ?캡처 ? 공
        case failed         // 캡처 ? 패
    }
    
    // Codable??? 한 CodingKeys
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
    
    // 직접 초기? 용 init (?  ? ? 크 ?지??
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
    
    // ?  ?지 로드 메서??
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // MARK: - ?   **? 심: ? 차??4? 계 복원 ? 스??*
    
    // 복원 컨텍? 트 구조 ?
    private struct RestorationContext {
        let snapshot: BFCacheSnapshot
        weak var webView: WKWebView?
        let completion: (Bool) -> Void
        var overallSuccess: Bool = false
    }
    
    private func safeDouble(from value: Any?) -> Double? {
        switch value {
        case let doubleValue as Double:
            return doubleValue
        case let cgValue as CGFloat:
            return Double(cgValue)
        case let number as NSNumber:
            return number.doubleValue
        case let intValue as Int:
            return Double(intValue)
        case let floatValue as Float:
            return Double(floatValue)
        case let stringValue as String:
            return Double(stringValue)
        default:
            return nil
        }
    }


    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("?   ? 차??4? 계 BFCache 복원 ? 작")
        TabPersistenceManager.debugMessages.append("?   복원 ? ?? \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("?   목표 ? 치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("?   목표 백분?? X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("?   ? ??콘텐 ?? 이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")
        TabPersistenceManager.debugMessages.append("??? 더 ?? 기시 ? Step1=\(restorationConfig.step1RenderDelay)s, Step2=\(restorationConfig.step2RenderDelay)s, Step3=\(restorationConfig.step3RenderDelay)s, Step4=\(restorationConfig.step4RenderDelay)s")
        
        // 복원 컨텍? 트 ? 성
        let context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: completion
        )
        
        // Step 1 ? 작
        executeStep1_RestoreContentHeight(context: context)
    }
    
    // MARK: - Step 1: ? ??콘텐 ?? 이 복원

    private func executeStep1_RestoreContentHeight(context: RestorationContext, attempt: Int = 0, previousHeight: Double? = nil) {
        let maxAttemptCount = 5
        let heightTolerance: Double = 4.0

        if attempt == 0 {
            TabPersistenceManager.debugMessages.append("?? [Step 1] ??????????? ?? ???")
        } else {
            TabPersistenceManager.debugMessages.append("?? [Step 1] ??? \(attempt + 1)/\(maxAttemptCount)")
        }

        guard restorationConfig.enableContentRestore else {
            TabPersistenceManager.debugMessages.append("?? [Step 1] ???????- ???")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step1RenderDelay) {
                self.executeStep2_PercentScroll(context: context)
            }
            return
        }

        let js = generateStep1_ContentRestoreScript()

        context.webView?.evaluateJavaScript(js) { result, error in
            var step1Success = false
            var currentHeightValue = previousHeight ?? 0
            var targetHeightValue = Double(self.restorationConfig.savedContentHeight)
            var restoredHeightValue = previousHeight ?? 0

            if let error = error {
                TabPersistenceManager.debugMessages.append("?? [Step 1] JavaScript ???: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step1Success = (resultDict["success"] as? Bool) ?? false

                if let currentHeight = self.safeDouble(from: resultDict["currentHeight"]) {
                    currentHeightValue = currentHeight
                    TabPersistenceManager.debugMessages.append("?? [Step 1] ??? ???: \(String(format: "%.0f", currentHeight))px")
                }
                if let targetHeight = self.safeDouble(from: resultDict["targetHeight"]) {
                    targetHeightValue = targetHeight
                    TabPersistenceManager.debugMessages.append("?? [Step 1] ?? ???: \(String(format: "%.0f", targetHeight))px")
                }
                if let restoredHeight = self.safeDouble(from: resultDict["restoredHeight"]) {
                    restoredHeightValue = restoredHeight
                    TabPersistenceManager.debugMessages.append("?? [Step 1] ???????: \(String(format: "%.0f", restoredHeight))px")
                }
                if let percentage = self.safeDouble(from: resultDict["percentage"]) {
                    TabPersistenceManager.debugMessages.append("?? [Step 1] ???? \(String(format: "%.1f", percentage))%")
                }
                if let isStatic = resultDict["isStaticSite"] as? Bool, isStatic {
                    TabPersistenceManager.debugMessages.append("?? [Step 1] ??? ?????- ?????? ????")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }

            if let prevHeight = previousHeight {
                let delta = restoredHeightValue - prevHeight
                TabPersistenceManager.debugMessages.append("?? [Step 1] ?? ?? ??: \(String(format: "%.0f", delta))px")
            }

            let fallbackTarget = Double(self.restorationConfig.savedContentHeight)
            let effectiveTarget = max(targetHeightValue, fallbackTarget)
            let heightDifference = effectiveTarget > 0 ? abs(effectiveTarget - restoredHeightValue) : 0
            let canRetry = attempt + 1 < maxAttemptCount
            let shouldRetry = canRetry && effectiveTarget > 0 && heightDifference > heightTolerance

            if shouldRetry {
                let retryDelay = max(self.restorationConfig.step1RenderDelay, 0.3)
                TabPersistenceManager.debugMessages.append("?? [Step 1] ?? ??? - ??? ?? (diff=\(String(format: "%.0f", heightDifference))px)")
                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
                    self.executeStep1_RestoreContentHeight(context: context, attempt: attempt + 1, previousHeight: restoredHeightValue)
                }
                return
            }

            if effectiveTarget > 0 {
                TabPersistenceManager.debugMessages.append("?? [Step 1] ?? ?? ??: \(String(format: "%.0f", heightDifference))px (??=\(String(format: "%.0f", effectiveTarget))px, ??=\(String(format: "%.0f", restoredHeightValue))px)")
            }

            TabPersistenceManager.debugMessages.append("?? [Step 1] ???: \(step1Success ? "???" : "???") - ?????? ?? ??")
            TabPersistenceManager.debugMessages.append("??[Step 1] ????????? \(self.restorationConfig.step1RenderDelay)??)")

            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step1RenderDelay) {
                self.executeStep2_PercentScroll(context: context)
            }
        }
    }
// MARK: - Step 2: ?  ?좌표 기반 ? 크 ?(최우??
    private func executeStep2_PercentScroll(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("?   [Step 2] ?  ?좌표 기반 ? 크 ?복원 ? 작 (최우??")
        
        guard restorationConfig.enablePercentRestore else {
            TabPersistenceManager.debugMessages.append("?   [Step 2] 비활? 화??- ? 킵")
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
                TabPersistenceManager.debugMessages.append("?   [Step 2] JavaScript ? 류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step2Success = (resultDict["success"] as? Bool) ?? false
                
                if let targetPercent = resultDict["targetPercent"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("?   [Step 2] 목표 백분?? X=\(String(format: "%.2f", targetPercent["x"] ?? 0))%, Y=\(String(format: "%.2f", targetPercent["y"] ?? 0))%")
                }
                if let calculatedPosition = resultDict["calculatedPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("?   [Step 2] 계산??? 치: X=\(String(format: "%.1f", calculatedPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", calculatedPosition["y"] ?? 0))px")
                }
                if let actualPosition = resultDict["actualPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("?   [Step 2] ? 제 ? 치: X=\(String(format: "%.1f", actualPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", actualPosition["y"] ?? 0))px")
                }
                if let difference = resultDict["difference"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("?   [Step 2] ? 치 차이: X=\(String(format: "%.1f", difference["x"] ?? 0))px, Y=\(String(format: "%.1f", difference["y"] ?? 0))px")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
                
                // ?  ?좌표 복원 ? 공 ??? 체 ? 공? 로 간주
                if step2Success {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("?   [Step 2] ???  ?좌표 복원 ? 공 - ? 체 복원 ? 공? 로 간주")
                }
            }
            
            TabPersistenceManager.debugMessages.append("?   [Step 2] ? 료: \(step2Success ? "? 공" : "? 패")")
            TabPersistenceManager.debugMessages.append("??[Step 2] ? 더 ??  ? \(self.restorationConfig.step2RenderDelay) ?)
            
            // ? 공/? 패 관계없??? 음 ? 계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step2RenderDelay) {
                self.executeStep3_AnchorRestore(context: updatedContext)
            }
        }
    }
    
    // MARK: - Step 3: 무한? 크 ?? 용 ? 커 복원
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("?   [Step 3] 무한? 크 ?? 용 ? 커 ?  ? 복원 ? 작")
        
        guard restorationConfig.enableAnchorRestore else {
            TabPersistenceManager.debugMessages.append("?   [Step 3] 비활? 화??- ? 킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step3RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
            return
        }
        
        // 무한? 크 ?? 커 ? 이??? 인
        var infiniteScrollAnchorDataJSON = "null"
        if let jsState = self.jsState,
           let infiniteScrollAnchorData = jsState["infiniteScrollAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(infiniteScrollAnchorData) {
            infiniteScrollAnchorDataJSON = dataJSON
        }
        
        let js = generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: infiniteScrollAnchorDataJSON)
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step3Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("?   [Step 3] JavaScript ? 류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step3Success = (resultDict["success"] as? Bool) ?? false
                
                if let anchorCount = resultDict["anchorCount"] as? Int {
                    TabPersistenceManager.debugMessages.append("?   [Step 3] ? 용 가? 한 ? 커: \(anchorCount) ?)
                }
                if let matchedAnchor = resultDict["matchedAnchor"] as? [String: Any] {
                    if let anchorType = matchedAnchor["anchorType"] as? String {
                        TabPersistenceManager.debugMessages.append("?   [Step 3] 매칭??? 커 ? ?? \(anchorType)")
                    }
                    if let method = matchedAnchor["matchMethod"] as? String {
                        TabPersistenceManager.debugMessages.append("?   [Step 3] 매칭 방법: \(method)")
                    }
                    if let confidence = matchedAnchor["confidence"] as? Double {
                        TabPersistenceManager.debugMessages.append("?   [Step 3] 매칭 ? 뢰?? \(String(format: "%.1f", confidence))%")
                    }
                }
                if let restoredPosition = resultDict["restoredPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("?   [Step 3] 복원??? 치: X=\(String(format: "%.1f", restoredPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", restoredPosition["y"] ?? 0))px")
                }
                if let targetDifference = resultDict["targetDifference"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("?   [Step 3] 목표? ??차이: X=\(String(format: "%.1f", targetDifference["x"] ?? 0))px, Y=\(String(format: "%.1f", targetDifference["y"] ?? 0))px")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(10) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("?   [Step 3] ? 료: \(step3Success ? "? 공" : "? 패") - ? 패? 도 계속 진행")
            TabPersistenceManager.debugMessages.append("??[Step 3] ? 더 ??  ? \(self.restorationConfig.step3RenderDelay) ?)
            
            // ? 공/? 패 관계없??? 음 ? 계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step3RenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
        }
    }
    
    // MARK: - Step 4: 최종 검 ? ?미세 보정
    private func executeStep4_FinalVerification(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("??[Step 4] 최종 검 ? ?미세 보정 ? 작")
        
        guard restorationConfig.enableFinalVerification else {
            TabPersistenceManager.debugMessages.append("??[Step 4] 비활? 화??- ? 킵")
            context.completion(context.overallSuccess)
            return
        }
        
        let js = generateStep4_FinalVerificationScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step4Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("??[Step 4] JavaScript ? 류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step4Success = (resultDict["success"] as? Bool) ?? false
                
                if let finalPosition = resultDict["finalPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("??[Step 4] 최종 ? 치: X=\(String(format: "%.1f", finalPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
                }
                if let targetPosition = resultDict["targetPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("??[Step 4] 목표 ? 치: X=\(String(format: "%.1f", targetPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", targetPosition["y"] ?? 0))px")
                }
                if let finalDifference = resultDict["finalDifference"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("??[Step 4] 최종 차이: X=\(String(format: "%.1f", finalDifference["x"] ?? 0))px, Y=\(String(format: "%.1f", finalDifference["y"] ?? 0))px")
                }
                if let withinTolerance = resultDict["withinTolerance"] as? Bool {
                    TabPersistenceManager.debugMessages.append("??[Step 4] ? 용 ? 차 ?? \(withinTolerance ? "?? : "? 니??)")
                }
                if let correctionApplied = resultDict["correctionApplied"] as? Bool, correctionApplied {
                    TabPersistenceManager.debugMessages.append("??[Step 4] 미세 보정 ? 용??)
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("??[Step 4] ? 료: \(step4Success ? "? 공" : "? 패")")
            TabPersistenceManager.debugMessages.append("??[Step 4] ? 더 ??  ? \(self.restorationConfig.step4RenderDelay) ?)
            
            // 최종 ?  ???? 료 콜백
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step4RenderDelay) {
                let finalSuccess = context.overallSuccess || step4Success
                TabPersistenceManager.debugMessages.append("?   ? 체 BFCache 복원 ? 료: \(finalSuccess ? "? 공" : "? 패")")
                context.completion(finalSuccess)
            }
        }
    }
    
    // MARK: - JavaScript ? 성 메서? 들
    

    private func generateStep1_ContentRestoreScript() -> String {
        let targetHeight = restorationConfig.savedContentHeight

        return """
        (function() {
            try {
                const logs = [];

                if (typeof Number.isFinite !== 'function') {
                    Number.isFinite = function(value) {
                        return typeof value === 'number' && isFinite(value);
                    };
                }

                function safeNumber(value, fallback) {
                    const num = Number(value);
                    if (Number.isFinite(num)) {
                        return num;
                    }
                    return fallback === undefined ? 0 : fallback;
                }

                const docElement = document.documentElement || {};
                const body = document.body || {};
                const targetHeight = safeNumber('\(targetHeight)', 0);
                const viewportHeight = safeNumber(window.innerHeight, 0);
                const viewportWidth = safeNumber(window.innerWidth, 0);
                const initialScrollTop = safeNumber(window.scrollY || window.pageYOffset || 0, 0);
                const initialScrollLeft = safeNumber(window.scrollX || window.pageXOffset || 0, 0);
                const currentHeight = Math.max(
                    safeNumber(docElement.scrollHeight, 0),
                    safeNumber(body.scrollHeight, 0)
                );

                logs.push('[Step 1] ??? ?? ?? ??');
                logs.push('?? ??: ' + currentHeight.toFixed(0) + 'px');
                logs.push('?? ??: ' + targetHeight.toFixed(0) + 'px');
                logs.push('???: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                logs.push('?? ???: X=' + initialScrollLeft.toFixed(1) + ', Y=' + initialScrollTop.toFixed(1));

                const loadMoreSelectors = [
                    '[data-testid*="load"]',
                    '[class*="load"]',
                    '[class*="more"]',
                    'button[class*="more"]',
                    '.load-more',
                    '.show-more'
                ];
                const loadMoreButtons = [];

                for (let i = 0; i < loadMoreSelectors.length; i++) {
                    try {
                        const nodes = document.querySelectorAll(loadMoreSelectors[i]);
                        for (let j = 0; j < nodes.length; j++) {
                            loadMoreButtons.push(nodes[j]);
                        }
                    } catch (e) {
                        // ignore selector failures
                    }
                }

                let clicked = 0;
                for (let i = 0; i < loadMoreButtons.length && clicked < 5; i++) {
                    const btn = loadMoreButtons[i];
                    if (!btn) { continue; }
                    try {
                        if (typeof btn.click === 'function') {
                            btn.click();
                        } else {
                            btn.dispatchEvent(new Event('click', { bubbles: true }));
                        }
                        clicked++;
                    } catch (e) {
                        // ignore individual click failures
                    }
                }
                if (clicked > 0) {
                    logs.push('?? ?? ?? ?? ?: ' + clicked);
                }

                const scrollTargets = [];
                function enqueuePosition(value) {
                    const position = Math.max(0, safeNumber(value, 0));
                    if (!scrollTargets.includes(position)) {
                        scrollTargets.push(position);
                    }
                }

                enqueuePosition(initialScrollTop);
                enqueuePosition(currentHeight - viewportHeight);
                enqueuePosition(currentHeight - Math.max(40, viewportHeight * 0.25));
                enqueuePosition(currentHeight - Math.max(80, viewportHeight * 0.5));
                enqueuePosition(currentHeight + Math.max(120, viewportHeight * 0.6));
                enqueuePosition(currentHeight + Math.max(240, viewportHeight));
                enqueuePosition(currentHeight);

                logs.push('??? ??? ??: ' + scrollTargets.length + '?');

                for (let i = 0; i < scrollTargets.length; i++) {
                    const y = scrollTargets[i];
                    window.scrollTo(0, y);
                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                    window.dispatchEvent(new Event('touchmove', { bubbles: true }));
                    if (typeof WheelEvent === 'function') {
                        try {
                            window.dispatchEvent(new WheelEvent('wheel', { deltaY: 120, bubbles: true }));
                        } catch (_) {
                            // ignore wheel construction issues
                        }
                    }
                }

                window.scrollTo(0, Math.max(0, currentHeight - Math.max(20, viewportHeight * 0.1)));
                window.dispatchEvent(new Event('scroll', { bubbles: true }));

                const restoredHeight = Math.max(
                    safeNumber(docElement.scrollHeight, 0),
                    safeNumber(body.scrollHeight, 0)
                );
                const deltaHeight = restoredHeight - currentHeight;
                const percentage = targetHeight > 0 ? (restoredHeight / targetHeight) * 100 : 100;
                const success = percentage >= 80 || (targetHeight === 0 && deltaHeight >= 0);
                const isStaticSite = percentage >= 90 || Math.abs(deltaHeight) <= 2;

                logs.push('?? ??: ' + deltaHeight.toFixed(0) + 'px');
                logs.push('??? ??: ' + restoredHeight.toFixed(0) + 'px');
                logs.push('???: ' + percentage.toFixed(1) + '%');

                return {
                    success: success,
                    isStaticSite: isStaticSite,
                    currentHeight: currentHeight,
                    targetHeight: targetHeight,
                    restoredHeight: restoredHeight,
                    percentage: percentage,
                    viewportHeight: viewportHeight,
                    logs: logs
                };

            } catch (e) {
                return {
                    success: false,
                    error: e.message,
                    logs: ['[Step 1] ??: ' + e.message]
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
                
                logs.push('[Step 2] ?  ?좌표 기반 ? 크 ?복원');
                logs.push('목표 백분?? X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                
                // ? 재 콘텐 ?? 기?  뷰포??? 기
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
                
                // 최 ? ? 크 ?가??거리
                const maxScrollY = Math.max(0, contentHeight - viewportHeight);
                const maxScrollX = Math.max(0, contentWidth - viewportWidth);
                
                logs.push('최 ? ? 크 ? X=' + maxScrollX.toFixed(0) + 'px, Y=' + maxScrollY.toFixed(0) + 'px');
                
                // 백분??기반 목표 ? 치 계산
                const targetX = (targetPercentX / 100) * maxScrollX;
                const targetY = (targetPercentY / 100) * maxScrollY;
                
                logs.push('계산??목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // ? 크 ?? 행
                window.scrollTo(targetX, targetY);
                document.documentElement.scrollTop = targetY;
                document.documentElement.scrollLeft = targetX;
                document.body.scrollTop = targetY;
                document.body.scrollLeft = targetX;
                
                if (document.scrollingElement) {
                    document.scrollingElement.scrollTop = targetY;
                    document.scrollingElement.scrollLeft = targetX;
                }
                
                // ? 제 ? 용??? 치 ? 인
                const actualX = window.scrollX || window.pageXOffset || 0;
                const actualY = window.scrollY || window.pageYOffset || 0;
                
                const diffX = Math.abs(actualX - targetX);
                const diffY = Math.abs(actualY - targetY);
                
                logs.push('? 제 ? 치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                logs.push('? 치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                // ? 용 ? 차 50px ? 내 ?? 공
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
                    logs: ['[Step 2] ? 류: ' + e.message]
                };
            }
        })()
        """
    }
    
    private func generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: String) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const infiniteScrollAnchorData = \(anchorDataJSON);
                
                logs.push('[Step 3] 무한? 크 ?? 용 ? 커 복원');
                logs.push('목표 ? 치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // ? 커 ? 이??? 인
                if (!infiniteScrollAnchorData || !infiniteScrollAnchorData.anchors || infiniteScrollAnchorData.anchors.length === 0) {
                    logs.push('무한? 크 ?? 커 ? 이??? 음 - ? 킵');
                    return {
                        success: false,
                        anchorCount: 0,
                        logs: logs
                    };
                }
                
                const anchors = infiniteScrollAnchorData.anchors;
                logs.push('? 용 가? 한 ? 커: ' + anchors.length + ' ?);
                
                // 무한? 크 ?? 커 ? ? 별 ? 터 ?
                const vueComponentAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'vueComponent' && anchor.vueComponent;
                });
                const contentHashAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'contentHash' && anchor.contentHash;
                });
                const virtualIndexAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'virtualIndex' && anchor.virtualIndex;
                });
                
                logs.push('Vue Component ? 커: ' + vueComponentAnchors.length + ' ?);
                logs.push('Content Hash ? 커: ' + contentHashAnchors.length + ' ?);
                logs.push('Virtual Index ? 커: ' + virtualIndexAnchors.length + ' ?);
                
                let foundElement = null;
                let matchedAnchor = null;
                let matchMethod = '';
                let confidence = 0;
                
                // ? 선? 위 1: Vue Component ? 커 매칭
                if (!foundElement && vueComponentAnchors.length > 0) {
                    for (let i = 0; i < vueComponentAnchors.length && !foundElement; i++) {
                        const anchor = vueComponentAnchors[i];
                        const vueComp = anchor.vueComponent;
                        
                        // data-v-* ? 성? 로 찾기
                        if (vueComp.dataV) {
                            const vueElements = document.querySelectorAll('[' + vueComp.dataV + ']');
                            for (let j = 0; j < vueElements.length; j++) {
                                const element = vueElements[j];
                                // 컴포? 트 ? 름 ?? 덱??매칭
                                if (vueComp.name && element.className.includes(vueComp.name)) {
                                    // 가??? 덱??기반 매칭
                                    if (vueComp.index !== undefined) {
                                        const elementIndex = Array.from(element.parentElement.children).indexOf(element);
                                        if (Math.abs(elementIndex - vueComp.index) <= 2) { // ? 용 ? 차 2
                                            foundElement = element;
                                            matchedAnchor = anchor;
                                            matchMethod = 'vue_component_with_index';
                                            confidence = 95;
                                            logs.push('Vue 컴포? 트 ?매칭: ' + vueComp.name + '[' + vueComp.index + ']');
                                            break;
                                        }
                                    } else {
                                        foundElement = element;
                                        matchedAnchor = anchor;
                                        matchMethod = 'vue_component';
                                        confidence = 85;
                                        logs.push('Vue 컴포? 트 ?매칭: ' + vueComp.name);
                                        break;
                                    }
                                }
                            }
                            if (foundElement) break;
                        }
                    }
                }
                
                // ? 선? 위 2: Content Hash ? 커 매칭
                if (!foundElement && contentHashAnchors.length > 0) {
                    for (let i = 0; i < contentHashAnchors.length && !foundElement; i++) {
                        const anchor = contentHashAnchors[i];
                        const contentHash = anchor.contentHash;
                        
                        // ? 스??? 용? 로 매칭
                        if (contentHash.text && contentHash.text.length > 20) {
                            const searchText = contentHash.text.substring(0, 50);
                            const allElements = document.querySelectorAll('*');
                            for (let j = 0; j < allElements.length; j++) {
                                const element = allElements[j];
                                const elementText = (element.textContent || '').trim();
                                if (elementText.includes(searchText)) {
                                    foundElement = element;
                                    matchedAnchor = anchor;
                                    matchMethod = 'content_hash';
                                    confidence = 80;
                                    logs.push('콘텐 ?? 시 ?매칭: "' + searchText + '"');
                                    break;
                                }
                            }
                            if (foundElement) break;
                        }
                        
                        // 짧 ? ? 시 ?매칭
                        if (!foundElement && contentHash.shortHash) {
                            const hashElements = document.querySelectorAll('[data-hash*="' + contentHash.shortHash + '"]');
                            if (hashElements.length > 0) {
                                foundElement = hashElements[0];
                                matchedAnchor = anchor;
                                matchMethod = 'short_hash';
                                confidence = 75;
                                logs.push('짧 ? ? 시 ?매칭: ' + contentHash.shortHash);
                                break;
                            }
                        }
                    }
                }
                
                // ? 선? 위 3: Virtual Index ? 커 매칭 (추정 ? 치)
                if (!foundElement && virtualIndexAnchors.length > 0) {
                    for (let i = 0; i < virtualIndexAnchors.length && !foundElement; i++) {
                        const anchor = virtualIndexAnchors[i];
                        const virtualIndex = anchor.virtualIndex;
                        
                        // 리스??? 덱??기반 추정
                        if (virtualIndex.listIndex !== undefined) {
                            const listElements = document.querySelectorAll('li, .item, .list-item, [class*="item"]');
                            const targetIndex = virtualIndex.listIndex;
                            if (targetIndex >= 0 && targetIndex < listElements.length) {
                                foundElement = listElements[targetIndex];
                                matchedAnchor = anchor;
                                matchMethod = 'virtual_index';
                                confidence = 60;
                                logs.push('가??? 덱? 로 매칭: [' + targetIndex + ']');
                                break;
                            }
                        }
                        
                        // ? 이지 ? 프??기반 추정
                        if (!foundElement && virtualIndex.offsetInPage !== undefined) {
                            const estimatedY = virtualIndex.offsetInPage;
                            const allElements = document.querySelectorAll('*');
                            let closestElement = null;
                            let minDistance = Infinity;
                            
                            for (let j = 0; j < allElements.length; j++) {
                                const element = allElements[j];
                                const rect = element.getBoundingClientRect();
                                const elementY = window.scrollY + rect.top;
                                const distance = Math.abs(elementY - estimatedY);
                                
                                if (distance < minDistance && rect.height > 20) {
                                    minDistance = distance;
                                    closestElement = element;
                                }
                            }
                            
                            if (closestElement && minDistance < 200) {
                                foundElement = closestElement;
                                matchedAnchor = anchor;
                                matchMethod = 'page_offset';
                                confidence = 50;
                                logs.push('? 이지 ? 프? 으 ?매칭: ' + estimatedY.toFixed(0) + 'px (? 차: ' + minDistance.toFixed(0) + 'px)');
                                break;
                            }
                        }
                    }
                }
                
                if (foundElement && matchedAnchor) {
                    // ? 소 ?? 크 ?
                    foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                    
                    // ? 프??보정
                    if (matchedAnchor.offsetFromTop) {
                        window.scrollBy(0, -matchedAnchor.offsetFromTop);
                    }
                    
                    const actualX = window.scrollX || window.pageXOffset || 0;
                    const actualY = window.scrollY || window.pageYOffset || 0;
                    const diffX = Math.abs(actualX - targetX);
                    const diffY = Math.abs(actualY - targetY);
                    
                    logs.push('? 커 복원 ??? 치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                    logs.push('목표? ??차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                    logs.push('매칭 ? 뢰?? ' + confidence + '%');
                    
                    return {
                        success: diffY <= 100, // 무한? 크롤 ? 100px ? 용 ? 차
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
                
                logs.push('무한? 크 ?? 커 매칭 ? 패');
                return {
                    success: false,
                    anchorCount: anchors.length,
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    logs: ['[Step 3] ? 류: ' + e.message]
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
                
                logs.push('[Step 4] 최종 검 ? ?미세 보정');
                logs.push('목표 ? 치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // ? 재 ? 치 ? 인
                let currentX = window.scrollX || window.pageXOffset || 0;
                let currentY = window.scrollY || window.pageYOffset || 0;
                
                let diffX = Math.abs(currentX - targetX);
                let diffY = Math.abs(currentY - targetY);
                
                logs.push('? 재 ? 치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                logs.push('? 치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                const withinTolerance = diffX <= tolerance && diffY <= tolerance;
                let correctionApplied = false;
                
                // ? 용 ? 차 초과 ??미세 보정
                if (!withinTolerance) {
                    logs.push('? 용 ? 차 초과 - 미세 보정 ? 용');
                    
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
                    
                    // 보정 ??? 치 ? 측??
                    currentX = window.scrollX || window.pageXOffset || 0;
                    currentY = window.scrollY || window.pageYOffset || 0;
                    diffX = Math.abs(currentX - targetX);
                    diffY = Math.abs(currentY - targetY);
                    
                    logs.push('보정 ??? 치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                    logs.push('보정 ??차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
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
                    logs: ['[Step 4] ? 류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // ? 전??JSON 변??? 틸리티
    private func convertToJSONString(_ object: Any) -> String? {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: object, options: [])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            TabPersistenceManager.debugMessages.append("JSON 변??? 패: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - BFCacheTransitionSystem 캐처/복원 ? 장
extension BFCacheTransitionSystem {
    
    // MARK: - ?   **? 심 개선: ? 자??캡처 ? 업 (?? 무한? 크 ?? 용 ? 커 캡처)**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            TabPersistenceManager.debugMessages.append("??캡처 ? 패: ? 뷰 ? 음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        // ?   캡처 ? ??? 이??로그
        TabPersistenceManager.debugMessages.append("?? 무한? 크 ?? 용 ? 커 캡처 ? ?? \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // ?   **직렬??? 로 모든 캡처 ? 업 ? 서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        guard let webView = task.webView else {
            TabPersistenceManager.debugMessages.append("??? 뷰 ? 제??- 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        TabPersistenceManager.debugMessages.append("?? 무한? 크 ?? 커 직렬 캡처 ? 작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 ? 레? 에??? 뷰 ? 태 ? 인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // ? 뷰가 준비되? 는지 ? 인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("? ️ ? 뷰 준 ?? 됨 - 캡처 ? 킵: \(task.pageRecord.title)")
                return nil
            }
            
            // ? 제 ? 크 ?가? 한 최 ? ? 기 감 ?
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
        
        // ?   **개선??캡처 로직 - ? 패 ??? 시??(기존 ? ? 밍 ?  ?)**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate??? 시??
        )
        
        // ?   **캡처??jsState ? 세 로깅**
        if let jsState = captureResult.snapshot.jsState {
            TabPersistenceManager.debugMessages.append("?   캡처??jsState ?? \(Array(jsState.keys))")
            
            if let infiniteScrollAnchors = jsState["infiniteScrollAnchors"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("?? 캡처??무한? 크 ?? 커 ? 이???? \(Array(infiniteScrollAnchors.keys))")
                
                if let anchors = infiniteScrollAnchors["anchors"] as? [[String: Any]] {
                    // ? 커 ? ? 별 카운??
                    let vueComponentCount = anchors.filter { ($0["anchorType"] as? String) == "vueComponent" }.count
                    let contentHashCount = anchors.filter { ($0["anchorType"] as? String) == "contentHash" }.count
                    let virtualIndexCount = anchors.filter { ($0["anchorType"] as? String) == "virtualIndex" }.count
                    let structuralPathCount = anchors.filter { ($0["anchorType"] as? String) == "structuralPath" }.count
                    let intersectionCount = anchors.filter { ($0["anchorType"] as? String) == "intersectionInfo" }.count
                    
                    TabPersistenceManager.debugMessages.append("?? 무한? 크 ?? 커 ? ? 별: Vue=\(vueComponentCount), Hash=\(contentHashCount), Index=\(virtualIndexCount), Path=\(structuralPathCount), Intersection=\(intersectionCount)")
                    
                    if anchors.count > 0 {
                        let firstAnchor = anchors[0]
                        TabPersistenceManager.debugMessages.append("??  ?번째 ? 커 ?? \(Array(firstAnchor.keys))")
                        
                        // ?   ** ?번째 ? 커 ? 세 ? 보 로깅**
                        if let anchorType = firstAnchor["anchorType"] as? String {
                            TabPersistenceManager.debugMessages.append("?    ?? 커 ? ?? \(anchorType)")
                            
                            switch anchorType {
                            case "vueComponent":
                                if let vueComp = firstAnchor["vueComponent"] as? [String: Any] {
                                    let name = vueComp["name"] as? String ?? "unknown"
                                    let dataV = vueComp["dataV"] as? String ?? "unknown"
                                    let index = vueComp["index"] as? Int ?? -1
                                    TabPersistenceManager.debugMessages.append("?   Vue 컴포? 트: name=\(name), dataV=\(dataV), index=\(index)")
                                }
                            case "contentHash":
                                if let contentHash = firstAnchor["contentHash"] as? [String: Any] {
                                    let shortHash = contentHash["shortHash"] as? String ?? "unknown"
                                    let textLength = (contentHash["text"] as? String)?.count ?? 0
                                    TabPersistenceManager.debugMessages.append("?   콘텐 ?? 시: hash=\(shortHash), textLen=\(textLength)")
                                }
                            case "virtualIndex":
                                if let virtualIndex = firstAnchor["virtualIndex"] as? [String: Any] {
                                    let listIndex = virtualIndex["listIndex"] as? Int ?? -1
                                    let pageIndex = virtualIndex["pageIndex"] as? Int ?? -1
                                    TabPersistenceManager.debugMessages.append("?   가??? 덱?? list=\(listIndex), page=\(pageIndex)")
                                }
                            default:
                                break
                            }
                        }
                        
                        if let absolutePos = firstAnchor["absolutePosition"] as? [String: Any] {
                            let top = (absolutePos["top"] as? Double) ?? 0
                            let left = (absolutePos["left"] as? Double) ?? 0
                            TabPersistenceManager.debugMessages.append("?    ?? 커 ? 치: X=\(String(format: "%.1f", left))px, Y=\(String(format: "%.1f", top))px")
                        }
                        if let qualityScore = firstAnchor["qualityScore"] as? Int {
                            TabPersistenceManager.debugMessages.append("?    ?? 커 ? 질? 수: \(qualityScore)??)
                        }
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("?? 무한? 크 ?? 커 ? 이??캡처 ? 패")
                }
                
                if let stats = infiniteScrollAnchors["stats"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("?   무한? 크 ?? 커 ? 집 ? 계: \(stats)")
                }
            } else {
                TabPersistenceManager.debugMessages.append("?? 무한? 크 ?? 커 ? 이??캡처 ? 패")
            }
        } else {
            TabPersistenceManager.debugMessages.append("?   jsState 캡처 ? 전 ? 패 - nil")
        }
        
        // 캡처 ? 료 ??? ??
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("??무한? 크 ?? 커 직렬 캡처 ? 료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize      // ??콘텐 ?? 기 추 ?
        let viewportSize: CGSize     // ??뷰포??? 기 추 ?
        let actualScrollableSize: CGSize  // ? ️ ? 제 ? 크 ?가??? 기 추 ?
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // ?   **? 패 복구 기능 추 ???캡처 - 기존 ? 시??? 기시 ??  ?**
    private func performRobustCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // ? 공? 거??마 ? ?? 도 ?결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    TabPersistenceManager.debugMessages.append("?   ? 시????캐처 ? 공: \(pageRecord.title) (? 도: \(attempt + 1))")
                }
                return result
            }
            
            // ? 시????? 시 ?  ?- ?   기존 80ms ?  ?
            TabPersistenceManager.debugMessages.append("??캡처 ? 패 - ? 시??(\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08) // ?   기존 80ms ?  ?
        }
        
        // ? 기까 ? ? 면 모든 ? 도 ? 패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        TabPersistenceManager.debugMessages.append("?   ? 냅??캡처 ? 도: \(pageRecord.title)")
        
        // 1. 비주??? 냅??(메인 ? 레?? - ?   기존 캡처 ? ? 아???  ? (3 ?
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("?   ? 냅??? 패, fallback ? 용: \(error.localizedDescription)")
                    // Fallback: layer ? 더 ?
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                    TabPersistenceManager.debugMessages.append("?   ? 냅??? 공")
                }
                semaphore.signal()
            }
        }
        
        // ??캡처 ? ? 아???  ? (3 ?
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            TabPersistenceManager.debugMessages.append("??? 냅??캡처 ? ? 아?? \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처 - ?   기존 캡처 ? ? 아???  ? (1 ?
        let domSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("?   DOM 캡처 ? 작")
        
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // ?   **? 린 ? 태/? 성 ? 태 모두 ? 거**
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(function(el) {
                        var classList = Array.from(el.classList);
                        var classesToRemove = classList.filter(function(c) {
                            return c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus');
                        });
                        for (var i = 0; i < classesToRemove.length; i++) {
                            el.classList.remove(classesToRemove[i]);
                        }
                    });
                    
                    // input focus ? 거
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
                    TabPersistenceManager.debugMessages.append("?   DOM 캡처 ? 패: \(error.localizedDescription)")
                } else if let dom = result as? String {
                    domSnapshot = dom
                    TabPersistenceManager.debugMessages.append("?   DOM 캡처 ? 공: \(dom.count)문자")
                }
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 2.0) // ?   기존 캡처 ? ? 아???  ? (1 ?
        
        // 3. ??**? 정: 무한? 크 ?? 용 ? 커 JS ? 태 캡처** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("?? 무한? 크 ?? 용 ? 커 JS ? 태 캡처 ? 작")
        
        DispatchQueue.main.sync {
            let jsScript = generateInfiniteScrollAnchorCaptureScript() // ?? **? 정?? 무한? 크 ?? 용 ? 커 캡처**
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("?   JS ? 태 캡처 ? 류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("??JS ? 태 캡처 ? 공: \(Array(data.keys))")
                    
                    // ?   **? 세 캡처 결과 로깅**
                    if let infiniteScrollAnchors = data["infiniteScrollAnchors"] as? [String: Any] {
                        if let anchors = infiniteScrollAnchors["anchors"] as? [[String: Any]] {
                            let vueComponentAnchors = anchors.filter { ($0["anchorType"] as? String) == "vueComponent" }
                            let contentHashAnchors = anchors.filter { ($0["anchorType"] as? String) == "contentHash" }
                            let virtualIndexAnchors = anchors.filter { ($0["anchorType"] as? String) == "virtualIndex" }
                            TabPersistenceManager.debugMessages.append("?? JS 캡처??? 커:  ?\(anchors.count) ?(Vue=\(vueComponentAnchors.count), Hash=\(contentHashAnchors.count), Index=\(virtualIndexAnchors.count))")
                        }
                        if let stats = infiniteScrollAnchors["stats"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("?   무한? 크 ?JS 캡처 ? 계: \(stats)")
                        }
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("?   JS ? 태 캡처 결과 ? ??? 류: \(type(of: result))")
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 2.0) // ?   기존 캡처 ? ? 아???  ? (2 ?
        
        // 캡처 ? 태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .complete
            TabPersistenceManager.debugMessages.append("??? 전 캡처 ? 공")
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
            TabPersistenceManager.debugMessages.append("??부 ?캡처 ? 공: visual=\(visualSnapshot != nil), dom=\(domSnapshot != nil), js=\(jsState != nil)")
        } else {
            captureStatus = .failed
            TabPersistenceManager.debugMessages.append("??캡처 ? 패")
        }
        
        // 버전 증 ? (? 레??? 전)
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        // ?   **? 정: 백분??계산 로직 ? 정 - OR 조건? 로 변 ?*
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
        
        TabPersistenceManager.debugMessages.append("?   캡처 ? 료: ? 치=(\(String(format: "%.1f", captureData.scrollPosition.x)), \(String(format: "%.1f", captureData.scrollPosition.y))), 백분??(\(String(format: "%.2f", scrollPercent.x))%, \(String(format: "%.2f", scrollPercent.y))%)")
        TabPersistenceManager.debugMessages.append("?   ? 크 ?계산 ? 보: actualScrollableHeight=\(captureData.actualScrollableSize.height), viewportHeight=\(captureData.viewportSize.height), maxScrollY=\(max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height))")
        
        // ?   **? 차 ? 행 ? 정 ? 성**
        let restorationConfig = BFCacheSnapshot.RestorationConfig(
            enableContentRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height),
            step1RenderDelay: 0.1,
            step2RenderDelay: 0.2,
            step3RenderDelay: 0.1,
            step4RenderDelay: 0.2
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
            webViewSnapshotPath: nil,  // ? 중??? 스??? ? 시 ? 정
            captureStatus: captureStatus,
            version: version,
            restorationConfig: restorationConfig
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // ?? **? 정: JavaScript ? 커 캡처 ? 크립트 개선**
    private func generateInfiniteScrollAnchorCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('?? 무한? 크 ?? 용 ? 커 캡처 ? 작');
                
                // ?   **? 세 로그 ? 집**
                const detailedLogs = [];
                const pageAnalysis = {};
                
                // 기본 ? 보 ? 집
                const scrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                const scrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                
                detailedLogs.push('?? 무한? 크 ?? 용 ? 커 캡처 ? 작');
                detailedLogs.push('? 크 ?? 치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포??? 기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐 ?? 기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                console.log('?? 기본 ? 보:', {
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                // ?? **? 제 보이??? 역 계산**
                const actualViewportRect = {
                    top: scrollY,
                    left: scrollX,
                    bottom: scrollY + viewportHeight,
                    right: scrollX + viewportWidth,
                    width: viewportWidth,
                    height: viewportHeight
                };
                
                detailedLogs.push('? 제 보이??? 역: top=' + actualViewportRect.top.toFixed(1) + ', bottom=' + actualViewportRect.bottom.toFixed(1));
                
                // ?? **? 소 가? 성 ? 확 ? 단 ? 수**
                function isElementActuallyVisible(element, strictMode) {
                    if (strictMode === undefined) strictMode = true;
                    
                    try {
                        if (!element || !element.getBoundingClientRect) return { visible: false, reason: 'invalid_element' };
                        if (!document.contains(element)) return { visible: false, reason: 'not_in_dom' };
                        
                        const rect = element.getBoundingClientRect();
                        if (rect.width === 0 || rect.height === 0) return { visible: false, reason: 'zero_size' };
                        
                        const elementTop = scrollY + rect.top;
                        const elementBottom = scrollY + rect.bottom;
                        const elementLeft = scrollX + rect.left;
                        const elementRight = scrollX + rect.right;
                        
                        const isInViewportVertically = elementBottom > actualViewportRect.top && elementTop < actualViewportRect.bottom;
                        const isInViewportHorizontally = elementRight > actualViewportRect.left && elementLeft < actualViewportRect.right;
                        
                        if (strictMode && (!isInViewportVertically || !isInViewportHorizontally)) {
                            return { visible: false, reason: 'outside_viewport', rect: rect };
                        }
                        
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
                
                // ?   **?  ?? 는 ? 스??? 터 ?? 수**
                function isQualityText(text) {
                    if (!text || typeof text !== 'string') return false;
                    
                    const cleanText = text.trim();
                    if (cleanText.length < 10) return false; // 무한? 크롤용 최소 길이 증 ?
                    
                    const meaninglessPatterns = [
                        /^(? 표??? 시?  ?|? 습? 다|? 트? 크|문제 ?? 결?  ?|? 시|? 에|? 시|? 도)/,
                        /^(로딩|loading|wait|please|기다??? 시 ?/i,
                        /^(? 류|? 러|error|fail|? 패|죄송|sorry)/i,
                        /^(? 인|ok|yes|no|취소|cancel|? 기|close)/i,
                        /^(? 보 ?more|load|next|? 전|prev|previous)/i,
                        /^(? 릭|click|tap|? 치|touch|? 택)/i,
                        /^(?  ?|?  ?|reply|comment|? 기|? 성)/i,
                        /^[\\s\\.\\-_=+]{2,}$/,
                        /^[0-9\\s\\.\\/\\-:]{3,}$/,
                        /^(am|pm|? 전|? 후|?? ? ?$/i,
                    ];
                    
                    for (let i = 0; i < meaninglessPatterns.length; i++) {
                        if (meaninglessPatterns[i].test(cleanText)) {
                            return false;
                        }
                    }
                    
                    return true;
                }
                
                // ?? **SHA256 간단 ? 시 ? 수 (콘텐 ?? 시??**
                function simpleHash(str) {
                    let hash = 0;
                    if (str.length === 0) return hash.toString(36);
                    for (let i = 0; i < str.length; i++) {
                        const char = str.charCodeAt(i);
                        hash = ((hash << 5) - hash) + char;
                        hash = hash & hash; // 32비트 ? 수 ?변??
                    }
                    return Math.abs(hash).toString(36);
                }
                
                // ?? **? 정?? data-v-* ? 성 찾기 ? 수**
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
                
                // ?? **? 정?? Vue 컴포? 트 ? 소 ? 집**
                function collectVueComponentElements() {
                    const vueElements = [];
                    
                    // 1. 모든 ? 소 ?? 회? 면??data-v-* ? 성??가 ?? 소 찾기
                    const allElements = document.querySelectorAll('*');
                    
                    for (let i = 0; i < allElements.length; i++) {
                        const element = allElements[i];
                        const dataVAttr = findDataVAttribute(element);
                        
                        if (dataVAttr) {
                            const visibilityResult = isElementActuallyVisible(element, true);
                            
                            if (visibilityResult.visible) {
                                const elementText = (element.textContent || '').trim();
                                if (isQualityText(elementText)) {
                                    vueElements.push({
                                        element: element,
                                        dataVAttr: dataVAttr,
                                        rect: visibilityResult.rect,
                                        textContent: elementText,
                                        visibilityResult: visibilityResult
                                    });
                                }
                            }
                        }
                    }
                    
                    detailedLogs.push('Vue.js 컴포? 트 ? 집: ' + vueElements.length + ' ?);
                    return vueElements;
                }
                
                // ?? **? 심: 무한? 크 ?? 용 ? 커 ? 집**
                function collectInfiniteScrollAnchors() {
                    const anchors = [];
                    const anchorStats = {
                        totalCandidates: 0,
                        visibilityChecked: 0,
                        actuallyVisible: 0,
                        vueComponentAnchors: 0,
                        contentHashAnchors: 0,
                        virtualIndexAnchors: 0,
                        structuralPathAnchors: 0,
                        intersectionAnchors: 0,
                        finalAnchors: 0
                    };
                    
                    detailedLogs.push('?? 무한? 크 ?? 용 ? 커 ? 집 ? 작');
                    
                    // ?? **1. Vue.js 컴포? 트 ? 소 ? 선 ? 집**
                    const vueComponentElements = collectVueComponentElements();
                    anchorStats.totalCandidates += vueComponentElements.length;
                    anchorStats.actuallyVisible += vueComponentElements.length;
                    
                    // ?? **2. ? 반 콘텐 ?? 소 ? 집 (무한? 크롤용) - ? 정??? 택??*
                    const contentSelectors = [
                        'li', 'tr', 'td', '.item', '.list-item', '.card', '.post', '.article',
                        '.comment', '.reply', '.feed', '.thread', '.message', '.product', 
                        '.news', '.media', '.content-item', '[class*="item"]', 
                        '[class*="post"]', '[class*="card"]', '[data-testid]', 
                        '[data-id]', '[data-key]', '[data-item-id]',
                        // ? 이 ?카페 ? 화 ? 택??추 ?
                        '.ListItem', '.ArticleListItem', '.MultiLinkWrap', 
                        '[class*="List"]', '[class*="Item"]', '[data-v-]'
                    ];
                    
                    let contentElements = [];
                    for (let i = 0; i < contentSelectors.length; i++) {
                        try {
                            const elements = document.querySelectorAll(contentSelectors[i]);
                            for (let j = 0; j < elements.length; j++) {
                                contentElements.push(elements[j]);
                            }
                        } catch(e) {
                            // selector ? 류 무시
                        }
                    }
                    
                    anchorStats.totalCandidates += contentElements.length;
                    
                    // 중복 ? 거  ?가? 성 ? 터 ?
                    const uniqueContentElements = [];
                    const processedElements = new Set();
                    
                    for (let i = 0; i < contentElements.length; i++) {
                        const element = contentElements[i];
                        if (!processedElements.has(element)) {
                            processedElements.add(element);
                            
                            const visibilityResult = isElementActuallyVisible(element, false); // ?   ??? 격??가? 성 검??
                            anchorStats.visibilityChecked++;
                            
                            if (visibilityResult.visible) {
                                const elementText = (element.textContent || '').trim();
                                if (elementText.length > 5) { // ?   ? 스??길이 조건 ? 화
                                    uniqueContentElements.push({
                                        element: element,
                                        rect: visibilityResult.rect,
                                        textContent: elementText,
                                        visibilityResult: visibilityResult
                                    });
                                    anchorStats.actuallyVisible++;
                                }
                            }
                        }
                    }
                    
                    detailedLogs.push('? 반 콘텐 ?? 보: ' + contentElements.length + ' ? ? 효: ' + uniqueContentElements.length + ' ?);
                    
                    // ?? **3. 뷰포??중심 기 ?? 로 ? 위 20개씩 ? 택 (증 ?)**
                    const viewportCenterY = scrollY + (viewportHeight / 2);
                    const viewportCenterX = scrollX + (viewportWidth / 2);
                    
                    // Vue 컴포? 트 ? 렬  ?? 택
                    vueComponentElements.sort(function(a, b) {
                        const aTop = scrollY + a.rect.top;
                        const bTop = scrollY + b.rect.top;
                        const aDistance = Math.abs(aTop + (a.rect.height / 2) - viewportCenterY);
                        const bDistance = Math.abs(bTop + (b.rect.height / 2) - viewportCenterY);
                        return aDistance - bDistance;
                    });
                    
                    // ? 반 콘텐 ?? 렬  ?? 택
                    uniqueContentElements.sort(function(a, b) {
                        const aTop = scrollY + a.rect.top;
                        const bTop = scrollY + b.rect.top;
                        const aDistance = Math.abs(aTop + (a.rect.height / 2) - viewportCenterY);
                        const bDistance = Math.abs(bTop + (b.rect.height / 2) - viewportCenterY);
                        return aDistance - bDistance;
                    });
                    
                    const selectedVueElements = vueComponentElements.slice(0, 20); // ?   20개로 증 ?
                    const selectedContentElements = uniqueContentElements.slice(0, 20); // ?   20개로 증 ?
                    
                    detailedLogs.push('뷰포??중심 기 ? ? 택: Vue=' + selectedVueElements.length + ' ? Content=' + selectedContentElements.length + ' ?);
                    
                    // ?? **4. Vue Component ? 커 ? 성**
                    for (let i = 0; i < selectedVueElements.length; i++) {
                        try {
                            const anchor = createVueComponentAnchor(selectedVueElements[i], i);
                            if (anchor) {
                                anchors.push(anchor);
                                anchorStats.vueComponentAnchors++;
                            }
                        } catch(e) {
                            console.warn('Vue ? 커[' + i + '] ? 성 ? 패:', e);
                        }
                    }
                    
                    // ?? **5. Content Hash + Virtual Index + Structural Path ? 커 ? 성**
                    for (let i = 0; i < selectedContentElements.length; i++) {
                        try {
                            // Content Hash ? 커
                            const hashAnchor = createContentHashAnchor(selectedContentElements[i], i);
                            if (hashAnchor) {
                                anchors.push(hashAnchor);
                                anchorStats.contentHashAnchors++;
                            }
                            
                            // Virtual Index ? 커
                            const indexAnchor = createVirtualIndexAnchor(selectedContentElements[i], i);
                            if (indexAnchor) {
                                anchors.push(indexAnchor);
                                anchorStats.virtualIndexAnchors++;
                            }
                            
                            // Structural Path ? 커 (보조) - ? 위 10개만
                            if (i < 10) {
                                const pathAnchor = createStructuralPathAnchor(selectedContentElements[i], i);
                                if (pathAnchor) {
                                    anchors.push(pathAnchor);
                                    anchorStats.structuralPathAnchors++;
                                }
                            }
                            
                        } catch(e) {
                            console.warn('콘텐 ?? 커[' + i + '] ? 성 ? 패:', e);
                        }
                    }
                    
                    anchorStats.finalAnchors = anchors.length;
                    
                    detailedLogs.push('무한? 크 ?? 커 ? 성 ? 료: ' + anchors.length + ' ?);
                    console.log('?? 무한? 크 ?? 커 ? 집 ? 료:', anchors.length, ' ?);
                    
                    // ?   **? 정: stats ?별도 객체 ?반환**
                    return {
                        anchors: anchors,
                        stats: anchorStats
                    };
                }
                
                // ?? **? 정?? Vue Component ? 커 ? 성**
                function createVueComponentAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        const dataVAttr = elementData.dataVAttr;
                        
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // Vue 컴포? 트 ? 보 추출
                        const vueComponent = {
                            name: 'unknown',
                            dataV: dataVAttr,
                            props: {},
                            index: index
                        };
                        
                        // ? 래? 명? 서 컴포? 트 ? 름 추출 - ? 이 ?카페 ? 화
                        const classList = Array.from(element.classList);
                        for (let i = 0; i < classList.length; i++) {
                            const className = classList[i];
                            if (className.includes('Article') || className.includes('List') || 
                                className.includes('Item') || className.includes('Comment') ||
                                className.includes('Card') || className.includes('Post') ||
                                className.includes('Multi') || className.includes('Link')) {
                                vueComponent.name = className;
                                break;
                            }
                        }
                        
                        // 부 ?? 소? 서 ? 덱??? 보
                        if (element.parentElement) {
                            const siblingIndex = Array.from(element.parentElement.children).indexOf(element);
                            vueComponent.index = siblingIndex;
                        }
                        
                        const qualityScore = 85; // Vue 컴포? 트??기본 85??
                        
                        return {
                            anchorType: 'vueComponent',
                            vueComponent: vueComponent,
                            
                            // ? 치 ? 보
                            absolutePosition: { top: absoluteTop, left: absoluteLeft },
                            viewportPosition: { top: rect.top, left: rect.left },
                            offsetFromTop: offsetFromTop,
                            size: { width: rect.width, height: rect.height },
                            
                            // 메 ? ? 보
                            textContent: textContent.substring(0, 100),
                            qualityScore: qualityScore,
                            anchorIndex: index,
                            captureTimestamp: Date.now(),
                            isVisible: true,
                            visibilityReason: 'vue_component_visible'
                        };
                        
                    } catch(e) {
                        console.error('Vue ? 커[' + index + '] ? 성 ? 패:', e);
                        return null;
                    }
                }
                
                // ?? **Content Hash ? 커 ? 성**
                function createContentHashAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // 콘텐 ?? 시 ? 성
                        const fullHash = simpleHash(textContent);
                        const shortHash = fullHash.substring(0, 8);
                        
                        const contentHash = {
                            fullHash: fullHash,
                            shortHash: shortHash,
                            text: textContent.substring(0, 100),
                            length: textContent.length
                        };
                        
                        const qualityScore = Math.min(95, 60 + Math.min(35, Math.floor(textContent.length / 10)));
                        
                        return {
                            anchorType: 'contentHash',
                            contentHash: contentHash,
                            
                            absolutePosition: { top: absoluteTop, left: absoluteLeft },
                            viewportPosition: { top: rect.top, left: rect.left },
                            offsetFromTop: offsetFromTop,
                            size: { width: rect.width, height: rect.height },
                            
                            textContent: textContent.substring(0, 100),
                            qualityScore: qualityScore,
                            anchorIndex: index,
                            captureTimestamp: Date.now(),
                            isVisible: true,
                            visibilityReason: 'content_hash_visible'
                        };
                        
                    } catch(e) {
                        console.error('Content Hash ? 커[' + index + '] ? 성 ? 패:', e);
                        return null;
                    }
                }
                
                // ?? **Virtual Index ? 커 ? 성**
                function createVirtualIndexAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // 가??? 덱??? 보
                        const virtualIndex = {
                            listIndex: index,
                            pageIndex: Math.floor(index / 10), // 10개씩 ? 이지 ? 위
                            offsetInPage: absoluteTop,
                            estimatedTotal: document.querySelectorAll('li, .item, .list-item, .ListItem').length
                        };
                        
                        const qualityScore = 70; // Virtual Index??70??
                        
                        return {
                            anchorType: 'virtualIndex',
                            virtualIndex: virtualIndex,
                            
                            absolutePosition: { top: absoluteTop, left: absoluteLeft },
                            viewportPosition: { top: rect.top, left: rect.left },
                            offsetFromTop: offsetFromTop,
                            size: { width: rect.width, height: rect.height },
                            
                            textContent: textContent.substring(0, 100),
                            qualityScore: qualityScore,
                            anchorIndex: index,
                            captureTimestamp: Date.now(),
                            isVisible: true,
                            visibilityReason: 'virtual_index_visible'
                        };
                        
                    } catch(e) {
                        console.error('Virtual Index ? 커[' + index + '] ? 성 ? 패:', e);
                        return null;
                    }
                }
                
                // ?? **Structural Path ? 커 ? 성 (보조)**
                function createStructuralPathAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // CSS 경로 ? 성
                        let cssPath = '';
                        let currentElement = element;
                        let depth = 0;
                        
                        while (currentElement && currentElement !== document.body && depth < 5) {
                            let selector = currentElement.tagName.toLowerCase();
                            
                            if (currentElement.id) {
                                selector += '#' + currentElement.id;
                                cssPath = selector + (cssPath ? ' > ' + cssPath : '');
                                break;
                            } else if (currentElement.className) {
                                const classNames = currentElement.className.trim().split(/\\s+/);
                                if (classNames.length > 0) {
                                    selector += '.' + classNames[0];
                                }
                            }
                            
                            // nth-child 추 ?
                            const siblings = Array.from(currentElement.parentElement ? currentElement.parentElement.children : []);
                            const sameTagSiblings = siblings.filter(function(sibling) {
                                return sibling.tagName === currentElement.tagName;
                            });
                            
                            if (sameTagSiblings.length > 1) {
                                const nthIndex = sameTagSiblings.indexOf(currentElement) + 1;
                                selector += ':nth-child(' + nthIndex + ')';
                            }
                            
                            cssPath = selector + (cssPath ? ' > ' + cssPath : '');
                            currentElement = currentElement.parentElement;
                            depth++;
                        }
                        
                        const structuralPath = {
                            cssPath: cssPath,
                            depth: depth
                        };
                        
                        const qualityScore = 50; // Structural Path??50??(보조??
                        
                        return {
                            anchorType: 'structuralPath',
                            structuralPath: structuralPath,
                            
                            absolutePosition: { top: absoluteTop, left: absoluteLeft },
                            viewportPosition: { top: rect.top, left: rect.left },
                            offsetFromTop: offsetFromTop,
                            size: { width: rect.width, height: rect.height },
                            
                            textContent: textContent.substring(0, 100),
                            qualityScore: qualityScore,
                            anchorIndex: index,
                            captureTimestamp: Date.now(),
                            isVisible: true,
                            visibilityReason: 'structural_path_visible'
                        };
                        
                    } catch(e) {
                        console.error('Structural Path ? 커[' + index + '] ? 성 ? 패:', e);
                        return null;
                    }
                }
                
                // ?? **메인 ? 행 - 무한? 크 ?? 용 ? 커 ? 이??? 집**
                const startTime = Date.now();
                const infiniteScrollAnchorsData = collectInfiniteScrollAnchors();
                const endTime = Date.now();
                const captureTime = endTime - startTime;
                
                pageAnalysis.capturePerformance = {
                    totalTime: captureTime,
                    anchorsPerSecond: infiniteScrollAnchorsData.anchors.length > 0 ? (infiniteScrollAnchorsData.anchors.length / (captureTime / 1000)).toFixed(2) : 0
                };
                
                detailedLogs.push('=== 무한? 크 ?? 용 ? 커 캡처 ? 료 (' + captureTime + 'ms) ===');
                detailedLogs.push('최종 무한? 크 ?? 커: ' + infiniteScrollAnchorsData.anchors.length + ' ?);
                detailedLogs.push('처리 ? 능: ' + pageAnalysis.capturePerformance.anchorsPerSecond + ' ? 커/ ?);
                
                console.log('?? 무한? 크 ?? 용 ? 커 캡처 ? 료:', {
                    infiniteScrollAnchorsCount: infiniteScrollAnchorsData.anchors.length,
                    stats: infiniteScrollAnchorsData.stats,
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight],
                    captureTime: captureTime,
                    actualViewportRect: actualViewportRect
                });
                
                // ??**? 정: ? 리??반환 구조**
                return {
                    infiniteScrollAnchors: infiniteScrollAnchorsData, // ?? **무한? 크 ?? 용 ? 커 ? 이??*
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
                    actualViewportRect: actualViewportRect,     // ?? **? 제 보이??? 역 ? 보**
                    detailedLogs: detailedLogs,                 // ?   **? 세 로그 배열**
                    captureStats: infiniteScrollAnchorsData.stats,  // ?   **? 정: stats 직접 ? 당**
                    pageAnalysis: pageAnalysis,                 // ?   **? 이지 분석 결과**
                    captureTime: captureTime                    // ?   **캡처 ? 요 ? 간**
                };
            } catch(e) { 
                console.error('?? 무한? 크 ?? 용 ? 커 캡처 ? 패:', e);
                return {
                    infiniteScrollAnchors: { anchors: [], stats: {} },
                    scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message,
                    detailedLogs: ['무한? 크 ?? 용 ? 커 캡처 ? 패: ' + e.message],
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
    
    // MARK: - ?   JavaScript ? 크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('?   브라?  ? 차단 ? ??BFCache ? 이지 복원');
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('?   브라?  ? 차단 ? ??BFCache ? 이지 ? ??);
            }
        });
        
        // ??**Cross-origin iframe 리스? 는 ?  ?? 되 복원? 서??? 용?  ? ? 음**
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                console.log('?   ?Cross-origin iframe ? 크 ?복원 ? 청 ? 신 (? 재 ? 용 ????');
                // ? 재??iframe 복원??? 용?  ? ? 으므 ?로그 ??  ?
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

