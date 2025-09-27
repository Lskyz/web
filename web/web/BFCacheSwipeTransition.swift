//
//  BFCacheSnapshotManager.swift
//  📸 **순차적 4단계 BFCache 복원 시스템**
//  🎯 **Step 1**: 저장 콘텐츠 높이 복원 (동적 사이트만)
//  📏 **Step 2**: 상대좌표 기반 스크롤 복원 (최우선)
//  🔍 **Step 3**: 무한스크롤 전용 앵커 정밀 복원
//  ✅ **Step 4**: 최종 검증 및 미세 보정
//  ⏰ **렌더링 대기**: 각 단계별 필수 대기시간 적용
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용
//  🎯 **가상 스크롤 정규화 대응**: 실제 스크롤러 탐지 + 4000-5500px 보정 감지
//  🔧 **JS 오류 수정**: Promise 대신 콜백 기반 비동기 처리
//  🚀 **오프스크린 앵커 지원**: 뷰포트 밖 요소도 캡처/복원

import UIKit
import WebKit
import SwiftUI

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

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
        TabPersistenceManager.debugMessages.append("🎯 순차적 4단계 BFCache 복원 시작 (오프스크린 앵커 지원)")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 저장 콘텐츠 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")
        TabPersistenceManager.debugMessages.append("🚀 오프스크린 앵커 지원 활성화")
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
        
        // 🔧 수정: 콜백 기반으로 변경
        let js = """
        window._bfcacheStep1Result = null;
        window._bfcacheStep1Complete = function() {
            \(generateStep1_ContentRestoreScript())
        };
        window._bfcacheStep1Complete();
        """
        
        context.webView?.evaluateJavaScript(js) { _, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] JavaScript 실행 오류: \(error.localizedDescription)")
            }
            
            // 결과를 가져오기 위한 두 번째 호출
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.retrieveStep1Result(context: context)
            }
        }
    }
    
    private func retrieveStep1Result(context: RestorationContext) {
        let retrieveJS = "window._bfcacheStep1Result"
        
        context.webView?.evaluateJavaScript(retrieveJS) { result, error in
            var step1Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] 결과 조회 오류: \(error.localizedDescription)")
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
        
        // 🔧 수정: 콜백 기반으로 변경
        let js = """
        window._bfcacheStep2Result = null;
        window._bfcacheStep2Complete = function() {
            \(generateStep2_PercentScrollScript())
        };
        window._bfcacheStep2Complete();
        """
        
        context.webView?.evaluateJavaScript(js) { _, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("📏 [Step 2] JavaScript 실행 오류: \(error.localizedDescription)")
            }
            
            // 결과를 가져오기 위한 두 번째 호출
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.retrieveStep2Result(context: context)
            }
        }
    }
    
    private func retrieveStep2Result(context: RestorationContext) {
        let retrieveJS = "window._bfcacheStep2Result"
        
        context.webView?.evaluateJavaScript(retrieveJS) { result, error in
            var step2Success = false
            var updatedContext = context
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📏 [Step 2] 결과 조회 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step2Success = (resultDict["success"] as? Bool) ?? false
                
                // 가상 스크롤 정규화 감지
                if let virtualScrollDetected = resultDict["virtualScrollDetected"] as? Bool, virtualScrollDetected {
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] ⚠️ 가상 스크롤 정규화 감지 - Step 3로 전환")
                    if let normalizedRange = resultDict["normalizedRange"] as? String {
                        TabPersistenceManager.debugMessages.append("📏 [Step 2] 정규화 범위: \(normalizedRange)")
                    }
                    step2Success = false
                }
                
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
                if let scrollerInfo = resultDict["scrollerInfo"] as? [String: Any] {
                    if let scrollerType = scrollerInfo["type"] as? String {
                        TabPersistenceManager.debugMessages.append("📏 [Step 2] 스크롤러 타입: \(scrollerType)")
                    }
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
    
    // MARK: - Step 3: 무한스크롤 전용 앵커 복원 (오프스크린 지원)
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 무한스크롤 전용 앵커 정밀 복원 시작 (오프스크린 지원)")
        
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
        
        // 🔧 수정: 콜백 기반 + 오프스크린 앵커 지원
        let js = """
        window._bfcacheStep3Result = null;
        window._bfcacheStep3Complete = function() {
            \(generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: infiniteScrollAnchorDataJSON))
        };
        window._bfcacheStep3Complete();
        """
        
        context.webView?.evaluateJavaScript(js) { _, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("🔍 [Step 3] JavaScript 실행 오류: \(error.localizedDescription)")
            }
            
            // 결과를 가져오기 위한 두 번째 호출
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.retrieveStep3Result(context: context)
            }
        }
    }
    
    private func retrieveStep3Result(context: RestorationContext) {
        let retrieveJS = "window._bfcacheStep3Result"
        
        context.webView?.evaluateJavaScript(retrieveJS) { result, error in
            var step3Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🔍 [Step 3] 결과 조회 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step3Success = (resultDict["success"] as? Bool) ?? false
                
                if let anchorCount = resultDict["anchorCount"] as? Int {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 사용 가능한 앵커: \(anchorCount)개")
                }
                if let offscreenMatched = resultDict["offscreenMatched"] as? Bool, offscreenMatched {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 🚀 오프스크린 앵커 매칭 성공")
                }
                if let virtualScrollUsed = resultDict["virtualScrollUsed"] as? Bool, virtualScrollUsed {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 가상 스크롤 인덱스 방식 사용")
                }
                if let seekingUsed = resultDict["seekingUsed"] as? Bool, seekingUsed {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 시킹/프리롤 사용")
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
        
        // 🔧 수정: 콜백 기반으로 변경
        let js = """
        window._bfcacheStep4Result = null;
        window._bfcacheStep4Complete = function() {
            \(generateStep4_FinalVerificationScript())
        };
        window._bfcacheStep4Complete();
        """
        
        context.webView?.evaluateJavaScript(js) { _, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] JavaScript 실행 오류: \(error.localizedDescription)")
            }
            
            // 결과를 가져오기 위한 두 번째 호출
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.retrieveStep4Result(context: context)
            }
        }
    }
    
    private func retrieveStep4Result(context: RestorationContext) {
        let retrieveJS = "window._bfcacheStep4Result"
        
        context.webView?.evaluateJavaScript(retrieveJS) { result, error in
            var step4Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] 결과 조회 오류: \(error.localizedDescription)")
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
    
    // MARK: - 🎯 가상 스크롤 대응 JavaScript 생성 메서드들 (콜백 기반으로 수정)
    
    // 🎯 **공통 유틸리티 스크립트 생성 - 오프스크린 앵커 지원 버전**
    private func generateCommonUtilityScript() -> String {
        return """
        // 🎯 **가상 스크롤 정규화 대응 + 오프스크린 앵커 공통 유틸리티**
        // 정규화 패턴: 6000px 이상 스크롤 시 4000-5500px 범위로 강제 리셋
        
        // 실제 스크롤러 탐지 함수
        function findPrimaryScroller() {
            const cands = Array.from(document.querySelectorAll('*')).filter(function(el) {
                const cs = getComputedStyle(el);
                if (!(cs.overflowY === 'auto' || cs.overflowY === 'scroll')) return false;
                const h = el.clientHeight;
                const sh = el.scrollHeight;
                if (h === 0) return false;
                const vh = window.innerHeight;
                // 뷰포트 크기와 유사 + 충분한 스크롤 여유
                return Math.abs(h - vh) < 120 && (sh - h) > 1000;
            });
            // 가장 스크롤 여유 큰 후보 1개
            const sorted = cands.sort(function(a,b) {
                return (b.scrollHeight - b.clientHeight) - (a.scrollHeight - a.clientHeight);
            });
            return sorted[0] || document.scrollingElement || document.documentElement;
        }
        
        // 스크롤러 타입 감지
        function getScrollerType(scroller) {
            if (scroller === document.scrollingElement || scroller === document.documentElement) {
                return 'root';
            }
            return 'container';
        }
        
        function getMaxScroll(scroller) { 
            if (!scroller) scroller = findPrimaryScroller();
            return { 
                x: Math.max(0, scroller.scrollWidth - scroller.clientWidth),
                y: Math.max(0, scroller.scrollHeight - scroller.clientHeight) 
            }; 
        }
        
        // 🔧 수정: 콜백 기반 레이아웃 안정화
        function waitForStableLayout(options, callback) {
            options = options || {};
            const frames = options.frames || 6;
            const timeout = options.timeout || 1500;
            const threshold = options.threshold || 2;
            
            const scroller = findPrimaryScroller();
            let last = scroller.scrollHeight;
            let stable = 0;
            const startTime = Date.now();
            
            function checkStability() {
                requestAnimationFrame(function() {
                    const h = scroller.scrollHeight;
                    if (Math.abs(h - last) <= threshold) {
                        stable++;
                    } else {
                        stable = 0;
                    }
                    last = h;
                    
                    if (stable >= frames || Date.now() - startTime >= timeout) {
                        if (callback) callback();
                    } else {
                        checkStability();
                    }
                });
            }
            
            checkStability();
        }
        
        // 🔧 수정: 콜백 기반 정밀 스크롤
        function preciseScrollTo(scroller, x, y, callback) {
            if (!scroller) scroller = findPrimaryScroller();
            
            // 첫 번째 설정
            scroller.scrollLeft = x;
            scroller.scrollTop = y;
            
            // 브라우저가 적용할 시간 대기
            requestAnimationFrame(function() {
                const y1 = scroller.scrollTop;
                
                // 가상 스크롤 정규화 감지
                const isNormalized = (y > 6000 && y1 >= 4000 && y1 <= 5500) || 
                                    (y > 10000 && y1 < y * 0.6);
                
                if (isNormalized) {
                    // 정규화 감지됨
                    if (callback) {
                        callback({ 
                            x: scroller.scrollLeft || 0, 
                            y: y1,
                            virtualScrollDetected: true,
                            targetY: y,
                            normalizedRange: '4000-5500px'
                        });
                    }
                    return;
                }
                
                // 두 번째 설정 (보정)
                scroller.scrollLeft = x;
                scroller.scrollTop = y;
                
                // 최종 적용 대기
                requestAnimationFrame(function() {
                    const y2 = scroller.scrollTop;
                    
                    // 두 번째 시도 후에도 정규화 확인
                    const isStillNormalized = (y > 6000 && y2 >= 4000 && y2 <= 5500) || 
                                              (y > 10000 && y2 < y * 0.6);
                    
                    if (callback) {
                        callback({ 
                            x: scroller.scrollLeft || 0, 
                            y: y2,
                            virtualScrollDetected: isStillNormalized,
                            targetY: y,
                            normalizedRange: isStillNormalized ? '4000-5500px' : null
                        });
                    }
                });
            });
        }
        
        function fixedHeaderHeight() {
            const cands = document.querySelectorAll('header, [class*="header"], [class*="gnb"], [class*="navbar"], [class*="nav-bar"]');
            let h = 0;
            cands.forEach(function(el) {
                const cs = getComputedStyle(el);
                if (cs.position === 'fixed' || cs.position === 'sticky') {
                    h = Math.max(h, el.getBoundingClientRect().height);
                }
            });
            return h;
        }
        
        // 🔧 수정: 콜백 기반 가상 스크롤 인덱스
        function scrollVirtualByIndex(idx, targetY, callback) {
            // 1) Vue/React 컴포넌트 API 탐색
            const hook = document.querySelector('[data-virtualizer],[data-v-]');
            if (hook) {
                // Vue 컴포넌트 접근 시도
                const vueApp = window.__vueApp__ || window.Vue;
                const vueInstance = hook.__vueParentComponent || hook.__vue__;
                if (vueInstance && vueInstance.exposed && vueInstance.exposed.scrollToIndex) {
                    vueInstance.exposed.scrollToIndex(idx);
                    setTimeout(function() {
                        if (callback) callback(true);
                    }, 100);
                    return;
                }
            }
            
            // 2) 페이징 스텝 (바이너리 서치)
            const scroller = findPrimaryScroller();
            let low = 0;
            let high = Math.max(100000, targetY * 2);
            let iteration = 0;
            
            function binarySearch() {
                if (iteration >= 10) {
                    if (callback) callback(false);
                    return;
                }
                
                const mid = Math.floor((low + high) / 2);
                scroller.scrollTop = mid;
                
                requestAnimationFrame(function() {
                    const currentY = scroller.scrollTop;
                    
                    // 정규화로 인해 더 이상 진행 불가
                    const isNormalized = mid > 6000 && currentY >= 4000 && currentY <= 5500;
                    if (isNormalized) {
                        console.log('가상 스크롤 정규화 감지: ' + currentY + 'px (목표: ' + mid + 'px)');
                        if (callback) callback(false);
                        return;
                    }
                    
                    if (currentY < targetY - 50) {
                        low = mid;
                        iteration++;
                        binarySearch();
                    } else if (currentY > targetY + 50) {
                        high = mid;
                        iteration++;
                        binarySearch();
                    } else {
                        // 목표 근처 도달
                        if (callback) callback(true);
                    }
                });
            }
            
            binarySearch();
        }
        
        // 🔧 수정: 콜백 기반 무한스크롤 preroll
        function prerollInfinite(maxSteps, callback) {
            maxSteps = maxSteps || 6;
            const scroller = findPrimaryScroller();
            let currentStep = 0;
            
            function stepPreroll() {
                if (currentStep >= maxSteps) {
                    // 안정화 대기 후 콜백
                    waitForStableLayout({}, callback);
                    return;
                }
                
                const before = scroller.scrollHeight;
                scroller.scrollTop = before; // 바닥
                window.dispatchEvent(new Event('scroll', { bubbles: true }));
                
                setTimeout(function() {
                    const after = scroller.scrollHeight;
                    if (after - before < 64) {
                        // 더 이상 늘지 않으면 종료
                        waitForStableLayout({}, callback);
                    } else {
                        currentStep++;
                        stepPreroll();
                    }
                }, 120);
            }
            
            stepPreroll();
        }
        
        // 🚀 **추가: DOM 상태 확인 함수**
        function inDOM(el) {
            return !!(el && el.isConnected);
        }
        
        // 🚀 **추가: 렌더링 가능 여부 확인 (뷰포트 제약 없음)**
        function isRenderable(el) {
            const cs = getComputedStyle(el);
            if (cs.display === 'none' || cs.visibility === 'hidden' || cs.opacity === '0') return false;
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
        }
        
        // 🚀 **추가: DOM 전역 앵커 매칭 (오프스크린 허용)**
        function matchAnchorDOMWide(anchor) {
            // 1) Vue component
            if (anchor && anchor.vueComponent && anchor.vueComponent.dataV) {
                const dataV = anchor.vueComponent.dataV;
                const name = anchor.vueComponent.name;
                const index = anchor.vueComponent.index;
                const nodes = document.querySelectorAll('[' + dataV + ']');
                
                for (let i = 0; i < nodes.length; i++) {
                    const el = nodes[i];
                    if (name && !(el.className || '').includes(name)) continue;
                    
                    if (typeof index === 'number' && el.parentElement) {
                        const idx = Array.from(el.parentElement.children).indexOf(el);
                        if (Math.abs(idx - index) > 2) continue;
                    }
                    
                    if (inDOM(el)) return el; // 뷰포트 밖이어도 통과
                }
            }
            
            // 2) Content Hash
            if (anchor && anchor.contentHash && anchor.contentHash.text) {
                const needle = anchor.contentHash.text.slice(0, 50);
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
                let n;
                while (n = walker.nextNode()) {
                    const t = (n.nodeValue || '').trim();
                    if (t.length >= 10 && t.includes(needle)) {
                        return n.parentElement;
                    }
                }
            }
            
            // 3) Virtual Index
            if (anchor && anchor.virtualIndex && anchor.virtualIndex.listIndex != null) {
                const cand = document.querySelectorAll('li, .item, .list-item, [class*="List"], [class*="Item"]');
                const i = anchor.virtualIndex.listIndex;
                if (i >= 0 && i < cand.length) return cand[i];
            }
            
            return null;
        }
        
        // 🚀 **추가: 오프스크린 요소로 스크롤**
        function scrollToElementOffscreen(el, scroller, callback) {
            if (!scroller) scroller = findPrimaryScroller();
            
            const r = el.getBoundingClientRect();
            const absY = scroller.scrollTop + r.top;
            const header = fixedHeaderHeight();
            const finalY = Math.max(0, absY - header);
            
            scroller.scrollTop = finalY;
            
            requestAnimationFrame(function() {
                scroller.scrollTop = finalY; // 2차 보정
                if (callback) callback({ x: scroller.scrollLeft || 0, y: finalY });
            });
        }
        
        // 🚀 **추가: 시킹/프리롤로 앵커를 뷰포트로 로드**
        function seekAnchorToViewport(targetPercentY, anchor, callback) {
            const scroller = findPrimaryScroller();
            const viewportHeight = scroller === document.documentElement ? window.innerHeight : scroller.clientHeight;
            const stepSize = viewportHeight * 0.8;
            let iteration = 0;
            const maxIterations = 20;
            
            function seekStep() {
                if (iteration >= maxIterations) {
                    if (callback) callback(false);
                    return;
                }
                
                // 현재 위치에서 매칭 시도
                const el = matchAnchorDOMWide(anchor);
                if (el) {
                    // 찾았으면 해당 위치로 스크롤
                    scrollToElementOffscreen(el, scroller, function(pos) {
                        if (callback) callback(true, pos);
                    });
                    return;
                }
                
                // 못 찾았으면 스텝 이동
                const currentY = scroller.scrollTop;
                const maxY = scroller.scrollHeight - viewportHeight;
                const targetY = (targetPercentY / 100) * maxY;
                
                let nextY;
                if (currentY < targetY - stepSize) {
                    nextY = Math.min(currentY + stepSize, targetY);
                } else if (currentY > targetY + stepSize) {
                    nextY = Math.max(currentY - stepSize, targetY);
                } else {
                    // 목표 근처인데 못 찾음 - 프리롤 시도
                    prerollInfinite(3, function() {
                        const el2 = matchAnchorDOMWide(anchor);
                        if (el2) {
                            scrollToElementOffscreen(el2, scroller, function(pos) {
                                if (callback) callback(true, pos);
                            });
                        } else {
                            if (callback) callback(false);
                        }
                    });
                    return;
                }
                
                scroller.scrollTop = nextY;
                iteration++;
                
                // 렌더링 대기 후 재시도
                setTimeout(seekStep, 100);
            }
            
            seekStep();
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
    
    // 🔧 수정: 콜백 기반 Step 1 스크립트
    private func generateStep1_ContentRestoreScript() -> String {
        let targetHeight = restorationConfig.savedContentHeight
        
        return """
        (function() {
            try {
                \(generateCommonUtilityScript())
                
                const logs = [];
                const targetHeight = parseFloat('\(targetHeight)');
                const scroller = findPrimaryScroller();
                const currentHeight = scroller.scrollHeight;
                
                logs.push('[Step 1] 콘텐츠 높이 복원 시작');
                logs.push('현재 높이: ' + currentHeight.toFixed(0) + 'px');
                logs.push('목표 높이: ' + targetHeight.toFixed(0) + 'px');
                logs.push('스크롤러 타입: ' + getScrollerType(scroller));
                
                // 정적 사이트 판단
                const percentage = (currentHeight / targetHeight) * 100;
                const isStaticSite = percentage >= 90;
                
                if (isStaticSite) {
                    logs.push('정적 사이트 - 콘텐츠 이미 충분함');
                    window._bfcacheStep1Result = {
                        success: true,
                        isStaticSite: true,
                        currentHeight: currentHeight,
                        targetHeight: targetHeight,
                        restoredHeight: currentHeight,
                        percentage: percentage,
                        logs: logs
                    };
                    return;
                }
                
                // 동적 사이트 - 콘텐츠 로드 시도
                logs.push('동적 사이트 - 콘텐츠 로드 시도');
                
                // 가상 스크롤 가능성 체크
                const maybeVirtualScroll = targetHeight > 10000;
                
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
                
                // 무한스크롤 트리거 (콜백 기반)
                if (maybeVirtualScroll) {
                    logs.push('가상 스크롤 가능성 - 무한스크롤 트리거');
                    prerollInfinite(3, function() {
                        const restoredHeight = scroller.scrollHeight;
                        const finalPercentage = (restoredHeight / targetHeight) * 100;
                        const success = finalPercentage >= 80;
                        
                        logs.push('복원된 높이: ' + restoredHeight.toFixed(0) + 'px');
                        logs.push('복원률: ' + finalPercentage.toFixed(1) + '%');
                        
                        window._bfcacheStep1Result = {
                            success: success,
                            isStaticSite: false,
                            currentHeight: currentHeight,
                            targetHeight: targetHeight,
                            restoredHeight: restoredHeight,
                            percentage: finalPercentage,
                            logs: logs
                        };
                    });
                } else {
                    // 비가상 스크롤 사이트
                    setTimeout(function() {
                        const restoredHeight = scroller.scrollHeight;
                        const finalPercentage = (restoredHeight / targetHeight) * 100;
                        const success = finalPercentage >= 80;
                        
                        logs.push('복원된 높이: ' + restoredHeight.toFixed(0) + 'px');
                        logs.push('복원률: ' + finalPercentage.toFixed(1) + '%');
                        
                        window._bfcacheStep1Result = {
                            success: success,
                            isStaticSite: false,
                            currentHeight: currentHeight,
                            targetHeight: targetHeight,
                            restoredHeight: restoredHeight,
                            percentage: finalPercentage,
                            logs: logs
                        };
                    }, 300);
                }
                
            } catch(e) {
                window._bfcacheStep1Result = {
                    success: false,
                    error: e.message,
                    logs: ['[Step 1] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // 🔧 수정: 콜백 기반 Step 2 스크립트
    private func generateStep2_PercentScrollScript() -> String {
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        
        return """
        (function() {
            try {
                \(generateCommonUtilityScript())
                
                const logs = [];
                const targetPercentX = parseFloat('\(targetPercentX)');
                const targetPercentY = parseFloat('\(targetPercentY)');
                
                logs.push('[Step 2] 상대좌표 기반 스크롤 복원');
                logs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                
                // 안정화 대기 (콜백 기반)
                waitForStableLayout({ frames: 3, timeout: 1000 }, function() {
                    const scroller = findPrimaryScroller();
                    const scrollerType = getScrollerType(scroller);
                    const max = getMaxScroll(scroller);
                    
                    logs.push('스크롤러: ' + scrollerType);
                    logs.push('최대 스크롤: X=' + max.x.toFixed(0) + 'px, Y=' + max.y.toFixed(0) + 'px');
                    
                    // 백분율 기반 목표 위치 계산
                    const targetX = (targetPercentX / 100) * max.x;
                    const targetY = (targetPercentY / 100) * max.y;
                    
                    logs.push('계산된 목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                    
                    // 정밀 스크롤 (콜백 기반)
                    preciseScrollTo(scroller, targetX, targetY, function(result) {
                        const diffX = Math.abs(result.x - targetX);
                        const diffY = Math.abs(result.y - targetY);
                        
                        logs.push('실제 위치: X=' + result.x.toFixed(1) + 'px, Y=' + result.y.toFixed(1) + 'px');
                        logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                        
                        // 가상 스크롤 정규화 감지
                        if (result.virtualScrollDetected) {
                            logs.push('⚠️ 가상 스크롤 정규화 감지 - ' + (result.normalizedRange || '4000-5500px') + ' 범위로 강제됨');
                            logs.push('   목표: ' + result.targetY + 'px → 실제: ' + result.y.toFixed(0) + 'px');
                            window._bfcacheStep2Result = {
                                success: false,
                                virtualScrollDetected: true,
                                targetPercent: { x: targetPercentX, y: targetPercentY },
                                calculatedPosition: { x: targetX, y: targetY },
                                actualPosition: { x: result.x, y: result.y },
                                difference: { x: diffX, y: diffY },
                                scrollerInfo: { type: scrollerType },
                                normalizedRange: result.normalizedRange,
                                logs: logs
                            };
                            return;
                        }
                        
                        // 허용 오차 50px 이내면 성공
                        const success = diffY <= 50;
                        
                        window._bfcacheStep2Result = {
                            success: success,
                            virtualScrollDetected: false,
                            targetPercent: { x: targetPercentX, y: targetPercentY },
                            calculatedPosition: { x: targetX, y: targetY },
                            actualPosition: { x: result.x, y: result.y },
                            difference: { x: diffX, y: diffY },
                            scrollerInfo: { type: scrollerType },
                            logs: logs
                        };
                    });
                });
                
            } catch(e) {
                window._bfcacheStep2Result = {
                    success: false,
                    error: e.message,
                    logs: ['[Step 2] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // 🔧 수정: 콜백 기반 Step 3 스크립트 (오프스크린 앵커 지원)
    private func generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: String) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        let targetPercentY = scrollPositionPercent.y
        
        return """
        (function() {
            try {
                \(generateCommonUtilityScript())
                
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const targetPercentY = parseFloat('\(targetPercentY)');
                const infiniteScrollAnchorData = \(anchorDataJSON);
                const scroller = findPrimaryScroller();
                
                logs.push('[Step 3] 무한스크롤 전용 앵커 복원 (오프스크린 지원)');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                logs.push('스크롤러 타입: ' + getScrollerType(scroller));
                
                // 앵커 데이터 확인
                if (!infiniteScrollAnchorData || !infiniteScrollAnchorData.anchors || infiniteScrollAnchorData.anchors.length === 0) {
                    logs.push('무한스크롤 앵커 데이터 없음 - 스킵');
                    window._bfcacheStep3Result = {
                        success: false,
                        anchorCount: 0,
                        logs: logs
                    };
                    return;
                }
                
                const anchors = infiniteScrollAnchorData.anchors;
                logs.push('사용 가능한 앵커: ' + anchors.length + '개');
                
                // 🚀 **핵심: DOM 전역 매칭 시도 (오프스크린 허용)**
                let foundElement = null;
                let matchedAnchor = null;
                let matchMethod = '';
                let confidence = 0;
                
                // 우선순위별로 앵커 매칭 시도
                for (let i = 0; i < Math.min(anchors.length, 20); i++) {
                    const anchor = anchors[i];
                    const el = matchAnchorDOMWide(anchor);
                    
                    if (el) {
                        foundElement = el;
                        matchedAnchor = anchor;
                        matchMethod = 'dom_wide_match';
                        confidence = 85;
                        
                        // 오프스크린인지 확인
                        const rect = el.getBoundingClientRect();
                        const isOffscreen = rect.top < -100 || rect.top > window.innerHeight + 100;
                        
                        if (isOffscreen) {
                            logs.push('🚀 오프스크린 앵커 매칭: ' + anchor.anchorType);
                            matchMethod = 'offscreen_match';
                        } else {
                            logs.push('앵커 매칭: ' + anchor.anchorType);
                        }
                        break;
                    }
                }
                
                // 매칭된 요소가 있으면 스크롤
                if (foundElement && matchedAnchor) {
                    scrollToElementOffscreen(foundElement, scroller, function(pos) {
                        const diffX = Math.abs(pos.x - targetX);
                        const diffY = Math.abs(pos.y - targetY);
                        
                        logs.push('앵커 복원 후 위치: X=' + pos.x.toFixed(1) + 'px, Y=' + pos.y.toFixed(1) + 'px');
                        logs.push('목표와의 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                        logs.push('매칭 신뢰도: ' + confidence + '%');
                        
                        window._bfcacheStep3Result = {
                            success: diffY <= 100,
                            anchorCount: anchors.length,
                            offscreenMatched: matchMethod === 'offscreen_match',
                            matchedAnchor: {
                                anchorType: matchedAnchor.anchorType,
                                matchMethod: matchMethod,
                                confidence: confidence
                            },
                            restoredPosition: { x: pos.x, y: pos.y },
                            targetDifference: { x: diffX, y: diffY },
                            logs: logs
                        };
                    });
                } else {
                    // 🚀 **매칭 실패 - 시킹/프리롤 시도**
                    logs.push('DOM 전역 매칭 실패 - 시킹/프리롤 시도');
                    
                    // 가장 우선순위 높은 앵커로 시킹
                    const primaryAnchor = anchors[0];
                    
                    seekAnchorToViewport(targetPercentY, primaryAnchor, function(success, pos) {
                        if (success && pos) {
                            const diffX = Math.abs(pos.x - targetX);
                            const diffY = Math.abs(pos.y - targetY);
                            
                            logs.push('시킹 후 복원 위치: X=' + pos.x.toFixed(1) + 'px, Y=' + pos.y.toFixed(1) + 'px');
                            logs.push('목표와의 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                            
                            window._bfcacheStep3Result = {
                                success: diffY <= 100,
                                anchorCount: anchors.length,
                                seekingUsed: true,
                                matchedAnchor: {
                                    anchorType: primaryAnchor.anchorType,
                                    matchMethod: 'seeking_restore',
                                    confidence: 75
                                },
                                restoredPosition: pos,
                                targetDifference: { x: diffX, y: diffY },
                                logs: logs
                            };
                        } else {
                            logs.push('시킹/프리롤 실패');
                            window._bfcacheStep3Result = {
                                success: false,
                                anchorCount: anchors.length,
                                seekingUsed: true,
                                logs: logs
                            };
                        }
                    });
                }
                
            } catch(e) {
                window._bfcacheStep3Result = {
                    success: false,
                    error: e.message,
                    logs: ['[Step 3] 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // 🔧 수정: 콜백 기반 Step 4 스크립트
    private func generateStep4_FinalVerificationScript() -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                \(generateCommonUtilityScript())
                
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const tolerance = 30;
                
                logs.push('[Step 4] 최종 검증 및 미세 보정');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                
                const scroller = findPrimaryScroller();
                logs.push('스크롤러 타입: ' + getScrollerType(scroller));
                
                // 현재 위치 확인
                let currentX = scroller.scrollLeft || 0;
                let currentY = scroller.scrollTop || 0;
                
                let diffX = Math.abs(currentX - targetX);
                let diffY = Math.abs(currentY - targetY);
                
                logs.push('현재 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                const withinTolerance = diffX <= tolerance && diffY <= tolerance;
                let correctionApplied = false;
                
                // 허용 오차 초과 시 미세 보정
                if (!withinTolerance) {
                    logs.push('허용 오차 초과 - 미세 보정 적용');
                    
                    // 정규화 체크
                    const isNormalized = targetY > 6000 && currentY >= 4000 && currentY <= 5500;
                    
                    if (isNormalized) {
                        logs.push('가상 스크롤 정규화 감지 (4000-5500px 범위) - 보정 스킵');
                        
                        window._bfcacheStep4Result = {
                            success: false,
                            targetPosition: { x: targetX, y: targetY },
                            finalPosition: { x: currentX, y: currentY },
                            finalDifference: { x: diffX, y: diffY },
                            withinTolerance: false,
                            correctionApplied: false,
                            logs: logs
                        };
                    } else {
                        scroller.scrollLeft = targetX;
                        scroller.scrollTop = targetY;
                        correctionApplied = true;
                        
                        requestAnimationFrame(function() {
                            // 보정 후 위치 재측정
                            currentX = scroller.scrollLeft || 0;
                            currentY = scroller.scrollTop || 0;
                            diffX = Math.abs(currentX - targetX);
                            diffY = Math.abs(currentY - targetY);
                            
                            logs.push('보정 후 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                            logs.push('보정 후 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                            
                            const success = diffY <= 50;
                            
                            window._bfcacheStep4Result = {
                                success: success,
                                targetPosition: { x: targetX, y: targetY },
                                finalPosition: { x: currentX, y: currentY },
                                finalDifference: { x: diffX, y: diffY },
                                withinTolerance: diffX <= tolerance && diffY <= tolerance,
                                correctionApplied: correctionApplied,
                                logs: logs
                            };
                        });
                    }
                } else {
                    // 이미 허용 오차 내
                    window._bfcacheStep4Result = {
                        success: true,
                        targetPosition: { x: targetX, y: targetY },
                        finalPosition: { x: currentX, y: currentY },
                        finalDifference: { x: diffX, y: diffY },
                        withinTolerance: true,
                        correctionApplied: false,
                        logs: logs
                    };
                }
                
            } catch(e) {
                window._bfcacheStep4Result = {
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
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🚀 무한스크롤 전용 앵커 + 오프스크린 캡처)**
    
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
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 캡처 대상 (오프스크린 포함): \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
        
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 직렬 캡처 시작 (오프스크린 포함): \(task.pageRecord.title) (\(task.type))")
        
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
        
        TabPersistenceManager.debugMessages.append("✅ 무한스크롤 앵커 직렬 캡처 완료 (오프스크린 포함): \(task.pageRecord.title)")
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
        
        // 3. ✅ **수정: 무한스크롤 전용 앵커 JS 상태 캡처 (오프스크린 포함)** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 JS 상태 캡처 시작 (오프스크린 포함)")
        
        DispatchQueue.main.sync {
            let jsScript = generateInfiniteScrollAnchorCaptureScript() // 🚀 **수정된: 오프스크린 앵커 캡처**
            
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
    
    // 🚀 **수정: JavaScript 앵커 캡처 스크립트 개선 (오프스크린 앵커 지원)**
    private func generateInfiniteScrollAnchorCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 무한스크롤 전용 앵커 캡처 시작 (오프스크린 지원)');
                
                // 🎯 **실제 스크롤러 탐지 함수**
                function findPrimaryScroller() {
                    const cands = Array.from(document.querySelectorAll('*')).filter(function(el) {
                        const cs = getComputedStyle(el);
                        if (!(cs.overflowY === 'auto' || cs.overflowY === 'scroll')) return false;
                        const h = el.clientHeight;
                        const sh = el.scrollHeight;
                        if (h === 0) return false;
                        const vh = window.innerHeight;
                        // 뷰포트 크기와 유사 + 충분한 스크롤 여유
                        return Math.abs(h - vh) < 120 && (sh - h) > 1000;
                    });
                    // 가장 스크롤 여유 큰 후보 1개
                    const sorted = cands.sort(function(a,b) {
                        return (b.scrollHeight - b.clientHeight) - (a.scrollHeight - a.clientHeight);
                    });
                    return sorted[0] || document.scrollingElement || document.documentElement;
                }
                
                // 📊 **상세 로그 수집**
                const detailedLogs = [];
                const pageAnalysis = {};
                
                // 🎯 **실제 스크롤러 기준으로 정보 수집**
                const scroller = findPrimaryScroller();
                const isRootScroller = (scroller === document.scrollingElement || scroller === document.documentElement);
                const scrollY = parseFloat(scroller.scrollTop) || 0;
                const scrollX = parseFloat(scroller.scrollLeft) || 0;
                const viewportHeight = parseFloat(isRootScroller ? window.innerHeight : scroller.clientHeight) || 0;
                const viewportWidth = parseFloat(isRootScroller ? window.innerWidth : scroller.clientWidth) || 0;
                const contentHeight = parseFloat(scroller.scrollHeight) || 0;
                const contentWidth = parseFloat(scroller.scrollWidth) || 0;
                
                detailedLogs.push('🚀 무한스크롤 전용 앵커 캡처 시작 (오프스크린 지원)');
                detailedLogs.push('스크롤러 타입: ' + (isRootScroller ? 'root' : 'container'));
                detailedLogs.push('스크롤 위치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포트 크기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                pageAnalysis.scrollerType = isRootScroller ? 'root' : 'container';
                
                console.log('🚀 기본 정보 (실제 스크롤러):', {
                    scrollerType: pageAnalysis.scrollerType,
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
                
                // 🚀 **개선: 렌더링 가능 여부만 체크 (뷰포트 제약 제거)**
                function isRenderable(element) {
                    try {
                        if (!element || !element.getBoundingClientRect) return false;
                        if (!document.contains(element)) return false;
                        
                        const cs = window.getComputedStyle(element);
                        if (cs.display === 'none' || cs.visibility === 'hidden' || cs.opacity === '0') return false;
                        
                        const rect = element.getBoundingClientRect();
                        return rect.width > 0 && rect.height > 0;
                        
                    } catch(e) {
                        return false;
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
                
                // 🚀 **수정된: Vue 컴포넌트 요소 수집 (오프스크린 포함)**
                function collectVueComponentElements() {
                    const vueElements = [];
                    
                    // 1. 모든 요소를 순회하면서 data-v-* 속성을 가진 요소 찾기
                    const allElements = document.querySelectorAll('*');
                    
                    for (let i = 0; i < allElements.length; i++) {
                        const element = allElements[i];
                        const dataVAttr = findDataVAttribute(element);
                        
                        if (dataVAttr) {
                            // 🚀 **개선: 렌더링 가능 여부만 체크 (뷰포트 체크 제거)**
                            if (isRenderable(element)) {
                                const elementText = (element.textContent || '').trim();
                                if (isQualityText(elementText)) {
                                    const rect = element.getBoundingClientRect();
                                    vueElements.push({
                                        element: element,
                                        dataVAttr: dataVAttr,
                                        rect: rect,
                                        textContent: elementText,
                                        // 오프스크린 여부 기록
                                        isOffscreen: rect.top < -100 || rect.top > window.innerHeight + 100
                                    });
                                }
                            }
                        }
                    }
                    
                    detailedLogs.push('Vue.js 컴포넌트 수집: ' + vueElements.length + '개 (오프스크린 포함)');
                    return vueElements;
                }
                
                // 🚀 **핵심: 무한스크롤 전용 앵커 수집 (오프스크린 포함)**
                function collectInfiniteScrollAnchors() {
                    const anchors = [];
                    const anchorStats = {
                        totalCandidates: 0,
                        renderableChecked: 0,
                        actuallyRenderable: 0,
                        offscreenAnchors: 0,
                        vueComponentAnchors: 0,
                        contentHashAnchors: 0,
                        virtualIndexAnchors: 0,
                        structuralPathAnchors: 0,
                        intersectionAnchors: 0,
                        finalAnchors: 0
                    };
                    
                    detailedLogs.push('🚀 무한스크롤 전용 앵커 수집 시작 (오프스크린 지원)');
                    
                    // 🚀 **1. Vue.js 컴포넌트 요소 우선 수집**
                    const vueComponentElements = collectVueComponentElements();
                    anchorStats.totalCandidates += vueComponentElements.length;
                    anchorStats.actuallyRenderable += vueComponentElements.length;
                    
                    // 오프스크린 카운트
                    const offscreenVueCount = vueComponentElements.filter(function(el) { return el.isOffscreen; }).length;
                    anchorStats.offscreenAnchors += offscreenVueCount;
                    detailedLogs.push('Vue 컴포넌트 중 오프스크린: ' + offscreenVueCount + '개');
                    
                    // 🚀 **2. 일반 콘텐츠 요소 수집 (무한스크롤용 + 오프스크린 포함)**
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
                    
                    // 중복 제거 및 렌더링 가능 필터링 (뷰포트 체크 없음)
                    const uniqueContentElements = [];
                    const processedElements = new Set();
                    
                    for (let i = 0; i < contentElements.length; i++) {
                        const element = contentElements[i];
                        if (!processedElements.has(element)) {
                            processedElements.add(element);
                            
                            // 🚀 **개선: 렌더링만 체크 (뷰포트 제약 제거)**
                            anchorStats.renderableChecked++;
                            
                            if (isRenderable(element)) {
                                const elementText = (element.textContent || '').trim();
                                if (elementText.length > 5) { // 🔧 텍스트 길이 조건 완화
                                    const rect = element.getBoundingClientRect();
                                    const isOffscreen = rect.top < -100 || rect.top > window.innerHeight + 100;
                                    
                                    uniqueContentElements.push({
                                        element: element,
                                        rect: rect,
                                        textContent: elementText,
                                        isOffscreen: isOffscreen
                                    });
                                    anchorStats.actuallyRenderable++;
                                    
                                    if (isOffscreen) {
                                        anchorStats.offscreenAnchors++;
                                    }
                                }
                            }
                        }
                    }
                    
                    detailedLogs.push('일반 콘텐츠 후보: ' + contentElements.length + '개, 유효: ' + uniqueContentElements.length + '개');
                    detailedLogs.push('오프스크린 콘텐츠: ' + anchorStats.offscreenAnchors + '개');
                    
                    // 🚀 **3. 수집량 증가: 상위 80개 선택 (오프스크린 포함)**
                    const MAX_ANCHORS = 80; // 20 → 80으로 증가
                    const viewportCenterY = scrollY + (viewportHeight / 2);
                    const viewportCenterX = scrollX + (viewportWidth / 2);
                    
                    // Vue 컴포넌트 정렬 (거리 기준)
                    vueComponentElements.sort(function(a, b) {
                        const aTop = scrollY + a.rect.top;
                        const bTop = scrollY + b.rect.top;
                        const aDistance = Math.abs(aTop + (a.rect.height / 2) - viewportCenterY);
                        const bDistance = Math.abs(bTop + (b.rect.height / 2) - viewportCenterY);
                        return aDistance - bDistance;
                    });
                    
                    // 일반 콘텐츠 정렬 (거리 기준)
                    uniqueContentElements.sort(function(a, b) {
                        const aTop = scrollY + a.rect.top;
                        const bTop = scrollY + b.rect.top;
                        const aDistance = Math.abs(aTop + (a.rect.height / 2) - viewportCenterY);
                        const bDistance = Math.abs(bTop + (b.rect.height / 2) - viewportCenterY);
                        return aDistance - bDistance;
                    });
                    
                    const selectedVueElements = vueComponentElements.slice(0, MAX_ANCHORS);
                    const selectedContentElements = uniqueContentElements.slice(0, MAX_ANCHORS);
                    
                    detailedLogs.push('선택된 앵커: Vue=' + selectedVueElements.length + '개, Content=' + selectedContentElements.length + '개');
                    
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
                    
                    anchorStats.finalAnchors = anchors.length;
                    
                    detailedLogs.push('무한스크롤 앵커 생성 완료: ' + anchors.length + '개 (오프스크린: ' + anchorStats.offscreenAnchors + '개)');
                    console.log('🚀 무한스크롤 앵커 수집 완료:', anchors.length, '개 (오프스크린 포함)');
                    
                    // 🔧 **수정: stats를 별도 객체로 반환**
                    return {
                        anchors: anchors,
                        stats: anchorStats
                    };
                }
                
                // 🚀 **수정된: Vue Component 앵커 생성**
                function createVueComponentAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        const dataVAttr = elementData.dataVAttr;
                        const isOffscreen = elementData.isOffscreen;
                        
                        // 🎯 **수정: 실제 스크롤러 기준으로 계산**
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // Vue 컴포넌트 정보 추출
                        const vueComponent = {
                            name: 'unknown',
                            dataV: dataVAttr,
                            props: {},
                            index: index,
                            isOffscreen: isOffscreen
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
                        
                        const qualityScore = isOffscreen ? 75 : 85; // 오프스크린은 점수 낮춤
                        
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
                            isVisible: !isOffscreen,
                            isOffscreen: isOffscreen,
                            visibilityReason: isOffscreen ? 'offscreen' : 'vue_component_visible'
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
                        const isOffscreen = elementData.isOffscreen;
                        
                        // 🎯 **수정: 실제 스크롤러 기준으로 계산**
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
                        
                        const qualityScore = isOffscreen ? 
                            Math.min(85, 50 + Math.min(35, Math.floor(textContent.length / 10))) :
                            Math.min(95, 60 + Math.min(35, Math.floor(textContent.length / 10)));
                        
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
                            isVisible: !isOffscreen,
                            isOffscreen: isOffscreen,
                            visibilityReason: isOffscreen ? 'offscreen' : 'content_hash_visible'
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
                        const isOffscreen = elementData.isOffscreen;
                        
                        // 🎯 **수정: 실제 스크롤러 기준으로 계산**
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        // 가상 인덱스 정보
                        const virtualIndex = {
                            listIndex: index,
                            pageIndex: Math.floor(index / 10), // 10개씩 페이지 단위
                            offsetInPage: absoluteTop,
                            estimatedTotal: document.querySelectorAll('li, .item, .list-item, .ListItem').length,
                            isOffscreen: isOffscreen
                        };
                        
                        const qualityScore = isOffscreen ? 60 : 70; // Virtual Index는 기본 점수 낮음
                        
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
                            isVisible: !isOffscreen,
                            isOffscreen: isOffscreen,
                            visibilityReason: isOffscreen ? 'offscreen' : 'virtual_index_visible'
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
                        const isOffscreen = elementData.isOffscreen;
                        
                        // 🎯 **수정: 실제 스크롤러 기준으로 계산**
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
                            depth: depth,
                            isOffscreen: isOffscreen
                        };
                        
                        const qualityScore = isOffscreen ? 40 : 50; // Structural Path는 점수 낮음
                        
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
                            isVisible: !isOffscreen,
                            isOffscreen: isOffscreen,
                            visibilityReason: isOffscreen ? 'offscreen' : 'structural_path_visible'
                        };
                        
                    } catch(e) {
                        console.error('Structural Path 앵커[' + index + '] 생성 실패:', e);
                        return null;
                    }
                }
                
                // 🚀 **메인 실행 - 무한스크롤 전용 앵커 데이터 수집 (오프스크린 포함)**
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
                detailedLogs.push('오프스크린 앵커: ' + infiniteScrollAnchorsData.stats.offscreenAnchors + '개');
                detailedLogs.push('처리 성능: ' + pageAnalysis.capturePerformance.anchorsPerSecond + ' 앵커/초');
                
                console.log('🚀 무한스크롤 전용 앵커 캡처 완료 (오프스크린 포함):', {
                    infiniteScrollAnchorsCount: infiniteScrollAnchorsData.anchors.length,
                    offscreenCount: infiniteScrollAnchorsData.stats.offscreenAnchors,
                    stats: infiniteScrollAnchorsData.stats,
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight],
                    captureTime: captureTime,
                    actualViewportRect: actualViewportRect,
                    scrollerType: pageAnalysis.scrollerType
                });
                
                // ✅ **수정: 정리된 반환 구조 (실제 스크롤러 기준 + 오프스크린 포함)**
                return {
                    infiniteScrollAnchors: infiniteScrollAnchorsData, // 🚀 **무한스크롤 전용 앵커 데이터 (오프스크린 포함)**
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
                    captureTime: captureTime,                   // 📊 **캡처 소요 시간**
                    scrollerType: pageAnalysis.scrollerType    // 🎯 **스크롤러 타입**
                };
            } catch(e) { 
                console.error('🚀 무한스크롤 전용 앵커 캡처 실패:', e);
                return {
                    infiniteScrollAnchors: { anchors: [], stats: {} },
                    scroll: { 
                        x: 0, 
                        y: 0
                    },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message,
                    detailedLogs: ['무한스크롤 전용 앵커 캡처 실패: ' + e.message],
                    captureStats: { error: e.message },
                    pageAnalysis: { error: e.message },
                    scrollerType: 'unknown'
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
