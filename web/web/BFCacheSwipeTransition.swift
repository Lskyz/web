//  BFCacheSnapshotManager.swift
//  📸 **순차적 4단계 BFCache 복원 시스템**
//  🎯 **Step 1**: 저장 콘텐츠 높이 복원 (동적 사이트만)
//  📏 **Step 2**: 상대좌표 기반 스크롤 복원 (최우선)
//  🔍 **Step 3**: 무한스크롤 전용 앵커 정밀 복원
//  ✅ **Step 4**: 최종 검증 및 미세 보정
//  ⏰ **렌더링 대기**: 각 단계별 필수 대기시간 적용
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용
//  🎯 **단일 스크롤러 최적화**: 검출된 단일 스크롤러만 조작

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
        let step1RenderDelay: Double        // Step 1 후 렌더링 대기
        let step2RenderDelay: Double        // Step 2 후 렌더링 대기
        let step3RenderDelay: Double        // Step 3 후 렌더링 대기
        let step4RenderDelay: Double        // Step 4 후 렌더링 대기
        
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
    init(
        pageRecord: PageRecord, 
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
        restorationConfig: RestorationConfig = RestorationConfig.default
    ) {
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
    
    // MARK: - 🎯 **핵심: 순차적 4단계 복원 시스템**
    
    // 복원 컨텍스트 구조체
    private struct RestorationContext {
        let snapshot: BFCacheSnapshot
        weak var webView: WKWebView?
        let completion: (Bool) -> Void
        var overallSuccess: Bool = false
    }
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 순차적 4단계 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 저장 콘텐츠 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")
        TabPersistenceManager.debugMessages.append("⏰ 렌더링 대기시간: Step1=\(restorationConfig.step1RenderDelay)s, Step2=\(restorationConfig.step2RenderDelay)s, Step3=\(restorationConfig.step3RenderDelay)s, Step4=\(restorationConfig.step4RenderDelay)s")
        
        // 복원 컨텍스트 생성
        let context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: completion
        )
        
        // Step 1 시작
        executeStep1_RestoreContentHeight(context: context)
    }
    
    fileprivate static func runRestorationScript(
        _ script: String,
        in webView: WKWebView?,
        completion: @escaping (Any?, Error?) -> Void
    ) {
        guard let webView else {
            let error = NSError(
                domain: "BFCacheSnapshot",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "Missing webView for BFCache restoration script."]
            )
            completion(nil, error)
            return
        }

        if #available(iOS 16.4, *) {
            webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    completion(value, nil)
                case .failure(let error):
                    completion(nil, error)
                }
            }
        } else {
            let error = NSError(
                domain: "BFCacheSnapshot",
                code: -1002,
                userInfo: [NSLocalizedDescriptionKey: "BFCache restoration requires iOS 16.4 or later to run async scripts."]
            )
            completion(nil, error)
        }
    }

    // MARK: - Step 1: 저장 콘텐츠 높이 복원
    private func executeStep1_RestoreContentHeight(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📦 [Step 1] 저장 콘텐츠 높이 복원 시작")
        
        guard restorationConfig.enableContentRestore else {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 비활성화됨 - 스킵")
            // 렌더링 대기 후 다음 단계
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step1RenderDelay) {
                self.executeStep2_PercentScroll(context: context)
            }
            return
        }
        
        let js = generateStep1_ContentRestoreScript()
        
        Self.runRestorationScript(js, in: context.webView) { result, error in
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
        
        Self.runRestorationScript(js, in: context.webView) { result, error in
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
                
                // 상대좌표 복원 성공 시 전체 성공으로 간주
                if step2Success {
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
    
    // MARK: - Step 3: 무한스크롤 전용 앵커 복원
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 무한스크롤 전용 앵커 정밀 복원 시작")
        
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
        
        let js = generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: infiniteScrollAnchorDataJSON)
        
        Self.runRestorationScript(js, in: context.webView) { result, error in
            var step3Success = false
            
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
        
        Self.runRestorationScript(js, in: context.webView) { result, error in
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
    
    // MARK: - 🎯 단일 스크롤러 JavaScript 생성 메서드들
    
    // 🎯 **공통 유틸리티 스크립트 생성**
    private func generateCommonUtilityScript() -> String {
        return """
        const BFCacheAsyncUtil = window.__BFCacheAsyncUtil || (() => {
            function getROOT() {
                return document.scrollingElement || document.documentElement;
            }

            function getMaxScroll() {
                const root = getROOT();
                return {
                    x: Math.max(0, root.scrollWidth - window.innerWidth),
                    y: Math.max(0, root.scrollHeight - window.innerHeight)
                };
            }

            function clampScrollPosition(x = 0, y = 0) {
                const max = getMaxScroll();
                return {
                    x: Math.max(0, Math.min(max.x, x)),
                    y: Math.max(0, Math.min(max.y, y))
                };
            }

            function fixedHeaderHeight() {
                const candidates = document.querySelectorAll('header, [class*="header"], [class*="gnb"], [class*="navbar"], [class*="nav-bar"]');
                let height = 0;
                candidates.forEach(element => {
                    const style = getComputedStyle(element);
                    if (style.position === 'fixed' || style.position === 'sticky') {
                        height = Math.max(height, element.getBoundingClientRect().height);
                    }
                });
                return height;
            }

            const sleep = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms));
            const nextFrame = () => new Promise(resolve => requestAnimationFrame(() => resolve()));

            async function waitFrames(count = 1) {
                for (let i = 0; i < count; i++) {
                    await nextFrame();
                }
            }

            async function waitForStableLayout(options = {}) {
                const { frames = 6, timeout = 1500, threshold = 2 } = options;
                const root = getROOT();
                let last = root.scrollHeight;
                let stable = 0;
                const start = performance.now();

                while (performance.now() - start < timeout) {
                    await waitFrames(1);
                    const current = root.scrollHeight;
                    if (Math.abs(current - last) <= threshold) {
                        stable += 1;
                        if (stable >= frames) {
                            return true;
                        }
                    } else {
                        stable = 0;
                        last = current;
                    }
                }

                return false;
            }

            async function prerollInfinite(options = {}) {
                const {
                    maxSteps = 6,
                    stepDelay = 160,
                    minGrowth = 48,
                    settleFrames = 3
                } = options;

                const root = getROOT();
                let lastGrowth = 0;

                for (let i = 0; i < maxSteps; i++) {
                    const before = root.scrollHeight;
                    const maxScroll = getMaxScroll().y;
                    const target = Math.max(0, maxScroll - 32);

                    root.scrollTop = target;
                    window.dispatchEvent(new Event('scroll', { bubbles: true }));

                    await waitFrames(1);
                    await sleep(stepDelay);
                    await waitForStableLayout({ frames: settleFrames, threshold: 4, timeout: stepDelay * 4 });

                    const after = root.scrollHeight;
                    lastGrowth = after - before;
                    if (lastGrowth < minGrowth) {
                        break;
                    }
                }

                return lastGrowth;
            }

            async function preciseScrollTo(x, y, options = {}) {
                const root = getROOT();
                const { settleFrames = 3, allowHorizontal = true } = options;
                const clamped = clampScrollPosition(x, y);

                if (allowHorizontal) {
                    root.scrollLeft = clamped.x;
                }
                root.scrollTop = clamped.y;

                await waitFrames(settleFrames);
                await waitForStableLayout({ frames: settleFrames, threshold: 2, timeout: 800 });

                return {
                    x: root.scrollLeft || 0,
                    y: root.scrollTop || 0
                };
            }

            (function hardenEnv() {
                if (window._bfcacheEnvHardened) {
                    return;
                }
                window._bfcacheEnvHardened = true;

                try {
                    history.scrollRestoration = 'manual';
                } catch (e) {}

                const style = document.createElement('style');
                style.textContent = `
                    html, body {
                        overflow-anchor: none !important;
                        scroll-behavior: auto !important;
                        -webkit-text-size-adjust: 100% !important;
                    }
                `;
                document.documentElement.appendChild(style);
            })();

            return {
                getROOT,
                getMaxScroll,
                clampScrollPosition,
                fixedHeaderHeight,
                sleep,
                waitFrames,
                waitForStableLayout,
                prerollInfinite,
                preciseScrollTo
            };
        })();
        window.__BFCacheAsyncUtil = BFCacheAsyncUtil;

        const getROOT = BFCacheAsyncUtil.getROOT;
        const getMaxScroll = BFCacheAsyncUtil.getMaxScroll;
        const clampScrollPosition = BFCacheAsyncUtil.clampScrollPosition;
        const fixedHeaderHeight = BFCacheAsyncUtil.fixedHeaderHeight;
        const sleep = BFCacheAsyncUtil.sleep;
        const waitFrames = BFCacheAsyncUtil.waitFrames;
        const waitForStableLayout = BFCacheAsyncUtil.waitForStableLayout;
        const prerollInfinite = BFCacheAsyncUtil.prerollInfinite;
        const preciseScrollTo = BFCacheAsyncUtil.preciseScrollTo;

        """
    }

    private func generateStep1_ContentRestoreScript() -> String {
        let targetHeight = restorationConfig.savedContentHeight

        return """
        \(generateCommonUtilityScript())
        try {
            const logs = [];
            const targetHeight = Math.max(parseFloat('\(targetHeight)'), 0);
            const root = getROOT();
            const currentHeight = root.scrollHeight;

            logs.push('[Step 1] 콘텐츠 높이 복원 시도');
            logs.push('현재 높이: ' + currentHeight.toFixed(0) + 'px');
            logs.push('목표 높이: ' + targetHeight.toFixed(0) + 'px');

            if (targetHeight <= 0) {
                logs.push('목표 높이가 0이거나 미측정 - 성공 처리');
                return {
                    success: true,
                    isStaticSite: true,
                    currentHeight: currentHeight,
                    targetHeight: targetHeight,
                    restoredHeight: currentHeight,
                    percentage: 100,
                    logs: logs
                };
            }

            const initialPercentage = (currentHeight / targetHeight) * 100;
            const isStaticSite = initialPercentage >= 90;

            if (isStaticSite) {
                logs.push('정적 사이트로 판단 - 추가 로딩 불필요');
                return {
                    success: true,
                    isStaticSite: true,
                    currentHeight: currentHeight,
                    targetHeight: targetHeight,
                    restoredHeight: currentHeight,
                    percentage: initialPercentage,
                    logs: logs
                };
            }

            logs.push('동적 사이트 - 추가 콘텐츠 로딩 수행');

            const loadMoreButtons = Array.from(document.querySelectorAll('[data-testid*="load"], [class*="load"], [class*="more"], button[class*="more"], .load-more, .show-more'));
            let clicked = 0;
            for (let i = 0; i < loadMoreButtons.length && i < 5; i++) {
                const button = loadMoreButtons[i];
                if (button && typeof button.click === 'function') {
                    button.click();
                    clicked += 1;
                    await sleep(80);
                }
            }

            if (clicked > 0) {
                logs.push('로드 버튼 클릭 수: ' + clicked);
                await waitFrames(2);
                await waitForStableLayout({ frames: 3, threshold: 4, timeout: 1200 });
            }

            const growth = await prerollInfinite({ maxSteps: 4, stepDelay: 200, minGrowth: 32, settleFrames: 3 });
            logs.push('프리롤 증가량: ' + growth.toFixed(0) + 'px');

            await waitForStableLayout({ frames: 4, threshold: 3, timeout: 1500 });

            const restoredHeight = root.scrollHeight;
            const finalPercentage = targetHeight > 0 ? (restoredHeight / targetHeight) * 100 : 100;
            const success = finalPercentage >= 80;

            logs.push('복원된 높이: ' + restoredHeight.toFixed(0) + 'px');
            logs.push('복원율: ' + finalPercentage.toFixed(1) + '%');

            return {
                success: success,
                isStaticSite: false,
                currentHeight: currentHeight,
                targetHeight: targetHeight,
                restoredHeight: restoredHeight,
                percentage: finalPercentage,
                logs: logs
            };
        } catch (e) {
            return {
                success: false,
                error: e.message,
                logs: ['[Step 1] 오류: ' + e.message]
            };
        }
        """
    }

    private func generateStep2_PercentScrollScript() -> String {
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y

        return """
        \(generateCommonUtilityScript())
        try {
            const logs = [];
            const targetPercentX = parseFloat('\(targetPercentX)');
            const targetPercentY = parseFloat('\(targetPercentY)');

            logs.push('[Step 2] 상대 좌표 기반 스크롤 복원');
            logs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');

            await waitForStableLayout({ frames: 3, timeout: 1000 });

            const maxScroll = getMaxScroll();
            logs.push('측정된 최대 스크롤: X=' + maxScroll.x.toFixed(0) + 'px, Y=' + maxScroll.y.toFixed(0) + 'px');

            const desiredX = (targetPercentX / 100) * maxScroll.x;
            const desiredY = (targetPercentY / 100) * maxScroll.y;
            const targetPosition = clampScrollPosition(desiredX, desiredY);

            logs.push('계산된 목표: X=' + targetPosition.x.toFixed(1) + 'px, Y=' + targetPosition.y.toFixed(1) + 'px');

            const result = await preciseScrollTo(targetPosition.x, targetPosition.y, { settleFrames: 3, allowHorizontal: true });

            const diffX = Math.abs(result.x - targetPosition.x);
            const diffY = Math.abs(result.y - targetPosition.y);

            logs.push('실제 위치: X=' + result.x.toFixed(1) + 'px, Y=' + result.y.toFixed(1) + 'px');
            logs.push('위치 오차: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');

            const success = diffY <= 50;

            return {
                success: success,
                targetPercent: { x: targetPercentX, y: targetPercentY },
                calculatedPosition: { x: targetPosition.x, y: targetPosition.y },
                actualPosition: { x: result.x, y: result.y },
                difference: { x: diffX, y: diffY },
                logs: logs
            };
        } catch (e) {
            return {
                success: false,
                error: e.message,
                logs: ['[Step 2] 오류: ' + e.message]
            };
        }
        """
    }

    private func generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: String) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        \(generateCommonUtilityScript())
        try {
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const infiniteScrollAnchorData = \(anchorDataJSON);
                
                await waitForStableLayout({ frames: 3, timeout: 1200 });
                
                logs.push('[Step 3] 무한스크롤 전용 앵커 복원');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // 앵커 데이터 확인
                if (!infiniteScrollAnchorData || !infiniteScrollAnchorData.anchors || infiniteScrollAnchorData.anchors.length === 0) {
                    logs.push('무한스크롤 앵커 데이터 없음 - 스킵');
                    return {
                        success: false,
                        anchorCount: 0,
                        logs: logs
                    };
                }
                
                const anchors = infiniteScrollAnchorData.anchors;
                logs.push('사용 가능한 앵커: ' + anchors.length + '개');
                
                // 무한스크롤 앵커 타입별 필터링
                const vueComponentAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'vueComponent' && anchor.vueComponent;
                });
                const contentHashAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'contentHash' && anchor.contentHash;
                });
                const virtualIndexAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'virtualIndex' && anchor.virtualIndex;
                });
                
                logs.push('Vue Component 앵커: ' + vueComponentAnchors.length + '개');
                logs.push('Content Hash 앵커: ' + contentHashAnchors.length + '개');
                logs.push('Virtual Index 앵커: ' + virtualIndexAnchors.length + '개');
                
                let foundElement = null;
                let matchedAnchor = null;
                let matchMethod = '';
                let confidence = 0;
                
                // 🎯 **수정: className 처리 함수**
                function getClassNameString(element) {
                    if (typeof element.className === 'string') {
                        return element.className;
                    } else if (element.className && typeof element.className.toString === 'function') {
                        return element.className.toString();
                    }
                    return '';
                }
                
                // 우선순위 1: Vue Component 앵커 매칭
                if (!foundElement && vueComponentAnchors.length > 0) {
                    for (let i = 0; i < vueComponentAnchors.length && !foundElement; i++) {
                        const anchor = vueComponentAnchors[i];
                        const vueComp = anchor.vueComponent;
                        
                        // data-v-* 속성으로 찾기
                        if (vueComp.dataV) {
                            const vueElements = document.querySelectorAll('[' + vueComp.dataV + ']');
                            for (let j = 0; j < vueElements.length; j++) {
                                const element = vueElements[j];
                                const classNameStr = getClassNameString(element);
                                
                                // 컴포넌트 이름과 인덱스 매칭
                                if (vueComp.name && classNameStr.indexOf(vueComp.name) !== -1) {
                                    // 가상 인덱스 기반 매칭
                                    if (vueComp.index !== undefined) {
                                        const elementIndex = Array.from(element.parentElement.children).indexOf(element);
                                        if (Math.abs(elementIndex - vueComp.index) <= 2) { // 허용 오차 2
                                            foundElement = element;
                                            matchedAnchor = anchor;
                                            matchMethod = 'vue_component_with_index';
                                            confidence = 95;
                                            logs.push('Vue 컴포넌트로 매칭: ' + vueComp.name + '[' + vueComp.index + ']');
                                            break;
                                        }
                                    } else {
                                        foundElement = element;
                                        matchedAnchor = anchor;
                                        matchMethod = 'vue_component';
                                        confidence = 85;
                                        logs.push('Vue 컴포넌트로 매칭: ' + vueComp.name);
                                        break;
                                    }
                                }
                            }
                            if (foundElement) break;
                        }
                    }
                }
                
                // 우선순위 2: Content Hash 앵커 매칭
                if (!foundElement && contentHashAnchors.length > 0) {
                    for (let i = 0; i < contentHashAnchors.length && !foundElement; i++) {
                        const anchor = contentHashAnchors[i];
                        const contentHash = anchor.contentHash;
                        
                        // 텍스트 내용으로 매칭
                        if (contentHash.text && contentHash.text.length > 20) {
                            const searchText = contentHash.text.substring(0, 50);
                            const allElements = document.querySelectorAll('*');
                            for (let j = 0; j < allElements.length; j++) {
                                const element = allElements[j];
                                const elementText = (element.textContent || '').trim();
                                if (elementText.indexOf(searchText) !== -1) {
                                    foundElement = element;
                                    matchedAnchor = anchor;
                                    matchMethod = 'content_hash';
                                    confidence = 80;
                                    logs.push('콘텐츠 해시로 매칭: "' + searchText + '"');
                                    break;
                                }
                            }
                            if (foundElement) break;
                        }
                        
                        // 짧은 해시로 매칭
                        if (!foundElement && contentHash.shortHash) {
                            const hashElements = document.querySelectorAll('[data-hash*="' + contentHash.shortHash + '"]');
                            if (hashElements.length > 0) {
                                foundElement = hashElements[0];
                                matchedAnchor = anchor;
                                matchMethod = 'short_hash';
                                confidence = 75;
                                logs.push('짧은 해시로 매칭: ' + contentHash.shortHash);
                                break;
                            }
                        }
                    }
                }
                
                // 우선순위 3: Virtual Index 앵커 매칭 (추정 위치)
                if (!foundElement && virtualIndexAnchors.length > 0) {
                    for (let i = 0; i < virtualIndexAnchors.length && !foundElement; i++) {
                        const anchor = virtualIndexAnchors[i];
                        const virtualIndex = anchor.virtualIndex;
                        
                        // 리스트 인덱스 기반 추정
                        if (virtualIndex.listIndex !== undefined) {
                            const listElements = document.querySelectorAll('li, .item, .list-item, [class*="item"]');
                            const targetIndex = virtualIndex.listIndex;
                            if (targetIndex >= 0 && targetIndex < listElements.length) {
                                foundElement = listElements[targetIndex];
                                matchedAnchor = anchor;
                                matchMethod = 'virtual_index';
                                confidence = 60;
                                logs.push('가상 인덱스로 매칭: [' + targetIndex + ']');
                                break;
                            }
                        }
                        
                        // 페이지 오프셋 기반 추정
                        if (!foundElement && virtualIndex.offsetInPage !== undefined) {
                            const estimatedY = virtualIndex.offsetInPage;
                            const allElements = document.querySelectorAll('*');
                            let closestElement = null;
                            let minDistance = Infinity;
                            
                            for (let j = 0; j < allElements.length; j++) {
                                const element = allElements[j];
                                const rect = element.getBoundingClientRect();
                                const ROOT = getROOT();
                                const elementY = ROOT.scrollTop + rect.top;
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
                                logs.push('페이지 오프셋으로 매칭: ' + estimatedY.toFixed(0) + 'px (오차: ' + minDistance.toFixed(0) + 'px)');
                                break;
                            }
                        }
                    }
                }
                
                if (foundElement && matchedAnchor) {
                    // 🎯 **수정: scrollIntoView 대신 정미한 비동기 이동 + 헤더 보정**
                    const ROOT = getROOT();
                    const rect = foundElement.getBoundingClientRect();
                    const absY = ROOT.scrollTop + rect.top;
                    const headerHeight = fixedHeaderHeight();

                    let finalY = Math.max(0, absY - headerHeight);
                    if (matchedAnchor.offsetFromTop) {
                        finalY = Math.max(0, finalY - matchedAnchor.offsetFromTop);
                    }

                    // 🎯 **preciseScrollTo 사용하여 정미한 이동**
                    const restoredPosition = await preciseScrollTo(targetX, finalY, { settleFrames: 3, allowHorizontal: true });

                    const actualX = restoredPosition.x;
                    const actualY = restoredPosition.y;
                    const diffX = Math.abs(actualX - targetX);
                    const diffY = Math.abs(actualY - targetY);

                    logs.push('앵커 복원 후 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                    logs.push('목표와의 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                    logs.push('매칭 신뢰도: ' + confidence + '%');
                    logs.push('헤더 보정: ' + headerHeight.toFixed(0) + 'px');

                    return {
                        success: diffY <= 80,
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
                
                logs.push('무한스크롤 앵커 매칭 실패');
                return {
                    success: false,
                    anchorCount: anchors.length,
                    logs: logs
                };
                
        } catch (e) {
            return {
                success: false,
                error: e.message,
                logs: ['[Step 3] 오류: ' + e.message]
            };
        }
        """
    }
    
    private func generateStep4_FinalVerificationScript() -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y

        return """
        \(generateCommonUtilityScript())
        try {
            const logs = [];
            const targetX = parseFloat('\(targetX)');
            const targetY = parseFloat('\(targetY)');
            const tolerance = 30;

            logs.push('[Step 4] 최종 좌표 검증');
            logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');

            let current = await preciseScrollTo(targetX, targetY, { settleFrames: 2, allowHorizontal: true });
            let currentX = current.x;
            let currentY = current.y;
            let diffX = Math.abs(currentX - targetX);
            let diffY = Math.abs(currentY - targetY);
            let correctionApplied = false;

            logs.push('1차 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
            logs.push('1차 오차: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');

            if (diffX > tolerance || diffY > tolerance) {
                logs.push('오차 초과 - 재보정 수행');
                current = await preciseScrollTo(targetX, targetY, { settleFrames: 3, allowHorizontal: true });
                currentX = current.x;
                currentY = current.y;
                diffX = Math.abs(currentX - targetX);
                diffY = Math.abs(currentY - targetY);
                correctionApplied = true;
                logs.push('재보정 후 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                logs.push('재보정 후 오차: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
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
        } catch (e) {
            return {
                success: false,
                error: e.message,
                logs: ['[Step 4] 오류: ' + e.message]
            };
        }
        """
    }

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
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🚀 무한스크롤 전용 앵커 캡처)**
    
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
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
        
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            // 🎯 **수정: 단일 스크롤러 기준으로 캡처**
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
            
            if let infiniteScrollAnchors = jsState["infiniteScrollAnchors"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🚀 캡처된 무한스크롤 앵커 데이터 키: \(Array(infiniteScrollAnchors.keys))")
                
                if let anchors = infiniteScrollAnchors["anchors"] as? [[String: Any]] {
                    // 앵커 타입별 카운트
                    let vueComponentCount = anchors.filter { ($0["anchorType"] as? String) == "vueComponent" }.count
                    let contentHashCount = anchors.filter { ($0["anchorType"] as? String) == "contentHash" }.count
                    let virtualIndexCount = anchors.filter { ($0["anchorType"] as? String) == "virtualIndex" }.count
                    let structuralPathCount = anchors.filter { ($0["anchorType"] as? String) == "structuralPath" }.count
                    let intersectionCount = anchors.filter { ($0["anchorType"] as? String) == "intersectionInfo" }.count
                    
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 타입별: Vue=\(vueComponentCount), Hash=\(contentHashCount), Index=\(virtualIndexCount), Path=\(structuralPathCount), Intersection=\(intersectionCount)")
                    
                    if anchors.count > 0 {
                        let firstAnchor = anchors[0]
                        TabPersistenceManager.debugMessages.append("🚀 첫 번째 앵커 키: \(Array(firstAnchor.keys))")
                        
                        // 📊 **첫 번째 앵커 상세 정보 로깅**
                        if let anchorType = firstAnchor["anchorType"] as? String {
                            TabPersistenceManager.debugMessages.append("📊 첫 앵커 타입: \(anchorType)")
                            
                            switch anchorType {
                            case "vueComponent":
                                if let vueComp = firstAnchor["vueComponent"] as? [String: Any] {
                                    let name = vueComp["name"] as? String ?? "unknown"
                                    let dataV = vueComp["dataV"] as? String ?? "unknown"
                                    let index = vueComp["index"] as? Int ?? -1
                                    TabPersistenceManager.debugMessages.append("📊 Vue 컴포넌트: name=\(name), dataV=\(dataV), index=\(index)")
                                }
                            case "contentHash":
                                if let contentHash = firstAnchor["contentHash"] as? [String: Any] {
                                    let shortHash = contentHash["shortHash"] as? String ?? "unknown"
                                    let textLength = (contentHash["text"] as? String)?.count ?? 0
                                    TabPersistenceManager.debugMessages.append("📊 콘텐츠 해시: hash=\(shortHash), textLen=\(textLength)")
                                }
                            case "virtualIndex":
                                if let virtualIndex = firstAnchor["virtualIndex"] as? [String: Any] {
                                    let listIndex = virtualIndex["listIndex"] as? Int ?? -1
                                    let pageIndex = virtualIndex["pageIndex"] as? Int ?? -1
                                    TabPersistenceManager.debugMessages.append("📊 가상 인덱스: list=\(listIndex), page=\(pageIndex)")
                                }
                            default:
                                break
                            }
                        }
                        
                        if let absolutePos = firstAnchor["absolutePosition"] as? [String: Any] {
                            let top = (absolutePos["top"] as? Double) ?? 0
                            let left = (absolutePos["left"] as? Double) ?? 0
                            TabPersistenceManager.debugMessages.append("📊 첫 앵커 위치: X=\(String(format: "%.1f", left))px, Y=\(String(format: "%.1f", top))px")
                        }
                        if let qualityScore = firstAnchor["qualityScore"] as? Int {
                            TabPersistenceManager.debugMessages.append("📊 첫 앵커 품질점수: \(qualityScore)점")
                        }
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 데이터 캡처 실패")
                }
                
                if let stats = infiniteScrollAnchors["stats"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 무한스크롤 앵커 수집 통계: \(stats)")
                }
            } else {
                TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 데이터 캡처 실패")
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
        
        TabPersistenceManager.debugMessages.append("✅ 무한스크롤 앵커 직렬 캡처 완료: \(task.pageRecord.title)")
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
                    return html.length > 500000 ? html.substring(0, 500000) : html;
                } catch(e) { return null; }
            })()
            """
            
            BFCacheSnapshot.runRestorationScript(domScript, in: webView) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 실패: \(error.localizedDescription)")
                } else if let dom = result as? String {
                    domSnapshot = dom
                    TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 성공: \(dom.count)문자")
                }
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 5.0) // 🔧 기존 캡처 타임아웃 유지 (1초)
        
        // 3. ✅ **수정: 무한스크롤 전용 앵커 JS 상태 캡처** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateInfiniteScrollAnchorCaptureScript() // 🚀 **수정된: 무한스크롤 전용 앵커 캡처**
            
            BFCacheSnapshot.runRestorationScript(jsScript, in: webView) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                    
                    // 📊 **상세 캡처 결과 로깅**
                    if let infiniteScrollAnchors = data["infiniteScrollAnchors"] as? [String: Any] {
                        if let anchors = infiniteScrollAnchors["anchors"] as? [[String: Any]] {
                            let vueComponentAnchors = anchors.filter { ($0["anchorType"] as? String) == "vueComponent" }
                            let contentHashAnchors = anchors.filter { ($0["anchorType"] as? String) == "contentHash" }
                            let virtualIndexAnchors = anchors.filter { ($0["anchorType"] as? String) == "virtualIndex" }
                            TabPersistenceManager.debugMessages.append("🚀 JS 캡처된 앵커: 총 \(anchors.count)개 (Vue=\(vueComponentAnchors.count), Hash=\(contentHashAnchors.count), Index=\(virtualIndexAnchors.count))")
                        }
                        if let stats = infiniteScrollAnchors["stats"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("📊 무한스크롤 JS 캡처 통계: \(stats)")
                        }
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 결과 타입 오류: \(type(of: result))")
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 3.0) // 🔧 기존 캡처 타임아웃 유지 (2초)
        
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
        
        // 🔧 **수정: 백분율 계산 로직 수정 - OR 조건으로 변경**
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
        TabPersistenceManager.debugMessages.append("📊 스크롤 계산 정보: actualScrollableHeight=\(captureData.actualScrollableSize.height), viewportHeight=\(captureData.viewportSize.height), maxScrollY=\(max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height))")
        
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
            webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
            captureStatus: captureStatus,
            version: version,
            restorationConfig: restorationConfig
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🚀 **핵심 수정: 무한스크롤 전용 앵커 캡처 - 제목/목록 태그 위주 수집**
    private func generateInfiniteScrollAnchorCaptureScript() -> String {
        return """
        \(generateCommonUtilityScript())
        return (async function() {
            try {
                console.log('🚀 무한스크롤 전용 앵커 캡처 시작 (제목/목록 태그 위주)');
                
                // 🎯 **단일 스크롤러 유틸리티 함수들**
                function getROOT() { 
                    return document.scrollingElement || document.documentElement; 
                }
                
                // 📊 **상세 로그 수집**
                const detailedLogs = [];
                const pageAnalysis = {};
                
                await waitForStableLayout({ frames: 4, threshold: 3, timeout: 1800 });
                await waitFrames(1);
                
                // 🎯 **수정: 단일 스크롤러 기준으로 정보 수집**
                const ROOT = getROOT();
                const scrollY = parseFloat(ROOT.scrollTop) || 0;
                const scrollX = parseFloat(ROOT.scrollLeft) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                const contentHeight = parseFloat(ROOT.scrollHeight) || 0;
                const contentWidth = parseFloat(ROOT.scrollWidth) || 0;
                
                detailedLogs.push('🚀 무한스크롤 전용 앵커 캡처 시작 (단일 스크롤러)');
                detailedLogs.push('스크롤 위치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포트 크기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                console.log('🚀 기본 정보 (단일 스크롤러):', {
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                // 🚀 **SHA256 간단 해시 함수 (콘텐츠 해시용)**
                function simpleHash(str) {
                    let hash = 0;
                    if (str.length === 0) return hash.toString(36);
                    for (let i = 0; i < str.length; i++) {
                        const char = str.charCodeAt(i);
                        hash = ((hash << 5) - hash) + char;
                        hash = hash & hash; // 32비트 정수로 변환
                    }
                    return Math.abs(hash).toString(36);
                }
                
                // 🚀 **수정된: data-v-* 속성 찾기 함수**
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
                
                // 🚀 **새로운: 태그 타입별 품질 점수 계산**
                function calculateTagQualityScore(element) {
                    const tagName = element.tagName.toLowerCase();
                    const textLength = (element.textContent || '').trim().length;
                    
                    // 기본 점수 (태그 타입별)
                    let baseScore = 50;
                    
                    // 제목 태그 (최고 점수)
                    if (['h1', 'h2', 'h3', 'h4', 'h5', 'h6'].indexOf(tagName) !== -1) {
                        baseScore = 95;
                    }
                    // 목록 항목 (높은 점수)
                    else if (['li', 'article', 'section'].indexOf(tagName) !== -1) {
                        baseScore = 85;
                    }
                    // 단락 (중간 점수)
                    else if (tagName === 'p') {
                        baseScore = 75;
                    }
                    // 링크 (중간 점수)
                    else if (tagName === 'a') {
                        baseScore = 70;
                    }
                    // 스팬/div (낮은 점수)
                    else if (['span', 'div'].indexOf(tagName) !== -1) {
                        baseScore = 60;
                    }
                    
                    // 텍스트 길이 보너스 (최대 +30점)
                    const lengthBonus = Math.min(30, Math.floor(textLength / 10));
                    
                    return Math.min(100, baseScore + lengthBonus);
                }
                
                // 🚀 **핵심 수정: 제목/목록 태그 위주로 수집**
                function collectSemanticElements() {
                    const semanticElements = [];
                    
                    // 1. 제목 태그 우선 수집
                    const headings = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
                    for (let i = 0; i < headings.length; i++) {
                        semanticElements.push(headings[i]);
                    }
                    
                    // 2. 목록 항목 수집
                    const listItems = document.querySelectorAll('li, article, section');
                    for (let i = 0; i < listItems.length; i++) {
                        const text = (listItems[i].textContent || '').trim();
                        if (text.length >= 10) { // 최소 10자
                            semanticElements.push(listItems[i]);
                        }
                    }
                    
                    // 3. 단락 태그 수집 (의미있는 것만)
                    const paragraphs = document.querySelectorAll('p');
                    for (let i = 0; i < paragraphs.length; i++) {
                        const text = (paragraphs[i].textContent || '').trim();
                        if (text.length >= 20) { // 최소 20자
                            semanticElements.push(paragraphs[i]);
                        }
                    }
                    
                    // 4. 링크 태그 수집 (의미있는 것만)
                    const links = document.querySelectorAll('a');
                    for (let i = 0; i < links.length; i++) {
                        const text = (links[i].textContent || '').trim();
                        if (text.length >= 5) { // 최소 5자
                            semanticElements.push(links[i]);
                        }
                    }
                    
                    detailedLogs.push('의미 있는 요소 수집: ' + semanticElements.length + '개');
                    return semanticElements;
                }
                
                // 🚀 **핵심: 무한스크롤 전용 앵커 수집 (뷰포트 영역별)**
                function collectInfiniteScrollAnchors() {
                    const anchors = [];
                    const anchorStats = {
                        totalCandidates: 0,
                        vueComponentAnchors: 0,
                        contentHashAnchors: 0,
                        virtualIndexAnchors: 0,
                        finalAnchors: 0,
                        regionDistribution: {
                            aboveViewport: 0,
                            viewportUpper: 0,
                            viewportMiddle: 0,
                            viewportLower: 0,
                            belowViewport: 0
                        },
                        tagDistribution: {
                            headings: 0,
                            listItems: 0,
                            paragraphs: 0,
                            links: 0,
                            others: 0
                        }
                    };
                    
                    detailedLogs.push('🚀 무한스크롤 전용 앵커 수집 시작 (제목/목록 태그 위주)');
                    
                    // 🚀 **1. 의미 있는 요소 수집**
                    let allCandidateElements = collectSemanticElements();
                    
                    // 🚀 **2. Vue.js 컴포넌트 요소 추가 수집 (data-v-* 속성)**
                    const vueElements = document.querySelectorAll('[data-v-], [class*="data-v-"]');
                    for (let i = 0; i < vueElements.length; i++) {
                        allCandidateElements.push(vueElements[i]);
                    }
                    
                    anchorStats.totalCandidates = allCandidateElements.length;
                    detailedLogs.push('후보 요소 총: ' + allCandidateElements.length + '개');
                    
                    // 🚀 **3. 중복 제거**
                    const uniqueElements = [];
                    const processedElements = new Set();
                    
                    for (let i = 0; i < allCandidateElements.length; i++) {
                        const element = allCandidateElements[i];
                        if (!processedElements.has(element)) {
                            processedElements.add(element);
                            uniqueElements.push(element);
                        }
                    }
                    
                    detailedLogs.push('유효 요소: ' + uniqueElements.length + '개');
                    
                    // 🚀 **4. 뷰포트 영역별 + 뷰포트 밖 요소 수집**
                    detailedLogs.push('🎯 뷰포트 영역별 앵커 수집 시작 (상/중/하 + 밖)');
                    
                    // Y축 기준 절대 위치로 정렬 (위에서 아래로)
                    uniqueElements.sort(function(a, b) {
                        const aRect = a.getBoundingClientRect();
                        const bRect = b.getBoundingClientRect();
                        const aTop = scrollY + aRect.top;
                        const bTop = scrollY + bRect.top;
                        return aTop - bTop;
                    });
                    
                    // 🎯 **영역별 분류 및 수집**
                    const viewportTop = scrollY;
                    const viewportBottom = scrollY + viewportHeight;
                    const viewportUpperBound = viewportTop + (viewportHeight * 0.33);
                    const viewportMiddleBound = viewportTop + (viewportHeight * 0.66);
                    
                    const regionsCollected = {
                        aboveViewport: [],
                        viewportUpper: [],
                        viewportMiddle: [],
                        viewportLower: [],
                        belowViewport: []
                    };
                    
                    for (let i = 0; i < uniqueElements.length; i++) {
                        const element = uniqueElements[i];
                        const rect = element.getBoundingClientRect();
                        const elementTop = scrollY + rect.top;
                        const elementCenter = elementTop + (rect.height / 2);
                        
                        if (elementCenter < viewportTop) {
                            regionsCollected.aboveViewport.push(element);
                        } else if (elementCenter >= viewportTop && elementCenter < viewportUpperBound) {
                            regionsCollected.viewportUpper.push(element);
                        } else if (elementCenter >= viewportUpperBound && elementCenter < viewportMiddleBound) {
                            regionsCollected.viewportMiddle.push(element);
                        } else if (elementCenter >= viewportMiddleBound && elementCenter < viewportBottom) {
                            regionsCollected.viewportLower.push(element);
                        } else {
                            regionsCollected.belowViewport.push(element);
                        }
                    }
                    
                    detailedLogs.push('영역별 요소 수: 위=' + regionsCollected.aboveViewport.length + 
                                    ', 상=' + regionsCollected.viewportUpper.length + 
                                    ', 중=' + regionsCollected.viewportMiddle.length + 
                                    ', 하=' + regionsCollected.viewportLower.length + 
                                    ', 아래=' + regionsCollected.belowViewport.length);
                    
                    // 🎯 **각 영역에서 골고루 선택 (총 60개 목표)**
                    const selectedElements = [];
                    const perRegion = 12;
                    
                    const aboveSelected = regionsCollected.aboveViewport.slice(-perRegion);
                    selectedElements.push(...aboveSelected);
                    
                    const upperSelected = regionsCollected.viewportUpper.slice(0, perRegion);
                    selectedElements.push(...upperSelected);
                    
                    const middleSelected = regionsCollected.viewportMiddle.slice(0, perRegion);
                    selectedElements.push(...middleSelected);
                    
                    const lowerSelected = regionsCollected.viewportLower.slice(0, perRegion);
                    selectedElements.push(...lowerSelected);
                    
                    const belowSelected = regionsCollected.belowViewport.slice(0, perRegion);
                    selectedElements.push(...belowSelected);
                    
                    detailedLogs.push('영역별 선택: 위=' + aboveSelected.length + 
                                    ', 상=' + upperSelected.length + 
                                    ', 중=' + middleSelected.length + 
                                    ', 하=' + lowerSelected.length + 
                                    ', 아래=' + belowSelected.length);
                    detailedLogs.push('총 선택: ' + selectedElements.length + '개');
                    
                    // 🚀 **5. 앵커 생성**
                    for (let i = 0; i < selectedElements.length; i++) {
                        try {
                            const element = selectedElements[i];
                            const rect = element.getBoundingClientRect();
                            const absoluteTop = scrollY + rect.top;
                            const absoluteLeft = scrollX + rect.left;
                            const offsetFromTop = scrollY - absoluteTop;
                            const textContent = (element.textContent || '').trim();
                            const tagName = element.tagName.toLowerCase();
                            
                            // 태그 타입 통계
                            if (['h1', 'h2', 'h3', 'h4', 'h5', 'h6'].indexOf(tagName) !== -1) {
                                anchorStats.tagDistribution.headings++;
                            } else if (['li', 'article', 'section'].indexOf(tagName) !== -1) {
                                anchorStats.tagDistribution.listItems++;
                            } else if (tagName === 'p') {
                                anchorStats.tagDistribution.paragraphs++;
                            } else if (tagName === 'a') {
                                anchorStats.tagDistribution.links++;
                            } else {
                                anchorStats.tagDistribution.others++;
                            }
                            
                            // 영역 판정
                            const elementCenter = absoluteTop + (rect.height / 2);
                            let region = 'unknown';
                            if (elementCenter < viewportTop) {
                                region = 'above';
                                anchorStats.regionDistribution.aboveViewport++;
                            } else if (elementCenter < viewportUpperBound) {
                                region = 'upper';
                                anchorStats.regionDistribution.viewportUpper++;
                            } else if (elementCenter < viewportMiddleBound) {
                                region = 'middle';
                                anchorStats.regionDistribution.viewportMiddle++;
                            } else if (elementCenter < viewportBottom) {
                                region = 'lower';
                                anchorStats.regionDistribution.viewportLower++;
                            } else {
                                region = 'below';
                                anchorStats.regionDistribution.belowViewport++;
                            }
                            
                            // 품질 점수 계산
                            const qualityScore = calculateTagQualityScore(element);
                            
                            // Vue Component 앵커
                            const dataVAttr = findDataVAttribute(element);
                            if (dataVAttr) {
                                const vueComponent = {
                                    name: 'unknown',
                                    dataV: dataVAttr,
                                    props: {},
                                    index: i
                                };
                                
                                const classList = Array.from(element.classList);
                                for (let j = 0; j < classList.length; j++) {
                                    const className = classList[j];
                                    if (className.length > 3) {
                                        vueComponent.name = className;
                                        break;
                                    }
                                }
                                
                                if (element.parentElement) {
                                    const siblingIndex = Array.from(element.parentElement.children).indexOf(element);
                                    vueComponent.index = siblingIndex;
                                }
                                
                                anchors.push({
                                    anchorType: 'vueComponent',
                                    vueComponent: vueComponent,
                                    absolutePosition: { top: absoluteTop, left: absoluteLeft },
                                    viewportPosition: { top: rect.top, left: rect.left },
                                    offsetFromTop: offsetFromTop,
                                    size: { width: rect.width, height: rect.height },
                                    textContent: textContent.substring(0, 100),
                                    qualityScore: qualityScore,
                                    anchorIndex: i,
                                    region: region,
                                    tagName: tagName,
                                    captureTimestamp: Date.now()
                                });
                                anchorStats.vueComponentAnchors++;
                            }
                            
                            // Content Hash 앵커
                            const fullHash = simpleHash(textContent);
                            const shortHash = fullHash.substring(0, 8);
                            
                            anchors.push({
                                anchorType: 'contentHash',
                                contentHash: {
                                    fullHash: fullHash,
                                    shortHash: shortHash,
                                    text: textContent.substring(0, 100),
                                    length: textContent.length
                                },
                                absolutePosition: { top: absoluteTop, left: absoluteLeft },
                                viewportPosition: { top: rect.top, left: rect.left },
                                offsetFromTop: offsetFromTop,
                                size: { width: rect.width, height: rect.height },
                                textContent: textContent.substring(0, 100),
                                qualityScore: qualityScore,
                                anchorIndex: i,
                                region: region,
                                tagName: tagName,
                                captureTimestamp: Date.now()
                            });
                            anchorStats.contentHashAnchors++;
                            
                            // Virtual Index 앵커
                            anchors.push({
                                anchorType: 'virtualIndex',
                                virtualIndex: {
                                    listIndex: i,
                                    pageIndex: Math.floor(i / 12),
                                    offsetInPage: absoluteTop,
                                    estimatedTotal: selectedElements.length
                                },
                                absolutePosition: { top: absoluteTop, left: absoluteLeft },
                                viewportPosition: { top: rect.top, left: rect.left },
                                offsetFromTop: offsetFromTop,
                                size: { width: rect.width, height: rect.height },
                                textContent: textContent.substring(0, 100),
                                qualityScore: qualityScore,
                                anchorIndex: i,
                                region: region,
                                tagName: tagName,
                                captureTimestamp: Date.now()
                            });
                            anchorStats.virtualIndexAnchors++;
                            
                        } catch(e) {
                            console.warn('앵커[' + i + '] 생성 실패:', e);
                        }
                    }
                    
                    anchorStats.finalAnchors = anchors.length;
                    
                    detailedLogs.push('무한스크롤 앵커 생성 완료: ' + anchors.length + '개');
                    detailedLogs.push('태그별 앵커 분포: 제목=' + anchorStats.tagDistribution.headings + 
                                    ', 목록=' + anchorStats.tagDistribution.listItems + 
                                    ', 단락=' + anchorStats.tagDistribution.paragraphs + 
                                    ', 링크=' + anchorStats.tagDistribution.links + 
                                    ', 기타=' + anchorStats.tagDistribution.others);
                    console.log('🚀 무한스크롤 앵커 수집 완료:', anchors.length, '개');
                    
                    return {
                        anchors: anchors,
                        stats: anchorStats
                    };
                }
                
                // 🚀 **메인 실행**
                const startTime = Date.now();
                const infiniteScrollAnchorsData = collectInfiniteScrollAnchors();
                const endTime = Date.now();
                const captureTime = endTime - startTime;
                
                pageAnalysis.capturePerformance = {
                    totalTime: captureTime,
                    anchorsPerSecond: infiniteScrollAnchorsData.anchors.length > 0 ? (infiniteScrollAnchorsData.anchors.length / (captureTime / 1000)).toFixed(2) : 0
                };
                
                detailedLogs.push('=== 무한스크롤 전용 앵커 캡처 완료 (' + captureTime + 'ms) ===');
                detailedLogs.push('최종 무한스크롤 앵커: ' + infiniteScrollAnchorsData.anchors.length + '개');
                
                console.log('🚀 무한스크롤 전용 앵커 캡처 완료:', {
                    infiniteScrollAnchorsCount: infiniteScrollAnchorsData.anchors.length,
                    stats: infiniteScrollAnchorsData.stats,
                    captureTime: captureTime
                });
                
                return {
                    infiniteScrollAnchors: infiniteScrollAnchorsData,
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
                    captureStats: infiniteScrollAnchorsData.stats,
                    pageAnalysis: pageAnalysis,
                    captureTime: captureTime
                };
            } catch(e) { 
                console.error('🚀 무한스크롤 전용 앵커 캡처 실패:', e);
                return {
                    infiniteScrollAnchors: { anchors: [], stats: {} },
                    scroll: { 
                        x: parseFloat(document.scrollingElement?.scrollLeft || document.documentElement.scrollLeft) || 0, 
                        y: parseFloat(document.scrollingElement?.scrollTop || document.documentElement.scrollTop) || 0 
                    },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message,
                    detailedLogs: ['무한스크롤 전용 앵커 캡처 실패: ' + e.message],
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
        
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
