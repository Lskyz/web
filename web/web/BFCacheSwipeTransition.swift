//
//  BFCacheSnapshotManager.swift
//  📸 **순차적 4단계 BFCache 복원 시스템 (클램핑 문제 해결)**
//  📄 **Step 1**: 페이지네이션 방식 복원 (무한스크롤 사이트 전용) - 강화됨
//  📏 **Step 2**: 클램핑 우회 상대좌표 기반 스크롤 복원 (최우선)
//  🔍 **Step 3**: 무한스크롤 전용 앵커 정밀 복원
//  ✅ **Step 4**: 최종 검증 및 미세 보정
//  ⏰ **렌더링 대기**: 각 단계별 필수 대기시간 적용
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용

import UIKit
import WebKit
import SwiftUI

// MARK: - 📸 **무한스크롤 + 페이지네이션 앵커 조합 BFCache 페이지 스냅샷**
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
        let enablePaginationRestore: Bool    // Step 1 활성화 (페이지네이션)
        let enablePercentRestore: Bool       // Step 2 활성화
        let enableAnchorRestore: Bool        // Step 3 활성화
        let enableFinalVerification: Bool    // Step 4 활성화
        let savedContentHeight: CGFloat      // 저장 시점 콘텐츠 높이
        let targetPageNumber: Int            // 📄 **목표 페이지 번호**
        let estimatedItemsPerPage: Int       // 📄 **페이지당 예상 아이템 수**
        let paginationType: PaginationType   // 📄 **페이지네이션 타입**
        let step1RenderDelay: Double         // Step 1 후 렌더링 대기 (1.2초)
        let step2RenderDelay: Double         // Step 2 후 렌더링 대기 (0.3초)
        let step3RenderDelay: Double         // Step 3 후 렌더링 대기 (0.5초)
        let step4RenderDelay: Double         // Step 4 후 렌더링 대기 (0.3초)
        
        enum PaginationType: String, Codable {
            case infiniteScroll = "infiniteScroll"        // 무한스크롤
            case loadMoreButton = "loadMoreButton"         // 더보기 버튼
            case virtualPagination = "virtualPagination"  // 가상 페이지네이션
            case hybridPagination = "hybridPagination"    // 하이브리드
        }
        
        static let `default` = RestorationConfig(
            enablePaginationRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: 0,
            targetPageNumber: 1,
            estimatedItemsPerPage: 20,
            paginationType: .infiniteScroll,
            step1RenderDelay: 1.2,
            step2RenderDelay: 0.3,
            step3RenderDelay: 0.5,
            step4RenderDelay: 0.3
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
        
        // 📄 **페이지네이션 정보 계산**
        var calculatedPageNumber = 1
        var estimatedItemsPerPage = 20
        var detectedPaginationType = RestorationConfig.PaginationType.infiniteScroll
        
        // jsState에서 페이지네이션 정보 추출
        if let jsState = jsState,
           let paginationData = jsState["paginationInfo"] as? [String: Any] {
            calculatedPageNumber = (paginationData["currentPage"] as? Int) ?? 1
            estimatedItemsPerPage = (paginationData["itemsPerPage"] as? Int) ?? 20
            if let typeString = paginationData["paginationType"] as? String,
               let type = RestorationConfig.PaginationType(rawValue: typeString) {
                detectedPaginationType = type
            }
        }
        
        self.restorationConfig = RestorationConfig(
            enablePaginationRestore: restorationConfig.enablePaginationRestore,
            enablePercentRestore: restorationConfig.enablePercentRestore,
            enableAnchorRestore: restorationConfig.enableAnchorRestore,
            enableFinalVerification: restorationConfig.enableFinalVerification,
            savedContentHeight: max(actualScrollableSize.height, contentSize.height),
            targetPageNumber: calculatedPageNumber,
            estimatedItemsPerPage: estimatedItemsPerPage,
            paginationType: detectedPaginationType,
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
    
    // 🔧 **수정: 복원 컨텍스트에 임시 요소 추가**
    private struct RestorationContext {
        let snapshot: BFCacheSnapshot
        weak var webView: WKWebView?
        let completion: (Bool) -> Void
        var overallSuccess: Bool = false
        var tempElement: Any? = nil  // 🔧 **임시 요소 저장용**
    }
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 순차적 4단계 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 저장된 콘텐츠 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")
        TabPersistenceManager.debugMessages.append("📄 목표 페이지: \(restorationConfig.targetPageNumber)페이지 (\(restorationConfig.estimatedItemsPerPage)개/페이지)")
        TabPersistenceManager.debugMessages.append("📄 페이지네이션 타입: \(restorationConfig.paginationType.rawValue)")
        TabPersistenceManager.debugMessages.append("⏰ 렌더링 대기시간: Step1=\(restorationConfig.step1RenderDelay)s, Step2=\(restorationConfig.step2RenderDelay)s, Step3=\(restorationConfig.step3RenderDelay)s, Step4=\(restorationConfig.step4RenderDelay)s")
        
        // 복원 컨텍스트 생성
        var context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: completion
        )
        
        // Step 1 시작
        executeStep1_PaginationRestore(context: context)
    }
    
    // MARK: - Step 1: 📄 **페이지네이션 방식 복원 (강화됨 - 콘텐츠 로드 우선)**
    private func executeStep1_PaginationRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📄 [Step 1] 페이지네이션 방식 복원 시작 (강화된 콘텐츠 로드)")
        
        guard restorationConfig.enablePaginationRestore else {
            TabPersistenceManager.debugMessages.append("📄 [Step 1] 비활성화됨 - 스킵")
            // 렌더링 대기 후 다음 단계
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step1RenderDelay) {
                self.executeStep2_ClampingBypassScroll(context: context)
            }
            return
        }
        
        let js = generateStep1_EnhancedPaginationRestoreScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step1Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📄 [Step 1] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step1Success = (resultDict["success"] as? Bool) ?? false
                
                if let detectedType = resultDict["detectedPaginationType"] as? String {
                    TabPersistenceManager.debugMessages.append("📄 [Step 1] 감지된 페이지네이션 타입: \(detectedType)")
                }
                if let initialHeight = resultDict["initialContentHeight"] as? Double {
                    TabPersistenceManager.debugMessages.append("📄 [Step 1] 초기 콘텐츠 높이: \(String(format: "%.0f", initialHeight))px")
                }
                if let finalHeight = resultDict["finalContentHeight"] as? Double {
                    TabPersistenceManager.debugMessages.append("📄 [Step 1] 최종 콘텐츠 높이: \(String(format: "%.0f", finalHeight))px")
                }
                if let targetHeight = resultDict["targetContentHeight"] as? Double {
                    TabPersistenceManager.debugMessages.append("📄 [Step 1] 목표 콘텐츠 높이: \(String(format: "%.0f", targetHeight))px")
                }
                if let loadProgress = resultDict["loadProgress"] as? Double {
                    TabPersistenceManager.debugMessages.append("📄 [Step 1] 콘텐츠 로드 진행률: \(String(format: "%.1f", loadProgress))%")
                }
                if let scrollAttempts = resultDict["scrollAttempts"] as? Int {
                    TabPersistenceManager.debugMessages.append("📄 [Step 1] 스크롤 시도 횟수: \(scrollAttempts)")
                }
                if let contentLoaded = resultDict["contentLoaded"] as? Bool {
                    TabPersistenceManager.debugMessages.append("📄 [Step 1] 충분한 콘텐츠 로드: \(contentLoaded ? "성공" : "실패")")
                }
                if let method = resultDict["restorationMethod"] as? String {
                    TabPersistenceManager.debugMessages.append("📄 [Step 1] 복원 방법: \(method)")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(15) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("📄 [Step 1] 완료: \(step1Success ? "성공" : "실패") - 실패해도 계속 진행")
            TabPersistenceManager.debugMessages.append("⏰ [Step 1] 렌더링 대기: \(self.restorationConfig.step1RenderDelay)초")
            
            // 성공/실패 관계없이 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step1RenderDelay) {
                self.executeStep2_ClampingBypassScroll(context: context)
            }
        }
    }
    
    // MARK: - Step 2: 🚀 **클램핑 우회 스크롤 복원 (핵심) - 임시 요소 유지**
    private func executeStep2_ClampingBypassScroll(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🚀 [Step 2] 클램핑 우회 스크롤 복원 시작")
        
        guard restorationConfig.enablePercentRestore else {
            TabPersistenceManager.debugMessages.append("🚀 [Step 2] 비활성화됨 - 스킵")
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step2RenderDelay) {
                self.executeStep3_AnchorRestore(context: context)
            }
            return
        }
        
        let js = generateStep2_ClampingBypassScrollScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step2Success = false
            var updatedContext = context
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("🚀 [Step 2] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step2Success = (resultDict["success"] as? Bool) ?? false
                
                if let targetPercent = resultDict["targetPercent"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("🚀 [Step 2] 목표 백분율: X=\(String(format: "%.2f", targetPercent["x"] ?? 0))%, Y=\(String(format: "%.2f", targetPercent["y"] ?? 0))%")
                }
                if let calculatedPosition = resultDict["calculatedPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("🚀 [Step 2] 계산된 위치: X=\(String(format: "%.1f", calculatedPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", calculatedPosition["y"] ?? 0))px")
                }
                if let actualPosition = resultDict["actualPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("🚀 [Step 2] 실제 위치: X=\(String(format: "%.1f", actualPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", actualPosition["y"] ?? 0))px")
                }
                if let difference = resultDict["difference"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("🚀 [Step 2] 위치 차이: X=\(String(format: "%.1f", difference["x"] ?? 0))px, Y=\(String(format: "%.1f", difference["y"] ?? 0))px")
                }
                if let method = resultDict["usedMethod"] as? String {
                    TabPersistenceManager.debugMessages.append("🚀 [Step 2] 사용된 클램핑 우회 방법: \(method)")
                }
                
                // 🔧 **수정: 임시 요소 ID 저장**
                if let tempElementId = resultDict["tempElementId"] as? String {
                    updatedContext.tempElement = tempElementId
                    TabPersistenceManager.debugMessages.append("🔧 [Step 2] 임시 요소 저장: \(tempElementId)")
                }
                
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(8) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
                
                // 클램핑 우회 성공 시 전체 성공으로 간주
                if step2Success {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("🚀 [Step 2] ✅ 클램핑 우회 성공 - 전체 복원 성공으로 간주")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🚀 [Step 2] 완료: \(step2Success ? "성공" : "실패")")
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
    
    // MARK: - Step 4: 🔧 **최종 검증 및 미세 보정 - 임시 요소 정리**
    private func executeStep4_FinalVerification(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 검증 및 미세 보정 시작")
        
        guard restorationConfig.enableFinalVerification else {
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 비활성화됨 - 스킵")
            context.completion(context.overallSuccess)
            return
        }
        
        // 🔧 **수정: 임시 요소 ID 전달**
        let tempElementId = context.tempElement as? String ?? ""
        let js = generateStep4_FinalVerificationScript(tempElementId: tempElementId)
        
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
                
                // 🔧 **임시 요소 정리 결과 로깅**
                if let tempElementCleaned = resultDict["tempElementCleaned"] as? Bool, tempElementCleaned {
                    TabPersistenceManager.debugMessages.append("🗑️ [Step 4] 임시 요소 정리 완료")
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
    
    // MARK: - JavaScript 생성 메서드들
    
    // 📄 **Step 1 강화된 페이지네이션 복원 스크립트 - 목표 스크롤 위치까지 콘텐츠 로드**
    private func generateStep1_EnhancedPaginationRestoreScript() -> String {
        let targetPage = restorationConfig.targetPageNumber
        let itemsPerPage = restorationConfig.estimatedItemsPerPage
        let paginationType = restorationConfig.paginationType.rawValue
        let targetScrollY = scrollPosition.y
        let savedContentHeight = restorationConfig.savedContentHeight
        
        return """
        (function() {
            try {
                const logs = [];
                const targetPage = parseInt('\(targetPage)');
                const itemsPerPage = parseInt('\(itemsPerPage)');
                const expectedPaginationType = '\(paginationType)';
                const targetScrollY = parseFloat('\(targetScrollY)');
                const savedContentHeight = parseFloat('\(savedContentHeight)');
                
                logs.push('[Step 1] 강화된 페이지네이션 방식 복원 시작');
                logs.push('목표 스크롤 위치: ' + targetScrollY.toFixed(1) + 'px');
                logs.push('저장된 콘텐츠 높이: ' + savedContentHeight.toFixed(0) + 'px');
                logs.push('목표 페이지: ' + targetPage + '페이지');
                logs.push('페이지당 아이템: ' + itemsPerPage + '개');
                logs.push('예상 페이지네이션 타입: ' + expectedPaginationType);
                
                // 초기 콘텐츠 높이 확인
                const initialContentHeight = Math.max(
                    document.documentElement.scrollHeight,
                    document.body.scrollHeight
                );
                logs.push('초기 콘텐츠 높이: ' + initialContentHeight.toFixed(0) + 'px');
                
                // 📄 **1. 페이지네이션 타입 자동 감지**
                function detectPaginationType() {
                    // 무한스크롤 감지
                    const infiniteScrollIndicators = [
                        '[data-testid*="infinite"]', '[class*="infinite"]',
                        '[data-testid*="lazy"]', '[class*="lazy"]',
                        '[data-testid*="virtual"]', '[class*="virtual"]'
                    ];
                    
                    for (let i = 0; i < infiniteScrollIndicators.length; i++) {
                        if (document.querySelector(infiniteScrollIndicators[i])) {
                            return 'infiniteScroll';
                        }
                    }
                    
                    // 더보기 버튼 감지
                    const loadMoreButtons = document.querySelectorAll(
                        'button[class*="more"], button[class*="load"], ' +
                        '[data-testid*="load"], [data-testid*="more"], ' +
                        '.load-more, .show-more, .btn-more'
                    );
                    
                    if (loadMoreButtons.length > 0) {
                        return 'loadMoreButton';
                    }
                    
                    // 가상 페이지네이션 감지 (스크롤 기반 페이지 분할)
                    const scrollHeight = document.documentElement.scrollHeight;
                    const viewportHeight = window.innerHeight;
                    const ratio = scrollHeight / viewportHeight;
                    
                    if (ratio > 5) { // 5배 이상이면 가상 페이지네이션으로 간주
                        return 'virtualPagination';
                    }
                    
                    return 'hybridPagination';
                }
                
                const detectedType = detectPaginationType();
                logs.push('감지된 페이지네이션 타입: ' + detectedType);
                
                // 📄 **2. MutationObserver로 콘텐츠 로드 감지**
                let contentLoaded = false;
                let observerTimeout = null;
                const observer = new MutationObserver(function(mutations, obs) {
                    const currentHeight = Math.max(
                        document.documentElement.scrollHeight,
                        document.body.scrollHeight
                    );
                    
                    // 목표 높이의 90% 이상 로드되면 성공
                    if (currentHeight >= targetScrollY * 0.9 || currentHeight >= savedContentHeight * 0.8) {
                        contentLoaded = true;
                        obs.disconnect();
                        if (observerTimeout) clearTimeout(observerTimeout);
                        logs.push('MutationObserver: 충분한 콘텐츠 로드됨 - ' + currentHeight.toFixed(0) + 'px');
                    }
                });
                
                // Observer 시작
                observer.observe(document.body, {
                    childList: true,
                    subtree: true,
                    attributes: false,
                    characterData: false
                });
                
                // Observer 타임아웃 설정 (5초)
                observerTimeout = setTimeout(function() {
                    observer.disconnect();
                }, 5000);
                
                // 📄 **3. 점진적 스크롤로 콘텐츠 로드**
                let success = false;
                let scrollAttempts = 0;
                const maxScrollAttempts = 15; // 최대 15번 시도
                const scrollStep = Math.min(3000, targetScrollY / 10); // 한 번에 3000px 또는 목표의 10%
                
                function progressiveScroll() {
                    scrollAttempts++;
                    
                    const currentHeight = Math.max(
                        document.documentElement.scrollHeight,
                        document.body.scrollHeight
                    );
                    
                    const currentScrollY = window.scrollY || window.pageYOffset || 0;
                    const progress = (currentHeight / savedContentHeight) * 100;
                    
                    logs.push('스크롤 시도 ' + scrollAttempts + ': 현재 높이=' + currentHeight.toFixed(0) + 'px, 진행률=' + progress.toFixed(1) + '%');
                    
                    // 충분한 콘텐츠가 로드되었는지 확인
                    if (currentHeight >= targetScrollY || contentLoaded) {
                        success = true;
                        logs.push('충분한 콘텐츠 로드 완료: ' + currentHeight.toFixed(0) + 'px');
                        return true;
                    }
                    
                    // 최대 시도 횟수 도달
                    if (scrollAttempts >= maxScrollAttempts) {
                        logs.push('최대 시도 횟수 도달 - 현재 높이: ' + currentHeight.toFixed(0) + 'px');
                        return false;
                    }
                    
                    // 다음 스크롤 위치 계산
                    const nextScrollY = Math.min(currentScrollY + scrollStep, currentHeight - window.innerHeight);
                    
                    // 스크롤 실행
                    window.scrollTo(0, nextScrollY);
                    
                    // 스크롤 이벤트 트리거
                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                    document.dispatchEvent(new Event('scroll', { bubbles: true }));
                    
                    // IntersectionObserver 트리거를 위한 추가 이벤트
                    const scrollEvent = new CustomEvent('scroll', { 
                        detail: { scrollY: nextScrollY },
                        bubbles: true,
                        cancelable: true
                    });
                    window.dispatchEvent(scrollEvent);
                    
                    // 무한스크롤 트리거 요소 찾기 및 활성화
                    const triggers = document.querySelectorAll(
                        '[data-infinite-scroll-trigger], [class*="scroll-trigger"], ' +
                        '[class*="load-more"], [data-testid*="load"], .sentinel'
                    );
                    
                    triggers.forEach(function(trigger) {
                        const rect = trigger.getBoundingClientRect();
                        if (rect.top < window.innerHeight * 2) { // 뷰포트 2배 거리 내에 있으면
                            // IntersectionObserver 이벤트 시뮬레이션
                            if (trigger.dispatchEvent) {
                                trigger.dispatchEvent(new Event('intersect', { bubbles: true }));
                            }
                        }
                    });
                    
                    return false; // 계속 진행
                }
                
                // 📄 **4. 더보기 버튼 클릭 (loadMoreButton 타입)**
                if (detectedType === 'loadMoreButton') {
                    const loadMoreButtons = document.querySelectorAll(
                        'button[class*="more"], button[class*="load"], ' +
                        '[data-testid*="load"], [data-testid*="more"], ' +
                        '.load-more, .show-more, .btn-more'
                    );
                    
                    let clickCount = 0;
                    const maxClicks = Math.min(10, Math.ceil(targetPage / 2));
                    
                    for (let i = 0; i < loadMoreButtons.length && clickCount < maxClicks; i++) {
                        const btn = loadMoreButtons[i];
                        if (btn && typeof btn.click === 'function' && !btn.disabled) {
                            btn.click();
                            clickCount++;
                            logs.push('더보기 버튼 클릭 ' + clickCount);
                            
                            // 잠시 대기 (Ajax 로딩 대응)
                            const now = Date.now();
                            while (Date.now() - now < 200) {} // 200ms 대기
                        }
                    }
                }
                
                // 📄 **5. 메인 실행 루프**
                let loopCount = 0;
                const maxLoops = 20;
                
                function executeScrollLoop() {
                    loopCount++;
                    
                    if (loopCount > maxLoops) {
                        logs.push('최대 루프 횟수 도달');
                        return;
                    }
                    
                    const continueScrolling = !progressiveScroll();
                    
                    if (continueScrolling) {
                        // 다음 스크롤을 비동기로 예약
                        setTimeout(executeScrollLoop, 300); // 300ms 후 다시 시도
                    } else {
                        logs.push('스크롤 루프 완료');
                    }
                }
                
                // 스크롤 루프 시작
                executeScrollLoop();
                
                // 📄 **6. 최종 대기 및 결과 확인 (동기 처리를 위한 임시 대기)**
                const startTime = Date.now();
                while (Date.now() - startTime < 2000 && !contentLoaded && !success) {
                    // 2초 동안 대기하면서 콘텐츠 로드 확인
                    const currentHeight = Math.max(
                        document.documentElement.scrollHeight,
                        document.body.scrollHeight
                    );
                    
                    if (currentHeight >= targetScrollY * 0.9) {
                        success = true;
                        contentLoaded = true;
                        break;
                    }
                    
                    // 짧은 대기
                    const now = Date.now();
                    while (Date.now() - now < 100) {} // 100ms 대기
                }
                
                // Observer 정리
                observer.disconnect();
                if (observerTimeout) clearTimeout(observerTimeout);
                
                // 📄 **7. 복원 결과 정리**
                const finalContentHeight = Math.max(
                    document.documentElement.scrollHeight,
                    document.body.scrollHeight
                );
                
                const loadProgress = (finalContentHeight / savedContentHeight) * 100;
                
                logs.push('페이지네이션 복원 완료: ' + (success ? '성공' : '부분성공'));
                logs.push('최종 콘텐츠 높이: ' + finalContentHeight.toFixed(0) + 'px');
                logs.push('콘텐츠 로드 진행률: ' + loadProgress.toFixed(1) + '%');
                logs.push('스크롤 시도 횟수: ' + scrollAttempts);
                
                return {
                    success: success || contentLoaded,
                    detectedPaginationType: detectedType,
                    targetPage: targetPage,
                    initialContentHeight: initialContentHeight,
                    finalContentHeight: finalContentHeight,
                    targetContentHeight: targetScrollY,
                    loadProgress: loadProgress,
                    scrollAttempts: scrollAttempts,
                    contentLoaded: contentLoaded,
                    restorationMethod: 'enhanced_progressive_scroll',
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    logs: ['[Step 1] 강화된 페이지네이션 복원 오류: ' + e.message]
                };
            }
        })()
        """
    }
    
    // 🚀 **Step 2: 클램핑 우회 스크롤 복원 스크립트 (핵심) - 임시 요소 유지**
    private func generateStep2_ClampingBypassScrollScript() -> String {
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        let absoluteTargetX = scrollPosition.x
        let absoluteTargetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetPercentX = parseFloat('\(targetPercentX)');
                const targetPercentY = parseFloat('\(targetPercentY)');
                const absoluteTargetX = parseFloat('\(absoluteTargetX)');
                const absoluteTargetY = parseFloat('\(absoluteTargetY)');
                
                logs.push('🚀 [Step 2] 클램핑 우회 스크롤 복원 시작');
                logs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                logs.push('목표 절대값: X=' + absoluteTargetX.toFixed(1) + 'px, Y=' + absoluteTargetY.toFixed(1) + 'px');
                
                // 🚫 브라우저 자동 스크롤 복원 완전 차단
                if (typeof history !== 'undefined' && history.scrollRestoration) {
                    history.scrollRestoration = 'manual';
                    logs.push('브라우저 자동 스크롤 복원 비활성화');
                }
                
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
                
                logs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                logs.push('최대 스크롤: X=' + maxScrollX.toFixed(0) + 'px, Y=' + maxScrollY.toFixed(0) + 'px');
                
                // 백분율 기반 목표 위치 계산
                const calculatedTargetX = (targetPercentX / 100) * maxScrollX;
                const calculatedTargetY = (targetPercentY / 100) * maxScrollY;
                
                // 절대값과 백분율 중 더 정확한 값 선택 (절대값 우선)
                const finalTargetX = absoluteTargetX > 0 ? absoluteTargetX : calculatedTargetX;
                const finalTargetY = absoluteTargetY > 0 ? absoluteTargetY : calculatedTargetY;
                
                logs.push('계산된 백분율 위치: X=' + calculatedTargetX.toFixed(1) + 'px, Y=' + calculatedTargetY.toFixed(1) + 'px');
                logs.push('최종 목표 위치: X=' + finalTargetX.toFixed(1) + 'px, Y=' + finalTargetY.toFixed(1) + 'px');
                
                let usedMethod = 'none';
                let success = false;
                let tempElementId = null; // 🔧 **임시 요소 ID 저장**
                
                // 🎯 **클램핑 우회 방법 결정**
                const CLAMPING_THRESHOLD = 3000; // 3000px 이상일 때 클램핑 우회 적용
                const needsBypass = finalTargetY > CLAMPING_THRESHOLD;
                
                logs.push('클램핑 우회 필요: ' + (needsBypass ? 'YES (>' + CLAMPING_THRESHOLD + 'px)' : 'NO'));
                
                if (needsBypass) {
                    // 🚀 **방법 1: 임시 앵커 + scrollIntoView**
                    try {
                        logs.push('🎯 방법 1 시도: 임시 앵커 + scrollIntoView');
                        
                        const tempAnchor = document.createElement('div');
                        tempElementId = 'bfcache-temp-anchor-' + Date.now();
                        tempAnchor.id = tempElementId;
                        tempAnchor.style.cssText = 
                            'position: absolute; ' +
                            'top: ' + finalTargetY + 'px; ' +
                            'left: ' + finalTargetX + 'px; ' +
                            'width: 1px; ' +
                            'height: 1px; ' +
                            'visibility: hidden; ' +
                            'pointer-events: none; ' +
                            'z-index: -9999;';
                        
                        document.body.appendChild(tempAnchor);
                        
                        // scrollIntoView로 바로 점프
                        tempAnchor.scrollIntoView({ 
                            behavior: 'auto', 
                            block: 'start',
                            inline: 'start'
                        });
                        
                        // 위치 확인
                        const afterScrollY = window.scrollY || window.pageYOffset || 0;
                        const diffY = Math.abs(afterScrollY - finalTargetY);
                        
                        if (diffY <= 200) {
                            success = true;
                            usedMethod = 'temp_anchor_scrollIntoView';
                            logs.push('🎯 방법 1 성공: ' + afterScrollY.toFixed(1) + 'px (오차: ' + diffY.toFixed(1) + 'px)');
                            logs.push('🔧 임시 요소 유지: ' + tempElementId);
                            // 🔧 **임시 요소를 제거하지 않음**
                        } else {
                            logs.push('🎯 방법 1 실패: ' + afterScrollY.toFixed(1) + 'px (오차: ' + diffY.toFixed(1) + 'px)');
                            // 실패시 임시 요소 제거
                            if (tempAnchor.parentNode) {
                                tempAnchor.parentNode.removeChild(tempAnchor);
                                tempElementId = null;
                            }
                        }
                    } catch(e) {
                        logs.push('🎯 방법 1 오류: ' + e.message);
                    }
                    
                    // 🚀 **방법 2: scrollTop 직접 설정 (방법 1 실패 시)**
                    if (!success) {
                        try {
                            logs.push('🎯 방법 2 시도: scrollTop 직접 설정');
                            
                            // 여러 방법으로 scrollTop 설정
                            document.documentElement.scrollTop = finalTargetY;
                            document.documentElement.scrollLeft = finalTargetX;
                            document.body.scrollTop = finalTargetY;
                            document.body.scrollLeft = finalTargetX;
                            
                            if (document.scrollingElement) {
                                document.scrollingElement.scrollTop = finalTargetY;
                                document.scrollingElement.scrollLeft = finalTargetX;
                            }
                            
                            // 강제 스크롤 (WebKit 특화)
                            if (typeof window.scrollTo === 'function') {
                                window.scrollTo({
                                    top: finalTargetY,
                                    left: finalTargetX,
                                    behavior: 'auto'
                                });
                            }
                            
                            // 위치 확인
                            const afterScrollY = window.scrollY || window.pageYOffset || 0;
                            const diffY = Math.abs(afterScrollY - finalTargetY);
                            
                            if (diffY <= 200) {
                                success = true;
                                usedMethod = 'direct_scrollTop';
                                logs.push('🎯 방법 2 성공: ' + afterScrollY.toFixed(1) + 'px (오차: ' + diffY.toFixed(1) + 'px)');
                            } else {
                                logs.push('🎯 방법 2 실패: ' + afterScrollY.toFixed(1) + 'px (오차: ' + diffY.toFixed(1) + 'px)');
                            }
                        } catch(e) {
                            logs.push('🎯 방법 2 오류: ' + e.message);
                        }
                    }
                    
                    // 🚀 **방법 3: 임시 높이 확장 (방법 1,2 실패 시) - 임시 요소 유지**
                    if (!success) {
                        try {
                            logs.push('🎯 방법 3 시도: 임시 높이 확장');
                            
                            const tempDiv = document.createElement('div');
                            tempElementId = 'bfcache-temp-height-' + Date.now();
                            tempDiv.id = tempElementId;
                            tempDiv.style.cssText = 
                                'position: absolute; ' +
                                'top: 0; ' +
                                'left: 0; ' +
                                'width: 1px; ' +
                                'height: ' + (finalTargetY + 2000) + 'px; ' +
                                'visibility: hidden; ' +
                                'pointer-events: none; ' +
                                'z-index: -9999;';
                            
                            document.body.appendChild(tempDiv);
                            
                            // 확장된 높이로 스크롤
                            window.scrollTo(finalTargetX, finalTargetY);
                            
                            // 위치 확인
                            const afterScrollY = window.scrollY || window.pageYOffset || 0;
                            const diffY = Math.abs(afterScrollY - finalTargetY);
                            
                            if (diffY <= 200) {
                                success = true;
                                usedMethod = 'temp_height_expansion';
                                logs.push('🎯 방법 3 성공: ' + afterScrollY.toFixed(1) + 'px (오차: ' + diffY.toFixed(1) + 'px)');
                                logs.push('🔧 임시 요소 유지: ' + tempElementId);
                                // 🔧 **임시 요소를 제거하지 않음**
                            } else {
                                logs.push('🎯 방법 3 실패: ' + afterScrollY.toFixed(1) + 'px (오차: ' + diffY.toFixed(1) + 'px)');
                                // 실패시 임시 요소 제거
                                if (tempDiv.parentNode) {
                                    tempDiv.parentNode.removeChild(tempDiv);
                                    tempElementId = null;
                                }
                            }
                        } catch(e) {
                            logs.push('🎯 방법 3 오류: ' + e.message);
                        }
                    }
                    
                } else {
                    // 🔧 **일반 스크롤 (클램핑 우회 불필요)**
                    logs.push('🔧 일반 스크롤 방법 사용');
                    
                    try {
                        // 기본 scrollTo 사용
                        window.scrollTo(finalTargetX, finalTargetY);
                        document.documentElement.scrollTop = finalTargetY;
                        document.documentElement.scrollLeft = finalTargetX;
                        document.body.scrollTop = finalTargetY;
                        document.body.scrollLeft = finalTargetX;
                        
                        if (document.scrollingElement) {
                            document.scrollingElement.scrollTop = finalTargetY;
                            document.scrollingElement.scrollLeft = finalTargetX;
                        }
                        
                        // 위치 확인
                        const afterScrollY = window.scrollY || window.pageYOffset || 0;
                        const diffY = Math.abs(afterScrollY - finalTargetY);
                        
                        if (diffY <= 50) {
                            success = true;
                            usedMethod = 'standard_scrollTo';
                            logs.push('🔧 일반 스크롤 성공: ' + afterScrollY.toFixed(1) + 'px (오차: ' + diffY.toFixed(1) + 'px)');
                        } else {
                            logs.push('🔧 일반 스크롤 실패: ' + afterScrollY.toFixed(1) + 'px (오차: ' + diffY.toFixed(1) + 'px)');
                        }
                    } catch(e) {
                        logs.push('🔧 일반 스크롤 오류: ' + e.message);
                    }
                }
                
                // 최종 위치 측정
                const actualX = window.scrollX || window.pageXOffset || 0;
                const actualY = window.scrollY || window.pageYOffset || 0;
                
                const diffX = Math.abs(actualX - finalTargetX);
                const diffY = Math.abs(actualY - finalTargetY);
                
                logs.push('최종 결과: ' + (success ? '성공' : '실패'));
                logs.push('사용된 방법: ' + usedMethod);
                logs.push('최종 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                logs.push('최종 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                return {
                    success: success,
                    usedMethod: usedMethod,
                    targetPercent: { x: targetPercentX, y: targetPercentY },
                    calculatedPosition: { x: calculatedTargetX, y: calculatedTargetY },
                    finalTarget: { x: finalTargetX, y: finalTargetY },
                    actualPosition: { x: actualX, y: actualY },
                    difference: { x: diffX, y: diffY },
                    bypassApplied: needsBypass,
                    tempElementId: tempElementId, // 🔧 **임시 요소 ID 반환**
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    usedMethod: 'error',
                    tempElementId: null,
                    logs: ['🚀 [Step 2] 클램핑 우회 스크롤 오류: ' + e.message]
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
                                logs.push('페이지 오프셋으로 매칭: ' + estimatedY.toFixed(0) + 'px (오차: ' + minDistance.toFixed(0) + 'px)');
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
                    logs.push('매칭 신뢰도: ' + confidence + '%');
                    
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
    
    // 🔧 **수정: Step 4에서 임시 요소 정리**
    private func generateStep4_FinalVerificationScript(tempElementId: String = "") -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const tempElementId = '\(tempElementId)';
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
                let tempElementCleaned = false;
                
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
                
                // 🔧 **임시 요소 정리 (최종 검증 후)**
                if (tempElementId && tempElementId.length > 0) {
                    try {
                        const tempElement = document.getElementById(tempElementId);
                        if (tempElement && tempElement.parentNode) {
                            tempElement.parentNode.removeChild(tempElement);
                            tempElementCleaned = true;
                            logs.push('🗑️ 임시 요소 정리: ' + tempElementId);
                        } else {
                            logs.push('🗑️ 임시 요소 이미 없음: ' + tempElementId);
                        }
                    } catch(cleanupError) {
                        logs.push('🗑️ 임시 요소 정리 실패: ' + cleanupError.message);
                    }
                } else {
                    logs.push('🗑️ 정리할 임시 요소 없음');
                }
                
                const success = diffY <= 50;
                
                return {
                    success: success,
                    targetPosition: { x: targetX, y: targetY },
                    finalPosition: { x: currentX, y: currentY },
                    finalDifference: { x: diffX, y: diffY },
                    withinTolerance: diffX <= tolerance && diffY <= tolerance,
                    correctionApplied: correctionApplied,
                    tempElementCleaned: tempElementCleaned,
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    tempElementCleaned: false,
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
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🚀 무한스크롤 + 페이지네이션 앵커 캡처)**
    
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
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 + 페이지네이션 앵커 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
        
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 + 페이지네이션 앵커 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
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
            
            // 📄 **페이지네이션 정보 로깅**
            if let paginationInfo = jsState["paginationInfo"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("📄 캡처된 페이지네이션 정보: \(paginationInfo)")
            }
            
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
        
        TabPersistenceManager.debugMessages.append("✅ 무한스크롤 + 페이지네이션 앵커 직렬 캡처 완료: \(task.pageRecord.title)")
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
        
        // 3. ✅ **수정: 무한스크롤 + 페이지네이션 JS 상태 캡처** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 + 페이지네이션 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateInfiniteScrollPaginationCaptureScript() // 🚀 **수정된: 무한스크롤 + 페이지네이션 캡처**
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                    
                    // 📄 **페이지네이션 정보 로깅**
                    if let paginationInfo = data["paginationInfo"] as? [String: Any] {
                        TabPersistenceManager.debugMessages.append("📄 JS 캡처된 페이지네이션 정보: \(paginationInfo)")
                    }
                    
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
            enablePaginationRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height),
            targetPageNumber: 1, // 기본값, jsState에서 실제 값 추출됨
            estimatedItemsPerPage: 20, // 기본값, jsState에서 실제 값 추출됨
            paginationType: .infiniteScroll, // 기본값, jsState에서 실제 값 추출됨
            step1RenderDelay: 1.2,
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
            restorationConfig: restorationConfig
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🚀 **수정: JavaScript 무한스크롤 + 페이지네이션 캡처 스크립트 개선**
    private func generateInfiniteScrollPaginationCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 무한스크롤 + 페이지네이션 캡처 시작');
                
                // 📊 **상세 로그 수집**
                const detailedLogs = [];
                const pageAnalysis = {};
                
                // 기본 정보 수집
                const scrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                const scrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                
                detailedLogs.push('🚀 무한스크롤 + 페이지네이션 캡처 시작');
                detailedLogs.push('스크롤 위치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포트 크기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                console.log('🚀 기본 정보:', {
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                // 📄 **1. 페이지네이션 정보 수집**
                function collectPaginationInfo() {
                    const paginationInfo = {
                        paginationType: 'infiniteScroll', // 기본값
                        currentPage: 1,
                        itemsPerPage: 20,
                        totalItems: 0,
                        estimatedTotalPages: 1,
                        hasLoadMoreButton: false,
                        isInfiniteScroll: false,
                        isVirtualPagination: false
                    };
                    
                    detailedLogs.push('📄 페이지네이션 정보 수집 시작');
                    
                    // 아이템 수 계산
                    const itemSelectors = [
                        'li', '.item', '.list-item', '.card', '.post', '.article',
                        '.comment', '.reply', '.feed', '.thread', '.message', '.product',
                        '[class*="item"]', '[class*="post"]', '[class*="card"]',
                        '[data-testid]', '[data-id]', '[data-key]', '[data-item-id]'
                    ];
                    
                    let totalVisibleItems = 0;
                    for (let i = 0; i < itemSelectors.length; i++) {
                        try {
                            const elements = document.querySelectorAll(itemSelectors[i]);
                            for (let j = 0; j < elements.length; j++) {
                                const element = elements[j];
                                const rect = element.getBoundingClientRect();
                                if (rect.height > 10 && rect.width > 10) { // 최소 크기 필터
                                    totalVisibleItems++;
                                }
                            }
                        } catch(e) {
                            // selector 오류 무시
                        }
                    }
                    
                    // 중복 제거 추정 (보수적으로 50% 적용)
                    const estimatedUniqueItems = Math.floor(totalVisibleItems * 0.5);
                    paginationInfo.totalItems = Math.max(estimatedUniqueItems, 1);
                    
                    detailedLogs.push('📄 감지된 아이템: ' + totalVisibleItems + '개 (중복제거 후: ' + estimatedUniqueItems + '개)');
                    
                    // 더보기 버튼 감지
                    const loadMoreButtons = document.querySelectorAll(
                        'button[class*="more"], button[class*="load"], ' +
                        '[data-testid*="load"], [data-testid*="more"], ' +
                        '.load-more, .show-more, .btn-more'
                    );
                    paginationInfo.hasLoadMoreButton = loadMoreButtons.length > 0;
                    
                    // 무한스크롤 감지
                    const infiniteScrollIndicators = document.querySelectorAll(
                        '[data-testid*="infinite"], [class*="infinite"], ' +
                        '[data-testid*="lazy"], [class*="lazy"], ' +
                        '[data-testid*="virtual"], [class*="virtual"]'
                    );
                    paginationInfo.isInfiniteScroll = infiniteScrollIndicators.length > 0;
                    
                    // 가상 페이지네이션 감지 (긴 스크롤 기준)
                    const scrollRatio = contentHeight / viewportHeight;
                    paginationInfo.isVirtualPagination = scrollRatio > 3;
                    
                    // 페이지네이션 타입 결정
                    if (paginationInfo.isInfiniteScroll) {
                        paginationInfo.paginationType = 'infiniteScroll';
                    } else if (paginationInfo.hasLoadMoreButton) {
                        paginationInfo.paginationType = 'loadMoreButton';
                    } else if (paginationInfo.isVirtualPagination) {
                        paginationInfo.paginationType = 'virtualPagination';
                    } else {
                        paginationInfo.paginationType = 'hybridPagination';
                    }
                    
                    // 페이지당 아이템 수 추정 (뷰포트 기반)
                    const itemsPerViewport = Math.floor(viewportHeight / 150); // 아이템 평균 높이 150px 가정
                    paginationInfo.itemsPerPage = Math.max(10, Math.min(50, itemsPerViewport * 2)); // 10-50 범위
                    
                    // 현재 페이지 추정
                    paginationInfo.currentPage = Math.max(1, Math.ceil(paginationInfo.totalItems / paginationInfo.itemsPerPage));
                    
                    // 총 페이지 수 추정
                    paginationInfo.estimatedTotalPages = Math.max(1, Math.ceil(paginationInfo.totalItems / paginationInfo.itemsPerPage));
                    
                    detailedLogs.push('📄 페이지네이션 타입: ' + paginationInfo.paginationType);
                    detailedLogs.push('📄 현재 페이지: ' + paginationInfo.currentPage + ' / ' + paginationInfo.estimatedTotalPages);
                    detailedLogs.push('📄 페이지당 아이템: ' + paginationInfo.itemsPerPage + '개');
                    detailedLogs.push('📄 더보기 버튼: ' + (paginationInfo.hasLoadMoreButton ? '있음' : '없음'));
                    detailedLogs.push('📄 무한스크롤: ' + (paginationInfo.isInfiniteScroll ? '감지됨' : '감지안됨'));
                    
                    return paginationInfo;
                }
                
                // 📄 **페이지네이션 정보 수집 실행**
                const paginationInfo = collectPaginationInfo();
                
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
                        structuralPathAnchors: 0,
                        intersectionAnchors: 0,
                        finalAnchors: 0
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
                        // 네이버 카페 특화 선택자 추가
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
                    
                    anchorStats.finalAnchors = anchors.length;
                    
                    detailedLogs.push('무한스크롤 앵커 생성 완료: ' + anchors.length + '개');
                    console.log('🚀 무한스크롤 앵커 수집 완료:', anchors.length, '개');
                    
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
                        
                        // 클래스명에서 컴포넌트 이름 추출 - 네이버 카페 특화
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
                
                // 🚀 **메인 실행 - 무한스크롤 + 페이지네이션 데이터 수집**
                const startTime = Date.now();
                const infiniteScrollAnchorsData = collectInfiniteScrollAnchors();
                const endTime = Date.now();
                const captureTime = endTime - startTime;
                
                pageAnalysis.capturePerformance = {
                    totalTime: captureTime,
                    anchorsPerSecond: infiniteScrollAnchorsData.anchors.length > 0 ? (infiniteScrollAnchorsData.anchors.length / (captureTime / 1000)).toFixed(2) : 0
                };
                
                detailedLogs.push('=== 무한스크롤 + 페이지네이션 캡처 완료 (' + captureTime + 'ms) ===');
                detailedLogs.push('최종 무한스크롤 앵커: ' + infiniteScrollAnchorsData.anchors.length + '개');
                detailedLogs.push('페이지네이션 정보: ' + paginationInfo.paginationType + ' (' + paginationInfo.currentPage + '/' + paginationInfo.estimatedTotalPages + '페이지)');
                detailedLogs.push('처리 성능: ' + pageAnalysis.capturePerformance.anchorsPerSecond + ' 앵커/초');
                
                console.log('🚀 무한스크롤 + 페이지네이션 캡처 완료:', {
                    infiniteScrollAnchorsCount: infiniteScrollAnchorsData.anchors.length,
                    paginationInfo: paginationInfo,
                    stats: infiniteScrollAnchorsData.stats,
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight],
                    captureTime: captureTime,
                    actualViewportRect: actualViewportRect
                });
                
                // ✅ **수정: 정리된 반환 구조**
                return {
                    infiniteScrollAnchors: infiniteScrollAnchorsData, // 🚀 **무한스크롤 앵커 데이터**
                    paginationInfo: paginationInfo,                  // 📄 **페이지네이션 정보**
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
                    captureStats: infiniteScrollAnchorsData.stats,  // 🔧 **무한스크롤 앵커 통계**
                    pageAnalysis: pageAnalysis,                 // 📊 **페이지 분석 결과**
                    captureTime: captureTime                    // 📊 **캡처 소요 시간**
                };
            } catch(e) { 
                console.error('🚀 무한스크롤 + 페이지네이션 캡처 실패:', e);
                return {
                    infiniteScrollAnchors: { anchors: [], stats: {} },
                    paginationInfo: {
                        paginationType: 'infiniteScroll',
                        currentPage: 1,
                        itemsPerPage: 20,
                        totalItems: 0,
                        estimatedTotalPages: 1,
                        hasLoadMoreButton: false,
                        isInfiniteScroll: false,
                        isVirtualPagination: false
                    },
                    scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message,
                    detailedLogs: ['무한스크롤 + 페이지네이션 캡처 실패: ' + e.message],
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
