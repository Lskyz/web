//
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
    
    // MARK: - 🎯 단일 스크롤러 JavaScript 생성 메서드들
    
    // 🎯 **공통 유틸리티 스크립트 생성**
    private func generateCommonUtilityScript() -> String {
        return """
        // 🎯 **단일 스크롤러 공통 유틸리티 (동기 버전)**
        function getROOT() { 
            return document.scrollingElement || document.documentElement; 
        }
        
        function getMaxScroll() { 
            const r = getROOT(); 
            return { 
                x: Math.max(0, r.scrollWidth - window.innerWidth),
                y: Math.max(0, r.scrollHeight - window.innerHeight) 
            }; 
        }
        
        function waitForStableLayoutSync(options = {}) {
            const { frames = 6, timeout = 1500, threshold = 2 } = options;
            const ROOT = getROOT();
            let last = ROOT.scrollHeight;
            let stable = 0;
            const startTime = Date.now();
            const maxIterations = Math.floor(timeout / 20); // 20ms씩 체크
            
            for (let i = 0; i < maxIterations; i++) {
                const h = ROOT.scrollHeight;
                if (Math.abs(h - last) <= threshold) {
                    stable++;
                } else {
                    stable = 0;
                }
                last = h;
                
                if (stable >= frames) {
                    break;
                }
                
                // 20ms 동기 대기
                const waitStart = Date.now();
                while (Date.now() - waitStart < 20) { /* 대기 */ }
            }
        }
        
        function preciseScrollToSync(x, y) {
            const ROOT = getROOT();
            
            // 첫 번째 설정
            ROOT.scrollLeft = x;
            ROOT.scrollTop = y;
            
            // 브라우저가 적용할 시간 대기 (동기)
            const waitStart = Date.now();
            while (Date.now() - waitStart < 16) { /* ~1프레임 대기 */ }
            
            // 두 번째 설정 (보정)
            ROOT.scrollLeft = x;
            ROOT.scrollTop = y;
            
            // 최종 적용 대기
            const waitStart2 = Date.now();
            while (Date.now() - waitStart2 < 16) { /* ~1프레임 대기 */ }
            
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
        
        function prerollInfiniteSync(maxSteps = 6) {
            const ROOT = getROOT();
            for (let i = 0; i < maxSteps; i++) {
                const before = ROOT.scrollHeight;
                ROOT.scrollTop = before; // 바닥
                window.dispatchEvent(new Event('scroll', { bubbles: true }));
                
                // 120ms 동기 대기
                const waitStart = Date.now();
                while (Date.now() - waitStart < 120) { /* 대기 */ }
                
                const after = ROOT.scrollHeight;
                if (after - before < 64) break; // 더 이상 늘지 않으면 종료
            }
            
            // 안정화 대기
            waitForStableLayoutSync();
        }
        
        // 🎯 **환경 안정화 (한 번만 실행)**
        (function hardenEnv() {
            if (window._bfcacheEnvHardened) return;
            window._bfcacheEnvHardened = true;
            
            try { 
                history.scrollRestoration = 'manual'; 
            } catch(e) {}
            
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
        """
    }
    
    private func generateStep1_ContentRestoreScript() -> String {
        let targetHeight = restorationConfig.savedContentHeight
        
        return """
        (function() {
            try {
                \(generateCommonUtilityScript())
                
                const logs = [];

                function cssEscapeCompat(value) {
                    if (value === null || value === undefined) return '';
                    if (window.CSS && CSS.escape) {
                        return CSS.escape(value);
                    }
                    return String(value).replace(/([ !"#$%&'()*+,./:;<=>?@[\]^`{|}~])/g, function(match) { return String.fromCharCode(92) + match; });
                }

                function datasetKeyToAttr(key) {
                    return 'data-' + String(key || '').replace(/([A-Z])/g, '-$1').toLowerCase();
                }

                function locateVirtualContainer(containerInfo) {
                    const resultLogs = [];
                    if (!containerInfo) {
                        resultLogs.push('Virtual container info missing');
                        return { element: null, logs: resultLogs };
                    }

                    let container = null;
                    if (containerInfo.domPath) {
                        try {
                            container = document.querySelector(containerInfo.domPath);
                            if (container) {
                                resultLogs.push('Matched container by domPath');
                                return { element: container, logs: resultLogs };
                            } else {
                                resultLogs.push('DomPath not found: ' + containerInfo.domPath);
                            }
                        } catch(e) {
                            resultLogs.push('DomPath lookup error: ' + e.message);
                        }
                    }

                    if (!container && containerInfo.id) {
                        container = document.getElementById(containerInfo.id);
                        if (container) {
                            resultLogs.push('Matched container by id #' + containerInfo.id);
                            return { element: container, logs: resultLogs };
                        } else {
                            resultLogs.push('ID not found: #' + containerInfo.id);
                        }
                    }

                    if (!container && containerInfo.classList && containerInfo.classList.length) {
                        for (let i = 0; i < containerInfo.classList.length; i++) {
                            const cls = containerInfo.classList[i];
                            try {
                                const candidate = document.querySelector('.' + cssEscapeCompat(cls));
                                if (candidate) {
                                    container = candidate;
                                    resultLogs.push('Matched container by class .' + cls);
                                    break;
                                }
                            } catch(e) {}
                        }
                    }

                    if (!container && containerInfo.dataset) {
                        const keys = Object.keys(containerInfo.dataset);
                        for (let i = 0; i < keys.length; i++) {
                            const attrName = datasetKeyToAttr(keys[i]);
                            const value = containerInfo.dataset[keys[i]];
                            if (!value) continue;
                            try {
                                const selector = '[' + attrName + '="' + cssEscapeCompat(value) + '"]';
                                const candidate = document.querySelector(selector);
                                if (candidate) {
                                    container = candidate;
                                    resultLogs.push('Matched container by dataset ' + selector);
                                    break;
                                }
                            } catch(e) {}
                        }
                    }

                    if (!container) {
                        const fallbackCandidates = Array.from(document.querySelectorAll('[class*="virtual"], [data-virtualized], [data-virtual], [data-virtual-scroll], [data-windowed]')).filter(function(el) {
                            if (!el || !el.getBoundingClientRect) return false;
                            const rect = el.getBoundingClientRect();
                            return rect.height >= 60 && Math.abs((el.scrollHeight || 0) - (el.clientHeight || 0)) > 20;
                        });
                        if (fallbackCandidates.length > 0) {
                            container = fallbackCandidates[0];
                            resultLogs.push('Fallback virtual container selected by heuristics');
                        } else {
                            resultLogs.push('Virtual container fallback search failed');
                        }
                    }

                    return { element: container, logs: resultLogs };
                }

                function trySelectorsInContainer(container, selectors, triedSelectors) {
                    if (!container || !selectors) return null;
                    triedSelectors = triedSelectors || new Set();
                    for (let i = 0; i < selectors.length; i++) {
                        const selector = selectors[i];
                        if (!selector || triedSelectors.has(selector)) continue;
                        triedSelectors.add(selector);
                        try {
                            const found = container.querySelector(selector);
                            if (found) {
                                return found;
                            }
                        } catch(e) {}
                    }
                    return null;
                }

                function buildSelectorsFromDescriptor(descriptor) {
                    const selectors = [];
                    if (!descriptor) return selectors;
                    if (descriptor.attributes) {
                        const keys = Object.keys(descriptor.attributes);
                        for (let i = 0; i < keys.length; i++) {
                            const attr = keys[i];
                            const value = descriptor.attributes[attr];
                            if (value === undefined || value === null || value === '') continue;
                            const base = '[' + attr + '="' + cssEscapeCompat(value) + '"]';
                            selectors.push(base);
                            if (descriptor.tagName) {
                                selectors.push(descriptor.tagName + base);
                            }
                        }
                    }
                    if (descriptor.aria) {
                        const keys = Object.keys(descriptor.aria);
                        for (let i = 0; i < keys.length; i++) {
                            const attr = keys[i];
                            const value = descriptor.aria[attr];
                            if (value === undefined || value === null || value === '') continue;
                            const base = '[' + attr + '="' + cssEscapeCompat(value) + '"]';
                            selectors.push(base);
                            if (descriptor.tagName) {
                                selectors.push(descriptor.tagName + base);
                            }
                        }
                    }
                    return selectors;
                }

                function findVirtualFocusElement(container, anchorInfo) {
                    if (!container || !anchorInfo) return null;
                    const triedSelectors = new Set();
                    const tryQueue = [];
                    if (anchorInfo.focusItem) {
                        tryQueue.push(anchorInfo.focusItem);
                    }
                    if (anchorInfo.visibleItems && anchorInfo.visibleItems.length) {
                        for (let i = 0; i < Math.min(anchorInfo.visibleItems.length, 6); i++) {
                            tryQueue.push(anchorInfo.visibleItems[i]);
                        }
                    }

                    for (let i = 0; i < tryQueue.length; i++) {
                        const descriptor = tryQueue[i];
                        if (!descriptor) continue;

                        if (descriptor.domPath) {
                            try {
                                const absoluteMatch = document.querySelector(descriptor.domPath);
                                if (absoluteMatch && container.contains(absoluteMatch)) {
                                    return absoluteMatch;
                                }
                            } catch(e) {}
                        }

                        const selectors = buildSelectorsFromDescriptor(descriptor);
                        const found = trySelectorsInContainer(container, selectors, triedSelectors);
                        if (found) {
                            return found;
                        }

                        if (descriptor.text) {
                            const snippet = descriptor.text.trim().toLowerCase().slice(0, 40);
                            if (snippet.length >= 3) {
                                const nodes = Array.from(container.querySelectorAll(descriptor.tagName || '[data-index],[data-key],div,li'));
                                let bestMatch = null;
                                let bestScore = Infinity;
                                for (let j = 0; j < nodes.length && j < 80; j++) {
                                    const node = nodes[j];
                                    const nodeText = (node.textContent || '').trim().toLowerCase();
                                    if (!nodeText) continue;
                                    const index = nodeText.indexOf(snippet);
                                    if (index !== -1 && index < bestScore) {
                                        bestScore = index;
                                        bestMatch = node;
                                    } else if (!bestMatch && nodeText.startsWith(snippet.split(' ')[0])) {
                                        bestMatch = node;
                                    }
                                }
                                if (bestMatch) {
                                    return bestMatch;
                                }
                            }
                        }
                    }

                    return null;
                }

                function restoreVirtualScrollerAnchor(anchor) {
                    const resultLogs = [];
                    if (!anchor || !anchor.virtualScroller) {
                        return { element: null, logs: resultLogs };
                    }

                    const info = anchor.virtualScroller;
                    const containerInfo = info.container || {};
                    const located = locateVirtualContainer(containerInfo);
                    if (located.logs && located.logs.length) {
                        for (let i = 0; i < located.logs.length; i++) {
                            resultLogs.push(located.logs[i]);
                        }
                    }
                    const container = located.element;
                    if (!container) {
                        resultLogs.push('Virtual container element not found');
                        return { element: null, logs: resultLogs, containerPath: containerInfo.domPath || null };
                    }

                    const maxScroll = Math.max(0, (container.scrollHeight || 0) - (container.clientHeight || 0));
                    let targetScrollTop = typeof containerInfo.scrollTop === 'number' ? containerInfo.scrollTop : container.scrollTop;
                    if (typeof containerInfo.scrollPercent === 'number' && isFinite(containerInfo.scrollPercent) && maxScroll > 0) {
                        targetScrollTop = Math.max(0, Math.min(maxScroll, containerInfo.scrollPercent * maxScroll));
                    }
                    targetScrollTop = Math.max(0, Math.min(maxScroll, targetScrollTop));

                    const beforeScroll = container.scrollTop;
                    container.scrollTop = targetScrollTop;
                    if (typeof containerInfo.scrollLeft === 'number') {
                        container.scrollLeft = containerInfo.scrollLeft;
                    }
                    container.dispatchEvent(new Event('scroll', { bubbles: true }));
                    const waitStart = Date.now();
                    while (Date.now() - waitStart < 32) {}
                    container.dispatchEvent(new Event('scroll', { bubbles: true }));

                    resultLogs.push('Virtual container scrollTop ' + beforeScroll.toFixed(1) + ' -> ' + container.scrollTop.toFixed(1));

                    const focusElement = findVirtualFocusElement(container, info);
                    if (!focusElement) {
                        resultLogs.push('Virtual focus element not found after scroll');
                        return { element: null, logs: resultLogs, containerPath: containerInfo.domPath || null };
                    }

                    return {
                        element: focusElement,
                        logs: resultLogs,
                        containerPath: containerInfo.domPath || null,
                        method: 'virtual_scroller',
                        confidence: Math.min(90, Math.max(60, info.confidence || 60))
                    };
                }

 catch(e) {
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
                \(generateCommonUtilityScript())
                
                const logs = [];

                function cssEscapeCompat(value) {
                    if (value === null || value === undefined) return '';
                    if (window.CSS && CSS.escape) {
                        return CSS.escape(value);
                    }
                    return String(value).replace(/([ !"#$%&'()*+,./:;<=>?@[\]^`{|}~])/g, function(match) { return String.fromCharCode(92) + match; });
                }

                function datasetKeyToAttr(key) {
                    return 'data-' + String(key || '').replace(/([A-Z])/g, '-$1').toLowerCase();
                }

                function locateVirtualContainer(containerInfo) {
                    const resultLogs = [];
                    if (!containerInfo) {
                        resultLogs.push('Virtual container info missing');
                        return { element: null, logs: resultLogs };
                    }

                    let container = null;
                    if (containerInfo.domPath) {
                        try {
                            container = document.querySelector(containerInfo.domPath);
                            if (container) {
                                resultLogs.push('Matched container by domPath');
                                return { element: container, logs: resultLogs };
                            } else {
                                resultLogs.push('DomPath not found: ' + containerInfo.domPath);
                            }
                        } catch(e) {
                            resultLogs.push('DomPath lookup error: ' + e.message);
                        }
                    }

                    if (!container && containerInfo.id) {
                        container = document.getElementById(containerInfo.id);
                        if (container) {
                            resultLogs.push('Matched container by id #' + containerInfo.id);
                            return { element: container, logs: resultLogs };
                        } else {
                            resultLogs.push('ID not found: #' + containerInfo.id);
                        }
                    }

                    if (!container && containerInfo.classList && containerInfo.classList.length) {
                        for (let i = 0; i < containerInfo.classList.length; i++) {
                            const cls = containerInfo.classList[i];
                            try {
                                const candidate = document.querySelector('.' + cssEscapeCompat(cls));
                                if (candidate) {
                                    container = candidate;
                                    resultLogs.push('Matched container by class .' + cls);
                                    break;
                                }
                            } catch(e) {}
                        }
                    }

                    if (!container && containerInfo.dataset) {
                        const keys = Object.keys(containerInfo.dataset);
                        for (let i = 0; i < keys.length; i++) {
                            const attrName = datasetKeyToAttr(keys[i]);
                            const value = containerInfo.dataset[keys[i]];
                            if (!value) continue;
                            try {
                                const selector = '[' + attrName + '="' + cssEscapeCompat(value) + '"]';
                                const candidate = document.querySelector(selector);
                                if (candidate) {
                                    container = candidate;
                                    resultLogs.push('Matched container by dataset ' + selector);
                                    break;
                                }
                            } catch(e) {}
                        }
                    }

                    if (!container) {
                        const fallbackCandidates = Array.from(document.querySelectorAll('[class*="virtual"], [data-virtualized], [data-virtual], [data-virtual-scroll], [data-windowed]')).filter(function(el) {
                            if (!el || !el.getBoundingClientRect) return false;
                            const rect = el.getBoundingClientRect();
                            return rect.height >= 60 && Math.abs((el.scrollHeight || 0) - (el.clientHeight || 0)) > 20;
                        });
                        if (fallbackCandidates.length > 0) {
                            container = fallbackCandidates[0];
                            resultLogs.push('Fallback virtual container selected by heuristics');
                        } else {
                            resultLogs.push('Virtual container fallback search failed');
                        }
                    }

                    return { element: container, logs: resultLogs };
                }

                function trySelectorsInContainer(container, selectors, triedSelectors) {
                    if (!container || !selectors) return null;
                    triedSelectors = triedSelectors || new Set();
                    for (let i = 0; i < selectors.length; i++) {
                        const selector = selectors[i];
                        if (!selector || triedSelectors.has(selector)) continue;
                        triedSelectors.add(selector);
                        try {
                            const found = container.querySelector(selector);
                            if (found) {
                                return found;
                            }
                        } catch(e) {}
                    }
                    return null;
                }

                function buildSelectorsFromDescriptor(descriptor) {
                    const selectors = [];
                    if (!descriptor) return selectors;
                    if (descriptor.attributes) {
                        const keys = Object.keys(descriptor.attributes);
                        for (let i = 0; i < keys.length; i++) {
                            const attr = keys[i];
                            const value = descriptor.attributes[attr];
                            if (value === undefined || value === null || value === '') continue;
                            const base = '[' + attr + '="' + cssEscapeCompat(value) + '"]';
                            selectors.push(base);
                            if (descriptor.tagName) {
                                selectors.push(descriptor.tagName + base);
                            }
                        }
                    }
                    if (descriptor.aria) {
                        const keys = Object.keys(descriptor.aria);
                        for (let i = 0; i < keys.length; i++) {
                            const attr = keys[i];
                            const value = descriptor.aria[attr];
                            if (value === undefined || value === null || value === '') continue;
                            const base = '[' + attr + '="' + cssEscapeCompat(value) + '"]';
                            selectors.push(base);
                            if (descriptor.tagName) {
                                selectors.push(descriptor.tagName + base);
                            }
                        }
                    }
                    return selectors;
                }

                function findVirtualFocusElement(container, anchorInfo) {
                    if (!container || !anchorInfo) return null;
                    const triedSelectors = new Set();
                    const tryQueue = [];
                    if (anchorInfo.focusItem) {
                        tryQueue.push(anchorInfo.focusItem);
                    }
                    if (anchorInfo.visibleItems && anchorInfo.visibleItems.length) {
                        for (let i = 0; i < Math.min(anchorInfo.visibleItems.length, 6); i++) {
                            tryQueue.push(anchorInfo.visibleItems[i]);
                        }
                    }

                    for (let i = 0; i < tryQueue.length; i++) {
                        const descriptor = tryQueue[i];
                        if (!descriptor) continue;

                        if (descriptor.domPath) {
                            try {
                                const absoluteMatch = document.querySelector(descriptor.domPath);
                                if (absoluteMatch && container.contains(absoluteMatch)) {
                                    return absoluteMatch;
                                }
                            } catch(e) {}
                        }

                        const selectors = buildSelectorsFromDescriptor(descriptor);
                        const found = trySelectorsInContainer(container, selectors, triedSelectors);
                        if (found) {
                            return found;
                        }

                        if (descriptor.text) {
                            const snippet = descriptor.text.trim().toLowerCase().slice(0, 40);
                            if (snippet.length >= 3) {
                                const nodes = Array.from(container.querySelectorAll(descriptor.tagName || '[data-index],[data-key],div,li'));
                                let bestMatch = null;
                                let bestScore = Infinity;
                                for (let j = 0; j < nodes.length && j < 80; j++) {
                                    const node = nodes[j];
                                    const nodeText = (node.textContent || '').trim().toLowerCase();
                                    if (!nodeText) continue;
                                    const index = nodeText.indexOf(snippet);
                                    if (index !== -1 && index < bestScore) {
                                        bestScore = index;
                                        bestMatch = node;
                                    } else if (!bestMatch && nodeText.startsWith(snippet.split(' ')[0])) {
                                        bestMatch = node;
                                    }
                                }
                                if (bestMatch) {
                                    return bestMatch;
                                }
                            }
                        }
                    }

                    return null;
                }

                

                    const info = anchor.virtualScroller;
                    const containerInfo = info.container || {};
                    const located = locateVirtualContainer(containerInfo);
                    if (located.logs && located.logs.length) {
                        for (let i = 0; i < located.logs.length; i++) {
                            resultLogs.push(located.logs[i]);
                        }
                    }
                    const container = located.element;
                    if (!container) {
                        resultLogs.push('Virtual container element not found');
                        return { element: null, logs: resultLogs, containerPath: containerInfo.domPath || null };
                    }

                    const maxScroll = Math.max(0, (container.scrollHeight || 0) - (container.clientHeight || 0));
                    let targetScrollTop = typeof containerInfo.scrollTop === 'number' ? containerInfo.scrollTop : container.scrollTop;
                    if (typeof containerInfo.scrollPercent === 'number' && isFinite(containerInfo.scrollPercent) && maxScroll > 0) {
                        targetScrollTop = Math.max(0, Math.min(maxScroll, containerInfo.scrollPercent * maxScroll));
                    }
                    targetScrollTop = Math.max(0, Math.min(maxScroll, targetScrollTop));

                    const beforeScroll = container.scrollTop;
                    container.scrollTop = targetScrollTop;
                    if (typeof containerInfo.scrollLeft === 'number') {
                        container.scrollLeft = containerInfo.scrollLeft;
                    }
                    container.dispatchEvent(new Event('scroll', { bubbles: true }));
                    const waitStart = Date.now();
                    while (Date.now() - waitStart < 32) {}
                    container.dispatchEvent(new Event('scroll', { bubbles: true }));

                    resultLogs.push('Virtual container scrollTop ' + beforeScroll.toFixed(1) + ' -> ' + container.scrollTop.toFixed(1));

                    const focusElement = findVirtualFocusElement(container, info);
                    if (!focusElement) {
                        resultLogs.push('Virtual focus element not found after scroll');
                        return { element: null, logs: resultLogs, containerPath: containerInfo.domPath || null };
                    }

                    return {
                        element: focusElement,
                        logs: resultLogs,
                        containerPath: containerInfo.domPath || null,
                        method: 'virtual_scroller',
                        confidence: Math.min(90, Math.max(60, info.confidence || 60))
                    };
                }

                const targetPercentX = parseFloat('\(targetPercentX)');
                const targetPercentY = parseFloat('\(targetPercentY)');
                
                logs.push('[Step 2] 상대좌표 기반 스크롤 복원');
                logs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                
                // 🎯 **수정: 동기적 안정화 대기**
                waitForStableLayoutSync({ frames: 3, timeout: 1000 });
                
                const ROOT = getROOT();
                const max = getMaxScroll();
                
                logs.push('최대 스크롤: X=' + max.x.toFixed(0) + 'px, Y=' + max.y.toFixed(0) + 'px');
                
                // 백분율 기반 목표 위치 계산
                const targetX = (targetPercentX / 100) * max.x;
                const targetY = (targetPercentY / 100) * max.y;
                
                logs.push('계산된 목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                // 🎯 **수정: 동기적 정밀 스크롤**
                const result = preciseScrollToSync(targetX, targetY);
                
                const diffX = Math.abs(result.x - targetX);
                const diffY = Math.abs(result.y - targetY);
                
                logs.push('실제 위치: X=' + result.x.toFixed(1) + 'px, Y=' + result.y.toFixed(1) + 'px');
                logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                // 허용 오차 50px 이내면 성공
                const success = diffY <= 50;
                
                return {
                    success: success,
                    targetPercent: { x: targetPercentX, y: targetPercentY },
                    calculatedPosition: { x: targetX, y: targetY },
                    actualPosition: { x: result.x, y: result.y },
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
    
    private func generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: String) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                \(generateCommonUtilityScript())
                
                const logs = [];

                function cssEscapeCompat(value) {
                    if (value === null || value === undefined) return '';
                    if (window.CSS && CSS.escape) {
                        return CSS.escape(value);
                    }
                    return String(value).replace(/([ !"#$%&'()*+,./:;<=>?@[\]^`{|}~])/g, function(match) { return String.fromCharCode(92) + match; });
                }

                function datasetKeyToAttr(key) {
                    return 'data-' + String(key || '').replace(/([A-Z])/g, '-$1').toLowerCase();
                }

                function locateVirtualContainer(containerInfo) {
                    const resultLogs = [];
                    if (!containerInfo) {
                        resultLogs.push('Virtual container info missing');
                        return { element: null, logs: resultLogs };
                    }

                    let container = null;
                    if (containerInfo.domPath) {
                        try {
                            container = document.querySelector(containerInfo.domPath);
                            if (container) {
                                resultLogs.push('Matched container by domPath');
                                return { element: container, logs: resultLogs };
                            } else {
                                resultLogs.push('DomPath not found: ' + containerInfo.domPath);
                            }
                        } catch(e) {
                            resultLogs.push('DomPath lookup error: ' + e.message);
                        }
                    }

                    if (!container && containerInfo.id) {
                        container = document.getElementById(containerInfo.id);
                        if (container) {
                            resultLogs.push('Matched container by id #' + containerInfo.id);
                            return { element: container, logs: resultLogs };
                        } else {
                            resultLogs.push('ID not found: #' + containerInfo.id);
                        }
                    }

                    if (!container && containerInfo.classList && containerInfo.classList.length) {
                        for (let i = 0; i < containerInfo.classList.length; i++) {
                            const cls = containerInfo.classList[i];
                            try {
                                const candidate = document.querySelector('.' + cssEscapeCompat(cls));
                                if (candidate) {
                                    container = candidate;
                                    resultLogs.push('Matched container by class .' + cls);
                                    break;
                                }
                            } catch(e) {}
                        }
                    }

                    if (!container && containerInfo.dataset) {
                        const keys = Object.keys(containerInfo.dataset);
                        for (let i = 0; i < keys.length; i++) {
                            const attrName = datasetKeyToAttr(keys[i]);
                            const value = containerInfo.dataset[keys[i]];
                            if (!value) continue;
                            try {
                                const selector = '[' + attrName + '="' + cssEscapeCompat(value) + '"]';
                                const candidate = document.querySelector(selector);
                                if (candidate) {
                                    container = candidate;
                                    resultLogs.push('Matched container by dataset ' + selector);
                                    break;
                                }
                            } catch(e) {}
                        }
                    }

                    if (!container) {
                        const fallbackCandidates = Array.from(document.querySelectorAll('[class*="virtual"], [data-virtualized], [data-virtual], [data-virtual-scroll], [data-windowed]')).filter(function(el) {
                            if (!el || !el.getBoundingClientRect) return false;
                            const rect = el.getBoundingClientRect();
                            return rect.height >= 60 && Math.abs((el.scrollHeight || 0) - (el.clientHeight || 0)) > 20;
                        });
                        if (fallbackCandidates.length > 0) {
                            container = fallbackCandidates[0];
                            resultLogs.push('Fallback virtual container selected by heuristics');
                        } else {
                            resultLogs.push('Virtual container fallback search failed');
                        }
                    }

                    return { element: container, logs: resultLogs };
                }

                function trySelectorsInContainer(container, selectors, triedSelectors) {
                    if (!container || !selectors) return null;
                    triedSelectors = triedSelectors || new Set();
                    for (let i = 0; i < selectors.length; i++) {
                        const selector = selectors[i];
                        if (!selector || triedSelectors.has(selector)) continue;
                        triedSelectors.add(selector);
                        try {
                            const found = container.querySelector(selector);
                            if (found) {
                                return found;
                            }
                        } catch(e) {}
                    }
                    return null;
                }

                function buildSelectorsFromDescriptor(descriptor) {
                    const selectors = [];
                    if (!descriptor) return selectors;
                    if (descriptor.attributes) {
                        const keys = Object.keys(descriptor.attributes);
                        for (let i = 0; i < keys.length; i++) {
                            const attr = keys[i];
                            const value = descriptor.attributes[attr];
                            if (value === undefined || value === null || value === '') continue;
                            const base = '[' + attr + '="' + cssEscapeCompat(value) + '"]';
                            selectors.push(base);
                            if (descriptor.tagName) {
                                selectors.push(descriptor.tagName + base);
                            }
                        }
                    }
                    if (descriptor.aria) {
                        const keys = Object.keys(descriptor.aria);
                        for (let i = 0; i < keys.length; i++) {
                            const attr = keys[i];
                            const value = descriptor.aria[attr];
                            if (value === undefined || value === null || value === '') continue;
                            const base = '[' + attr + '="' + cssEscapeCompat(value) + '"]';
                            selectors.push(base);
                            if (descriptor.tagName) {
                                selectors.push(descriptor.tagName + base);
                            }
                        }
                    }
                    return selectors;
                }

                function findVirtualFocusElement(container, anchorInfo) {
                    if (!container || !anchorInfo) return null;
                    const triedSelectors = new Set();
                    const tryQueue = [];
                    if (anchorInfo.focusItem) {
                        tryQueue.push(anchorInfo.focusItem);
                    }
                    if (anchorInfo.visibleItems && anchorInfo.visibleItems.length) {
                        for (let i = 0; i < Math.min(anchorInfo.visibleItems.length, 6); i++) {
                            tryQueue.push(anchorInfo.visibleItems[i]);
                        }
                    }

                    for (let i = 0; i < tryQueue.length; i++) {
                        const descriptor = tryQueue[i];
                        if (!descriptor) continue;

                        if (descriptor.domPath) {
                            try {
                                const absoluteMatch = document.querySelector(descriptor.domPath);
                                if (absoluteMatch && container.contains(absoluteMatch)) {
                                    return absoluteMatch;
                                }
                            } catch(e) {}
                        }

                        const selectors = buildSelectorsFromDescriptor(descriptor);
                        const found = trySelectorsInContainer(container, selectors, triedSelectors);
                        if (found) {
                            return found;
                        }

                        if (descriptor.text) {
                            const snippet = descriptor.text.trim().toLowerCase().slice(0, 40);
                            if (snippet.length >= 3) {
                                const nodes = Array.from(container.querySelectorAll(descriptor.tagName || '[data-index],[data-key],div,li'));
                                let bestMatch = null;
                                let bestScore = Infinity;
                                for (let j = 0; j < nodes.length && j < 80; j++) {
                                    const node = nodes[j];
                                    const nodeText = (node.textContent || '').trim().toLowerCase();
                                    if (!nodeText) continue;
                                    const index = nodeText.indexOf(snippet);
                                    if (index !== -1 && index < bestScore) {
                                        bestScore = index;
                                        bestMatch = node;
                                    } else if (!bestMatch && nodeText.startsWith(snippet.split(' ')[0])) {
                                        bestMatch = node;
                                    }
                                }
                                if (bestMatch) {
                                    return bestMatch;
                                }
                            }
                        }
                    }

                    return null;
                }

                

                    const info = anchor.virtualScroller;
                    const containerInfo = info.container || {};
                    const located = locateVirtualContainer(containerInfo);
                    if (located.logs && located.logs.length) {
                        for (let i = 0; i < located.logs.length; i++) {
                            resultLogs.push(located.logs[i]);
                        }
                    }
                    const container = located.element;
                    if (!container) {
                        resultLogs.push('Virtual container element not found');
                        return { element: null, logs: resultLogs, containerPath: containerInfo.domPath || null };
                    }

                    const maxScroll = Math.max(0, (container.scrollHeight || 0) - (container.clientHeight || 0));
                    let targetScrollTop = typeof containerInfo.scrollTop === 'number' ? containerInfo.scrollTop : container.scrollTop;
                    if (typeof containerInfo.scrollPercent === 'number' && isFinite(containerInfo.scrollPercent) && maxScroll > 0) {
                        targetScrollTop = Math.max(0, Math.min(maxScroll, containerInfo.scrollPercent * maxScroll));
                    }
                    targetScrollTop = Math.max(0, Math.min(maxScroll, targetScrollTop));

                    const beforeScroll = container.scrollTop;
                    container.scrollTop = targetScrollTop;
                    if (typeof containerInfo.scrollLeft === 'number') {
                        container.scrollLeft = containerInfo.scrollLeft;
                    }
                    container.dispatchEvent(new Event('scroll', { bubbles: true }));
                    const waitStart = Date.now();
                    while (Date.now() - waitStart < 32) {}
                    container.dispatchEvent(new Event('scroll', { bubbles: true }));

                    resultLogs.push('Virtual container scrollTop ' + beforeScroll.toFixed(1) + ' -> ' + container.scrollTop.toFixed(1));

                    const focusElement = findVirtualFocusElement(container, info);
                    if (!focusElement) {
                        resultLogs.push('Virtual focus element not found after scroll');
                        return { element: null, logs: resultLogs, containerPath: containerInfo.domPath || null };
                    }

                    return {
                        element: focusElement,
                        logs: resultLogs,
                        containerPath: containerInfo.domPath || null,
                        method: 'virtual_scroller',
                        confidence: Math.min(90, Math.max(60, info.confidence || 60))
                    };
                }

                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const infiniteScrollAnchorData = \(anchorDataJSON);
                
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
                const virtualScrollerAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'virtualScroller' && anchor.virtualScroller;
                });
                
                logs.push('Vue Component 앵커: ' + vueComponentAnchors.length + '개');
                logs.push('Content Hash 앵커: ' + contentHashAnchors.length + '개');
                logs.push('Virtual Index 앵커: ' + virtualIndexAnchors.length + '개');
                logs.push('Virtual Scroller 앵커: ' + virtualScrollerAnchors.length + '개');
                
                let foundElement = null;
                let matchedAnchor = null;
                let matchMethod = '';
                let confidence = 0;

                if (!foundElement && virtualScrollerAnchors.length > 0) {
                    for (let i = 0; i < virtualScrollerAnchors.length && !foundElement; i++) {
                        const anchor = virtualScrollerAnchors[i];
                        const restoreResult = restoreVirtualScrollerAnchor(anchor);
                        if (restoreResult.logs && restoreResult.logs.length) {
                            for (let j = 0; j < restoreResult.logs.length; j++) {
                                logs.push('[Virtual] ' + restoreResult.logs[j]);
                            }
                        }
                        if (restoreResult.element) {
                            foundElement = restoreResult.element;
                            matchedAnchor = anchor;
                            matchMethod = restoreResult.method || 'virtual_scroller';
                            confidence = restoreResult.confidence || Math.min(90, Math.max(60, (anchor.virtualScroller && anchor.virtualScroller.confidence) || 60));
                            if (restoreResult.containerPath) {
                                logs.push('[Virtual] Container: ' + restoreResult.containerPath);
                            }
                            logs.push('Virtual Scroller 앵커 매칭 성공');
                            break;
                        }
                    }
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
                                // 컴포넌트 이름과 인덱스 매칭
                                if (vueComp.name && element.className.includes(vueComp.name)) {
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
                                if (elementText.includes(searchText)) {
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
                    // 🎯 **수정: scrollIntoView 대신 직접 계산 + 헤더 보정**
                    const ROOT = getROOT();
                    const rect = foundElement.getBoundingClientRect();
                    const absY = ROOT.scrollTop + rect.top;
                    const headerHeight = fixedHeaderHeight();
                    const finalY = Math.max(0, absY - headerHeight);
                    
                    // 오프셋 보정
                    let adjustedY = finalY;
                    if (matchedAnchor.offsetFromTop) {
                        adjustedY = Math.max(0, finalY - matchedAnchor.offsetFromTop);
                    }
                    
                    // 🎯 **단일 스크롤러로 정밀 이동**
                    ROOT.scrollTop = adjustedY;
                    
                    const actualX = ROOT.scrollLeft || 0;
                    const actualY = ROOT.scrollTop || 0;
                    const diffX = Math.abs(actualX - targetX);
                    const diffY = Math.abs(actualY - targetY);
                    
                    logs.push('앵커 복원 후 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                    logs.push('목표와의 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                    logs.push('매칭 신뢰도: ' + confidence + '%');
                    logs.push('헤더 보정: ' + headerHeight.toFixed(0) + 'px');
                    
                    return {
                        success: diffY <= 100, // 무한스크롤은 100px 허용 오차
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
                \(generateCommonUtilityScript())
                
                const logs = [];

                function cssEscapeCompat(value) {
                    if (value === null || value === undefined) return '';
                    if (window.CSS && CSS.escape) {
                        return CSS.escape(value);
                    }
                    return String(value).replace(/([ !"#$%&'()*+,./:;<=>?@[\]^`{|}~])/g, function(match) { return String.fromCharCode(92) + match; });
                }

                function datasetKeyToAttr(key) {
                    return 'data-' + String(key || '').replace(/([A-Z])/g, '-$1').toLowerCase();
                }

                function locateVirtualContainer(containerInfo) {
                    const resultLogs = [];
                    if (!containerInfo) {
                        resultLogs.push('Virtual container info missing');
                        return { element: null, logs: resultLogs };
                    }

                    let container = null;
                    if (containerInfo.domPath) {
                        try {
                            container = document.querySelector(containerInfo.domPath);
                            if (container) {
                                resultLogs.push('Matched container by domPath');
                                return { element: container, logs: resultLogs };
                            } else {
                                resultLogs.push('DomPath not found: ' + containerInfo.domPath);
                            }
                        } catch(e) {
                            resultLogs.push('DomPath lookup error: ' + e.message);
                        }
                    }

                    if (!container && containerInfo.id) {
                        container = document.getElementById(containerInfo.id);
                        if (container) {
                            resultLogs.push('Matched container by id #' + containerInfo.id);
                            return { element: container, logs: resultLogs };
                        } else {
                            resultLogs.push('ID not found: #' + containerInfo.id);
                        }
                    }

                    if (!container && containerInfo.classList && containerInfo.classList.length) {
                        for (let i = 0; i < containerInfo.classList.length; i++) {
                            const cls = containerInfo.classList[i];
                            try {
                                const candidate = document.querySelector('.' + cssEscapeCompat(cls));
                                if (candidate) {
                                    container = candidate;
                                    resultLogs.push('Matched container by class .' + cls);
                                    break;
                                }
                            } catch(e) {}
                        }
                    }

                    if (!container && containerInfo.dataset) {
                        const keys = Object.keys(containerInfo.dataset);
                        for (let i = 0; i < keys.length; i++) {
                            const attrName = datasetKeyToAttr(keys[i]);
                            const value = containerInfo.dataset[keys[i]];
                            if (!value) continue;
                            try {
                                const selector = '[' + attrName + '="' + cssEscapeCompat(value) + '"]';
                                const candidate = document.querySelector(selector);
                                if (candidate) {
                                    container = candidate;
                                    resultLogs.push('Matched container by dataset ' + selector);
                                    break;
                                }
                            } catch(e) {}
                        }
                    }

                    if (!container) {
                        const fallbackCandidates = Array.from(document.querySelectorAll('[class*="virtual"], [data-virtualized], [data-virtual], [data-virtual-scroll], [data-windowed]')).filter(function(el) {
                            if (!el || !el.getBoundingClientRect) return false;
                            const rect = el.getBoundingClientRect();
                            return rect.height >= 60 && Math.abs((el.scrollHeight || 0) - (el.clientHeight || 0)) > 20;
                        });
                        if (fallbackCandidates.length > 0) {
                            container = fallbackCandidates[0];
                            resultLogs.push('Fallback virtual container selected by heuristics');
                        } else {
                            resultLogs.push('Virtual container fallback search failed');
                        }
                    }

                    return { element: container, logs: resultLogs };
                }

                function trySelectorsInContainer(container, selectors, triedSelectors) {
                    if (!container || !selectors) return null;
                    triedSelectors = triedSelectors || new Set();
                    for (let i = 0; i < selectors.length; i++) {
                        const selector = selectors[i];
                        if (!selector || triedSelectors.has(selector)) continue;
                        triedSelectors.add(selector);
                        try {
                            const found = container.querySelector(selector);
                            if (found) {
                                return found;
                            }
                        } catch(e) {}
                    }
                    return null;
                }

                function buildSelectorsFromDescriptor(descriptor) {
                    const selectors = [];
                    if (!descriptor) return selectors;
                    if (descriptor.attributes) {
                        const keys = Object.keys(descriptor.attributes);
                        for (let i = 0; i < keys.length; i++) {
                            const attr = keys[i];
                            const value = descriptor.attributes[attr];
                            if (value === undefined || value === null || value === '') continue;
                            const base = '[' + attr + '="' + cssEscapeCompat(value) + '"]';
                            selectors.push(base);
                            if (descriptor.tagName) {
                                selectors.push(descriptor.tagName + base);
                            }
                        }
                    }
                    if (descriptor.aria) {
                        const keys = Object.keys(descriptor.aria);
                        for (let i = 0; i < keys.length; i++) {
                            const attr = keys[i];
                            const value = descriptor.aria[attr];
                            if (value === undefined || value === null || value === '') continue;
                            const base = '[' + attr + '="' + cssEscapeCompat(value) + '"]';
                            selectors.push(base);
                            if (descriptor.tagName) {
                                selectors.push(descriptor.tagName + base);
                            }
                        }
                    }
                    return selectors;
                }

                function findVirtualFocusElement(container, anchorInfo) {
                    if (!container || !anchorInfo) return null;
                    const triedSelectors = new Set();
                    const tryQueue = [];
                    if (anchorInfo.focusItem) {
                        tryQueue.push(anchorInfo.focusItem);
                    }
                    if (anchorInfo.visibleItems && anchorInfo.visibleItems.length) {
                        for (let i = 0; i < Math.min(anchorInfo.visibleItems.length, 6); i++) {
                            tryQueue.push(anchorInfo.visibleItems[i]);
                        }
                    }

                    for (let i = 0; i < tryQueue.length; i++) {
                        const descriptor = tryQueue[i];
                        if (!descriptor) continue;

                        if (descriptor.domPath) {
                            try {
                                const absoluteMatch = document.querySelector(descriptor.domPath);
                                if (absoluteMatch && container.contains(absoluteMatch)) {
                                    return absoluteMatch;
                                }
                            } catch(e) {}
                        }

                        const selectors = buildSelectorsFromDescriptor(descriptor);
                        const found = trySelectorsInContainer(container, selectors, triedSelectors);
                        if (found) {
                            return found;
                        }

                        if (descriptor.text) {
                            const snippet = descriptor.text.trim().toLowerCase().slice(0, 40);
                            if (snippet.length >= 3) {
                                const nodes = Array.from(container.querySelectorAll(descriptor.tagName || '[data-index],[data-key],div,li'));
                                let bestMatch = null;
                                let bestScore = Infinity;
                                for (let j = 0; j < nodes.length && j < 80; j++) {
                                    const node = nodes[j];
                                    const nodeText = (node.textContent || '').trim().toLowerCase();
                                    if (!nodeText) continue;
                                    const index = nodeText.indexOf(snippet);
                                    if (index !== -1 && index < bestScore) {
                                        bestScore = index;
                                        bestMatch = node;
                                    } else if (!bestMatch && nodeText.startsWith(snippet.split(' ')[0])) {
                                        bestMatch = node;
                                    }
                                }
                                if (bestMatch) {
                                    return bestMatch;
                                }
                            }
                        }
                    }

                    return null;
                }

                

                    const info = anchor.virtualScroller;
                    const containerInfo = info.container || {};
                    const located = locateVirtualContainer(containerInfo);
                    if (located.logs && located.logs.length) {
                        for (let i = 0; i < located.logs.length; i++) {
                            resultLogs.push(located.logs[i]);
                        }
                    }
                    const container = located.element;
                    if (!container) {
                        resultLogs.push('Virtual container element not found');
                        return { element: null, logs: resultLogs, containerPath: containerInfo.domPath || null };
                    }

                    const maxScroll = Math.max(0, (container.scrollHeight || 0) - (container.clientHeight || 0));
                    let targetScrollTop = typeof containerInfo.scrollTop === 'number' ? containerInfo.scrollTop : container.scrollTop;
                    if (typeof containerInfo.scrollPercent === 'number' && isFinite(containerInfo.scrollPercent) && maxScroll > 0) {
                        targetScrollTop = Math.max(0, Math.min(maxScroll, containerInfo.scrollPercent * maxScroll));
                    }
                    targetScrollTop = Math.max(0, Math.min(maxScroll, targetScrollTop));

                    const beforeScroll = container.scrollTop;
                    container.scrollTop = targetScrollTop;
                    if (typeof containerInfo.scrollLeft === 'number') {
                        container.scrollLeft = containerInfo.scrollLeft;
                    }
                    container.dispatchEvent(new Event('scroll', { bubbles: true }));
                    const waitStart = Date.now();
                    while (Date.now() - waitStart < 32) {}
                    container.dispatchEvent(new Event('scroll', { bubbles: true }));

                    resultLogs.push('Virtual container scrollTop ' + beforeScroll.toFixed(1) + ' -> ' + container.scrollTop.toFixed(1));

                    const focusElement = findVirtualFocusElement(container, info);
                    if (!focusElement) {
                        resultLogs.push('Virtual focus element not found after scroll');
                        return { element: null, logs: resultLogs, containerPath: containerInfo.domPath || null };
                    }

                    return {
                        element: focusElement,
                        logs: resultLogs,
                        containerPath: containerInfo.domPath || null,
                        method: 'virtual_scroller',
                        confidence: Math.min(90, Math.max(60, info.confidence || 60))
                    };
                }

                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const tolerance = 30;
                
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
                    
                    // 🎯 **수정: 단일 스크롤러로 정밀 보정**
                    ROOT.scrollLeft = targetX;
                    ROOT.scrollTop = targetY;
                    
                    correctionApplied = true;
                    
                    // 보정 후 위치 재측정
                    currentX = ROOT.scrollLeft || 0;
                    currentY = ROOT.scrollTop || 0;
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
        _ = domSemaphore.wait(timeout: .now() + 5.0) // 🔧 기존 캡처 타임아웃 유지 (1초)
        
        // 3. ✅ **수정: 무한스크롤 전용 앵커 JS 상태 캡처** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateInfiniteScrollAnchorCaptureScript() // 🚀 **수정된: 무한스크롤 전용 앵커 캡처**
            
            webView.evaluateJavaScript(jsScript) { result, error in
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
    
    // 🚀 **수정: JavaScript 앵커 캡처 스크립트 개선 (단일 스크롤러 적용)**
    private func generateInfiniteScrollAnchorCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 무한스크롤 전용 앵커 캡처 시작');
                
                // 🎯 **단일 스크롤러 유틸리티 함수들**
                function getROOT() { 
                    return document.scrollingElement || document.documentElement; 
                }
                
                // 📊 **상세 로그 수집**
                const detailedLogs = [];
                const pageAnalysis = {};
                
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
                
                // 🚀 **실제 보이는 영역 계산**
                const actualViewportRect = {
                    top: scrollY,
                    left: scrollX,
                    bottom: scrollY + viewportHeight,
                    right: scrollX + viewportWidth,
                    width: viewportWidth,
                    height: viewportHeight
                };
                
                detailedLogs.push('실제 보이는 영역: top=' + actualViewportRect.top.toFixed(1) + ', bottom=' + actualViewportRect.bottom.toFixed(1));
                
                // 🚀 **요소 가시성 정확 판단 함수**
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
                
                // 🧹 **의미있는 텍스트 필터링 함수**
                function isQualityText(text) {
                    if (!text || typeof text !== 'string') return false;
                    
                    const cleanText = text.trim();
                    if (cleanText.length < 10) return false; // 무한스크롤용 최소 길이 증가
                    
                    const meaninglessPatterns = [
                        /^(투표는|표시되지|않습니다|네트워크|문제로|연결되지|잠시|후에|다시|시도)/,
                        /^(로딩|loading|wait|please|기다려|잠시만)/i,
                        /^(오류|에러|error|fail|실패|죄송|sorry)/i,
                        /^(확인|ok|yes|no|취소|cancel|닫기|close)/i,
                        /^(더보기|more|load|next|이전|prev|previous)/i,
                        /^(클릭|click|tap|터치|touch|선택)/i,
                        /^(답글|댓글|reply|comment|쓰기|작성)/i,
                        /^[\\s\\.\\-_=+]{2,}$/,
                        /^[0-9\\s\\.\\/\\-:]{3,}$/,
                        /^(am|pm|오전|오후|시|분|초)$/i,
                    ];
                    
                    for (let i = 0; i < meaninglessPatterns.length; i++) {
                        if (meaninglessPatterns[i].test(cleanText)) {
                            return false;
                        }
                    }
                    
                    return true;
                }
                
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
                
                // 🚀 **수정된: Vue 컴포넌트 요소 수집**
                function collectVueComponentElements() {
                    const vueElements = [];
                    
                    // 1. 모든 요소를 순회하면서 data-v-* 속성을 가진 요소 찾기
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
                    
                    detailedLogs.push('Vue.js 컴포넌트 수집: ' + vueElements.length + '개');
                    return vueElements;
                }
                
                // -- Common util: CSS escape for virtual scroller detection
                function cssEscapeCompat(value) {
                    if (value === null || value === undefined) return '';
                    if (window.CSS && CSS.escape) {
                        return CSS.escape(value);
                    }
                    return String(value).replace(/([ !"#$%&'()*+,./:;<=>?@[\]^`{|}~])/g, function(match) { return String.fromCharCode(92) + match; });
                }

                // -- DOM path builder (lightweight)
                function buildDomPath(element, maxDepth) {
                    if (!element) return '';
                    maxDepth = maxDepth || 8;
                    const segments = [];
                    let current = element;
                    let depth = 0;

                    while (current && current.nodeType === 1 && depth < maxDepth) {
                        let selector = current.tagName ? current.tagName.toLowerCase() : 'unknown';

                        if (current.id) {
                            selector += '#' + cssEscapeCompat(current.id);
                            segments.unshift(selector);
                            break;
                        }

                        if (current.classList && current.classList.length > 0) {
                            selector += '.' + cssEscapeCompat(Array.from(current.classList)[0]);
                        } else {
                            const attrCandidates = ['data-key', 'data-index', 'data-item-index', 'data-id'];
                            for (let i = 0; i < attrCandidates.length; i++) {
                                const attrName = attrCandidates[i];
                                if (current.hasAttribute && current.hasAttribute(attrName)) {
                                    selector += '[' + attrName + "=" + '"' + cssEscapeCompat(current.getAttribute(attrName)) + '"' + ']';
                                    break;
                                }
                            }
                        }

                        const parent = current.parentElement;
                        if (parent) {
                            const siblings = Array.from(parent.children).filter(function(child) {
                                return child.tagName === current.tagName;
                            });
                            if (siblings.length > 1) {
                                const position = siblings.indexOf(current) + 1;
                                selector += ':nth-of-type(' + position + ')';
                            }
                        }

                        segments.unshift(selector);
                        current = parent;
                        depth++;
                    }

                    return segments.join(' > ');
                }

                // -- Simplified attribute extractor
                function extractAttributeMap(element, attributes) {
                    const result = {};
                    if (!element || !attributes) return result;
                    for (let i = 0; i < attributes.length; i++) {
                        const attr = attributes[i];
                        if (element.hasAttribute && element.hasAttribute(attr)) {
                            result[attr] = element.getAttribute(attr);
                        }
                    }
                    return result;
                }

                // -- Virtual scroller detection and metadata capture
                function detectVirtualScrollContainers() {
                    const detectionLogs = [];
                    const containers = [];
                    const anchors = [];

                    const indexAttributes = ['data-index', 'data-key', 'data-id', 'data-item-index', 'data-item-id', 'data-rowindex', 'data-row-index', 'data-virtual-index', 'data-virtual-key', 'data-offset-index', 'data-pos', 'data-idx'];
                    const ariaAttributes = ['aria-rowindex', 'aria-posinset'];
                    const containerAttrHints = ['data-virtualized', 'data-virtual', 'data-virtual-scroll', 'data-virtual-scroller', 'data-recycle-scroller', 'data-windowed'];
                    const containerClassHints = ['virtual', 'Virtual', 'virtualized', 'virtual-scroll', 'virtual-scroller', 'ReactVirtualized', 'ReactWindow', 'react-window', 'RecycleList', 'RecycleScroller', 'cdk-virtual-scroll-viewport', 'MuiDataGrid-virtualScroller', 'ms-List-scrollableContainer'];
                    const itemSelector = indexAttributes.map(function(attr) { return '[' + attr + ']'; }).join(',') + ',[aria-rowindex],[aria-posinset],[role="row"],[role="option"],[data-testid*="virtual"],[data-testid*="Virtual"]';

                    const candidateSet = new Set();

                    for (let i = 0; i < containerAttrHints.length; i++) {
                        const attr = containerAttrHints[i];
                        document.querySelectorAll('[' + attr + ']').forEach(function(el) {
                            candidateSet.add(el);
                        });
                    }
                    for (let i = 0; i < containerClassHints.length; i++) {
                        const cls = containerClassHints[i];
                        document.querySelectorAll('[class*="' + cls + '"]').forEach(function(el) {
                            candidateSet.add(el);
                        });
                    }

                    const candidateItems = Array.from(document.querySelectorAll(itemSelector)).slice(0, 400);
                    for (let i = 0; i < candidateItems.length; i++) {
                        let parent = candidateItems[i].parentElement;
                        let depth = 0;
                        while (parent && depth < 6) {
                            const style = window.getComputedStyle(parent);
                            const overflowY = style.overflowY || style.overflow;
                            if (overflowY === 'auto' || overflowY === 'scroll') {
                                candidateSet.add(parent);
                                break;
                            }
                            parent = parent.parentElement;
                            depth++;
                        }
                    }

                    const candidates = Array.from(candidateSet).filter(function(el) {
                        if (!el || el === document.body || el === document.documentElement) return false;
                        const rect = el.getBoundingClientRect();
                        return rect.height >= 80 && rect.width >= 80;
                    }).slice(0, 20);

                    detectionLogs.push('[Virtual Scroll] candidates=' + candidates.length);

                    const MAX_VISIBLE_ITEMS = 24;

                    for (let i = 0; i < candidates.length; i++) {
                        const container = candidates[i];
                        const style = window.getComputedStyle(container);
                        const rect = container.getBoundingClientRect();
                        const items = Array.from(container.querySelectorAll(itemSelector)).slice(0, 120);
                        if (items.length === 0) continue;

                        let hintScore = 0;
                        for (let j = 0; j < containerAttrHints.length; j++) {
                            if (container.hasAttribute && container.hasAttribute(containerAttrHints[j])) {
                                hintScore += 20;
                            }
                        }
                        for (let j = 0; j < containerClassHints.length; j++) {
                            if ((container.className || '').includes(containerClassHints[j])) {
                                hintScore += 12;
                            }
                        }
                        if (container.dataset) {
                            const keys = Object.keys(container.dataset);
                            if (keys.some(function(key) { return key.toLowerCase().includes('virtual'); })) {
                                hintScore += 20;
                            }
                        }

                        const visibleItems = [];
                        let minIndex = Number.POSITIVE_INFINITY;
                        let maxIndex = Number.NEGATIVE_INFINITY;
                        const distinctIndices = new Set();
                        let hasIndexGap = false;

                        for (let j = 0; j < items.length; j++) {
                            const item = items[j];
                            const itemRect = item.getBoundingClientRect();
                            const visible = itemRect.bottom > rect.top && itemRect.top < rect.bottom;
                            if (!visible) continue;

                            const attributeMap = extractAttributeMap(item, indexAttributes);
                            let itemHasIndex = false;
                            Object.keys(attributeMap).forEach(function(attr) {
                                const rawValue = attributeMap[attr];
                                if (rawValue !== null && rawValue !== undefined) {
                                    const num = parseInt(rawValue, 10);
                                    if (!isNaN(num)) {
                                        itemHasIndex = true;
                                        minIndex = Math.min(minIndex, num);
                                        maxIndex = Math.max(maxIndex, num);
                                        distinctIndices.add(num);
                                    }
                                }
                            });

                            const ariaMap = {};
                            for (let k = 0; k < ariaAttributes.length; k++) {
                                const ariaAttr = ariaAttributes[k];
                                if (item.hasAttribute && item.hasAttribute(ariaAttr)) {
                                    const value = item.getAttribute(ariaAttr);
                                    ariaMap[ariaAttr] = value;
                                    const num = parseInt(value, 10);
                                    if (!isNaN(num)) {
                                        itemHasIndex = true;
                                        minIndex = Math.min(minIndex, num);
                                        maxIndex = Math.max(maxIndex, num);
                                        distinctIndices.add(num);
                                    }
                                }
                            }

                            if (itemHasIndex) {
                                hasIndexGap = true;
                            }

                            const text = (item.textContent || '').trim().replace(/\\s+/g, ' ').substring(0, 120);
                            const relativeTop = container.scrollTop + (itemRect.top - rect.top);
                            const transform = item.style.transform || window.getComputedStyle(item).transform || '';

                            visibleItems.push({
                                tagName: item.tagName ? item.tagName.toLowerCase() : 'div',
                                domPath: buildDomPath(item, 6),
                                attributes: attributeMap,
                                aria: ariaMap,
                                text: text,
                                relativeTop: relativeTop,
                                height: itemRect.height,
                                transform: transform
                            });

                            if (visibleItems.length >= MAX_VISIBLE_ITEMS) break;
                        }

                        if (visibleItems.length === 0) continue;

                        const indexSpan = (maxIndex < Number.POSITIVE_INFINITY && minIndex > Number.NEGATIVE_INFINITY) ? (maxIndex - minIndex) : 0;
                        let indexScore = 0;
                        if (distinctIndices.size >= Math.max(3, Math.floor(visibleItems.length * 0.6))) {
                            indexScore += 25;
                        }
                        if (indexSpan >= visibleItems.length) {
                            indexScore += 15;
                        }
                        if (hasIndexGap) {
                            indexScore += 10;
                        }

                        let scrollScore = 0;
                        if (container.scrollHeight > container.clientHeight * 1.2) {
                            scrollScore += 10;
                        }
                        if (container.scrollHeight > container.clientHeight * 2.5) {
                            scrollScore += 10;
                        }
                        if ((container.style.transform || '').includes('translate')) {
                            scrollScore += 5;
                        }

                        const confidence = Math.min(100, hintScore + indexScore + scrollScore);
                        detectionLogs.push('[Virtual Scroll] candidate #' + (i + 1) + ' score=' + confidence + ' (hint=' + hintScore + ', index=' + indexScore + ', scroll=' + scrollScore + ')');

                        if (confidence < 45) continue;

                        const focusCenter = container.scrollTop + (container.clientHeight / 2);
                        let focusItem = visibleItems[0];
                        let focusDistance = Infinity;
                        for (let j = 0; j < visibleItems.length; j++) {
                            const item = visibleItems[j];
                            const center = item.relativeTop + (item.height / 2);
                            const distance = Math.abs(center - focusCenter);
                            if (distance < focusDistance) {
                                focusDistance = distance;
                                focusItem = item;
                            }
                        }

                        const containerDataset = {};
                        if (container.dataset) {
                            Object.keys(container.dataset).slice(0, 10).forEach(function(key) {
                                containerDataset[key] = container.dataset[key];
                            });
                        }

                        const containerMeta = {
                            domPath: buildDomPath(container, 6),
                            id: container.id || null,
                            classList: Array.from(container.classList || []).slice(0, 8),
                            dataset: containerDataset,
                            confidence: confidence,
                            scrollTop: container.scrollTop,
                            scrollLeft: container.scrollLeft,
                            scrollHeight: container.scrollHeight,
                            scrollWidth: container.scrollWidth,
                            clientHeight: container.clientHeight,
                            clientWidth: container.clientWidth,
                            scrollPercent: container.scrollHeight > container.clientHeight ? (container.scrollTop / Math.max(1, container.scrollHeight - container.clientHeight)) : 0,
                            paddingTop: parseFloat(style.paddingTop) || 0,
                            paddingBottom: parseFloat(style.paddingBottom) || 0
                        };

                        containers.push(containerMeta);

                        const anchorIndex = anchors.length;
                        anchors.push({
                            anchorType: 'virtualScroller',
                            virtualScroller: {
                                version: 1,
                                confidence: confidence,
                                container: containerMeta,
                                focusItem: focusItem,
                                visibleItems: visibleItems.slice(0, 8),
                                stats: {
                                    totalItemsScanned: items.length,
                                    visibleItems: visibleItems.length,
                                    distinctIndexCount: distinctIndices.size,
                                    indexSpan: indexSpan
                                }
                            },
                            absolutePosition: { top: scrollY + rect.top, left: scrollX + rect.left },
                            viewportPosition: { top: rect.top, left: rect.left },
                            offsetFromTop: 0,
                            size: { width: rect.width, height: rect.height },
                            qualityScore: Math.min(95, Math.max(60, confidence)),
                            anchorIndex: anchorIndex,
                            captureTimestamp: Date.now(),
                            isVisible: true,
                            visibilityReason: 'virtual_scroller_detected'
                        });
                    }

                    return { containers: containers, anchors: anchors, logs: detectionLogs };
                }

                // 🚀 **핵심: 무한스크롤 전용 앵커 수집**
                function collectInfiniteScrollAnchors() {
                    const anchors = [];
                    const anchorStats = {
                        totalCandidates: 0,
                        visibilityChecked: 0,
                        actuallyVisible: 0,
                        vueComponentAnchors: 0,
                        contentHashAnchors: 0,
                        virtualIndexAnchors: 0,
                        virtualScrollerAnchors: 0,
                        structuralPathAnchors: 0,
                        intersectionAnchors: 0,
                        finalAnchors: 0,
                        virtualScrollersDetected: 0
                    };
                    
                    detailedLogs.push('🚀 무한스크롤 전용 앵커 수집 시작');
                    
                    // 🚀 **1. Vue.js 컴포넌트 요소 우선 수집**
                    const vueComponentElements = collectVueComponentElements();
                    anchorStats.totalCandidates += vueComponentElements.length;
                    anchorStats.actuallyVisible += vueComponentElements.length;
                    
                    // 🚀 **2. 일반 콘텐츠 요소 수집 (무한스크롤용) - 수정된 선택자**
                    const contentSelectors = [
                        'li', 'tr', 'td', '.item', '.list-item', '.card', '.post', '.article',
                        '.comment', '.reply', '.feed', '.thread', '.message', '.product', 
                        '.news', '.media', '.content-item', '[class*="item"]', 
                        '[class*="post"]', '[class*="card"]', '[data-testid]', 
                        '[data-id]', '[data-key]', '[data-item-id]',
                        // 일반적인 리스트 아이템 선택자 추가
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
                            // selector 오류 무시
                        }
                    }
                    
                    anchorStats.totalCandidates += contentElements.length;
                    
                    // 중복 제거 및 가시성 필터링
                    const uniqueContentElements = [];
                    const processedElements = new Set();
                    
                    for (let i = 0; i < contentElements.length; i++) {
                        const element = contentElements[i];
                        if (!processedElements.has(element)) {
                            processedElements.add(element);
                            
                            const visibilityResult = isElementActuallyVisible(element, false); // 🔧 덜 엄격한 가시성 검사
                            anchorStats.visibilityChecked++;
                            
                            if (visibilityResult.visible) {
                                const elementText = (element.textContent || '').trim();
                                if (elementText.length > 5) { // 🔧 텍스트 길이 조건 완화
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
                    
                    detailedLogs.push('일반 콘텐츠 후보: ' + contentElements.length + '개, 유효: ' + uniqueContentElements.length + '개');
                    
                    // 🚀 **3. 뷰포트 중심 기준으로 상위 20개씩 선택 (증가)**
                    const viewportCenterY = scrollY + (viewportHeight / 2);
                    const viewportCenterX = scrollX + (viewportWidth / 2);
                    
                    // Vue 컴포넌트 정렬 및 선택
                    vueComponentElements.sort(function(a, b) {
                        const aTop = scrollY + a.rect.top;
                        const bTop = scrollY + b.rect.top;
                        const aDistance = Math.abs(aTop + (a.rect.height / 2) - viewportCenterY);
                        const bDistance = Math.abs(bTop + (b.rect.height / 2) - viewportCenterY);
                        return aDistance - bDistance;
                    });
                    
                    // 일반 콘텐츠 정렬 및 선택
                    uniqueContentElements.sort(function(a, b) {
                        const aTop = scrollY + a.rect.top;
                        const bTop = scrollY + b.rect.top;
                        const aDistance = Math.abs(aTop + (a.rect.height / 2) - viewportCenterY);
                        const bDistance = Math.abs(bTop + (b.rect.height / 2) - viewportCenterY);
                        return aDistance - bDistance;
                    });
                    
                    const selectedVueElements = vueComponentElements.slice(0, 20); // 🔧 20개로 증가
                    const selectedContentElements = uniqueContentElements.slice(0, 20); // 🔧 20개로 증가
                    
                    detailedLogs.push('뷰포트 중심 기준 선택: Vue=' + selectedVueElements.length + '개, Content=' + selectedContentElements.length + '개');
                    
                    // 🚀 **4. Vue Component 앵커 생성**
                    for (let i = 0; i < selectedVueElements.length; i++) {
                        try {
                            const anchor = createVueComponentAnchor(selectedVueElements[i], i);
                            if (anchor) {
                                anchors.push(anchor);
                                anchorStats.vueComponentAnchors++;
                            }
                        } catch(e) {
                            console.warn('Vue 앵커[' + i + '] 생성 실패:', e);
                        }
                    }
                    
                    // 🚀 **5. Content Hash + Virtual Index + Structural Path 앵커 생성**
                    for (let i = 0; i < selectedContentElements.length; i++) {
                        try {
                            // Content Hash 앵커
                            const hashAnchor = createContentHashAnchor(selectedContentElements[i], i);
                            if (hashAnchor) {
                                anchors.push(hashAnchor);
                                anchorStats.contentHashAnchors++;
                            }
                            
                            // Virtual Index 앵커
                            const indexAnchor = createVirtualIndexAnchor(selectedContentElements[i], i);
                            if (indexAnchor) {
                                anchors.push(indexAnchor);
                                anchorStats.virtualIndexAnchors++;
                            }
                            
                            // Structural Path 앵커 (보조) - 상위 10개만
                            if (i < 10) {
                                const pathAnchor = createStructuralPathAnchor(selectedContentElements[i], i);
                                if (pathAnchor) {
                                    anchors.push(pathAnchor);
                                    anchorStats.structuralPathAnchors++;
                                }
                            }
                            
                        } catch(e) {
                            console.warn('콘텐츠 앵커[' + i + '] 생성 실패:', e);
                        }
                    }
                    
                    const virtualDetection = detectVirtualScrollContainers();
                    if (virtualDetection.logs && virtualDetection.logs.length) {
                        for (let i = 0; i < virtualDetection.logs.length; i++) {
                            detailedLogs.push(virtualDetection.logs[i]);
                        }
                    }
                    if (virtualDetection.containers) {
                        anchorStats.virtualScrollersDetected = virtualDetection.containers.length;
                    }
                    if (virtualDetection.anchors && virtualDetection.anchors.length) {
                        for (let i = 0; i < virtualDetection.anchors.length; i++) {
                            const virtualAnchor = virtualDetection.anchors[i];
                            virtualAnchor.anchorIndex = anchors.length;
                            anchors.push(virtualAnchor);
                            anchorStats.virtualScrollerAnchors++;
                        }
                    }

                    anchorStats.finalAnchors = anchors.length;
                    
                    detailedLogs.push('무한스크롤 앵커 생성 완료: ' + anchors.length + '개');
                    console.log('🚀 무한스크롤 앵커 수집 완료:', anchors.length, '개');
                    
                    // 🔧 **수정: stats를 별도 객체로 반환**
                    return {
                        anchors: anchors,
                        stats: anchorStats,
                        virtualScrollers: virtualDetection ? virtualDetection.containers : []
                    };
                }
                
                // 🚀 **수정된: Vue Component 앵커 생성**
                function createVueComponentAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        const dataVAttr = elementData.dataVAttr;
                        
                        // 🎯 **수정: 단일 스크롤러 기준으로 계산**
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // Vue 컴포넌트 정보 추출
                        const vueComponent = {
                            name: 'unknown',
                            dataV: dataVAttr,
                            props: {},
                            index: index
                        };
                        
                        // 클래스명에서 컴포넌트 이름 추출
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
                        
                        // 부모 요소에서 인덱스 정보
                        if (element.parentElement) {
                            const siblingIndex = Array.from(element.parentElement.children).indexOf(element);
                            vueComponent.index = siblingIndex;
                        }
                        
                        const qualityScore = 85; // Vue 컴포넌트는 기본 85점
                        
                        return {
                            anchorType: 'vueComponent',
                            vueComponent: vueComponent,
                            
                            // 위치 정보
                            absolutePosition: { top: absoluteTop, left: absoluteLeft },
                            viewportPosition: { top: rect.top, left: rect.left },
                            offsetFromTop: offsetFromTop,
                            size: { width: rect.width, height: rect.height },
                            
                            // 메타 정보
                            textContent: textContent.substring(0, 100),
                            qualityScore: qualityScore,
                            anchorIndex: index,
                            captureTimestamp: Date.now(),
                            isVisible: true,
                            visibilityReason: 'vue_component_visible'
                        };
                        
                    } catch(e) {
                        console.error('Vue 앵커[' + index + '] 생성 실패:', e);
                        return null;
                    }
                }
                
                // 🚀 **Content Hash 앵커 생성**
                function createContentHashAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        
                        // 🎯 **수정: 단일 스크롤러 기준으로 계산**
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // 콘텐츠 해시 생성
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
                        console.error('Content Hash 앵커[' + index + '] 생성 실패:', e);
                        return null;
                    }
                }
                
                // 🚀 **Virtual Index 앵커 생성**
                function createVirtualIndexAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        
                        // 🎯 **수정: 단일 스크롤러 기준으로 계산**
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // 가상 인덱스 정보
                        const virtualIndex = {
                            listIndex: index,
                            pageIndex: Math.floor(index / 10), // 10개씩 페이지 단위
                            offsetInPage: absoluteTop,
                            estimatedTotal: document.querySelectorAll('li, .item, .list-item, .ListItem').length
                        };
                        
                        const qualityScore = 70; // Virtual Index는 70점
                        
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
                        console.error('Virtual Index 앵커[' + index + '] 생성 실패:', e);
                        return null;
                    }
                }
                
                // 🚀 **Structural Path 앵커 생성 (보조)**
                function createStructuralPathAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        
                        // 🎯 **수정: 단일 스크롤러 기준으로 계산**
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // CSS 경로 생성
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
                            
                            // nth-child 추가
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
                        
                        const qualityScore = 50; // Structural Path는 50점 (보조용)
                        
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
                        console.error('Structural Path 앵커[' + index + '] 생성 실패:', e);
                        return null;
                    }
                }
                
                // 🚀 **메인 실행 - 무한스크롤 전용 앵커 데이터 수집**
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
                detailedLogs.push('처리 성능: ' + pageAnalysis.capturePerformance.anchorsPerSecond + ' 앵커/초');
                
                console.log('🚀 무한스크롤 전용 앵커 캡처 완료:', {
                    infiniteScrollAnchorsCount: infiniteScrollAnchorsData.anchors.length,
                    stats: infiniteScrollAnchorsData.stats,
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight],
                    captureTime: captureTime,
                    actualViewportRect: actualViewportRect
                });
                
                // ✅ **수정: 정리된 반환 구조 (단일 스크롤러 기준)**
                return {
                    infiniteScrollAnchors: infiniteScrollAnchorsData, // 🚀 **무한스크롤 전용 앵커 데이터**
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
                    actualViewportRect: actualViewportRect,     // 🚀 **실제 보이는 영역 정보**
                    detailedLogs: detailedLogs,                 // 📊 **상세 로그 배열**
                    captureStats: infiniteScrollAnchorsData.stats,  // 🔧 **수정: stats 직접 할당**
                    pageAnalysis: pageAnalysis,                 // 📊 **페이지 분석 결과**
                    captureTime: captureTime                    // 📊 **캡처 소요 시간**
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
