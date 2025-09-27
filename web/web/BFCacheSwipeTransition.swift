//
//  BFCacheSnapshotManager.swift
//  📸 **순차적 4단계 BFCache 복원 시스템**
//  🎯 **Step 1**: 저장 콘텐츠 높이 복원 (동적 사이트만) + 🆕 Lazy Loading 우선 트리거 + 부모 스크롤 복원
//  📏 **Step 2**: 상대좌표 기반 스크롤 복원 (최우선)
//  🔍 **Step 3**: 무한스크롤 전용 앵커 정밀 복원 + 🆕 IntersectionObserver 검증
//  ✅ **Step 4**: 최종 검증 및 미세 보정
//  ⏰ **렌더링 대기**: 각 단계별 필수 대기시간 적용
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용
//  🚀 **무한스크롤 강화**: 최대 8번 트리거 시도
//  🆕 **네이버 카페 스크롤 로직 통합**: Lazy Loading 우선 + 부모 컨테이너 복원 + IO 검증
//  🐛 **디버그 강화**: 이벤트/히스토리 추적 로깅 추가
//  🎯 **하단 더보기 선택자 개선**: 상단 탭/카테고리 제외, 하단 영역만 선택
//  🚫 **개선**: A.btn_more, A.item_more 선택자 제외
//  🔄 **개선**: iframe 내부 앵커 재귀적 수집
//  ⚡ **개선**: Step 1 강도 조절 (증가 없으면 중단)

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
        let enableLazyLoadingTrigger: Bool  // 🆕 Lazy Loading 트리거
        let enableParentScrollRestore: Bool // 🆕 부모 컨테이너 스크롤 복원
        let enableIOVerification: Bool      // 🆕 IntersectionObserver 검증
        
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
            enableLazyLoadingTrigger: true,  // 🆕
            enableParentScrollRestore: true, // 🆕
            enableIOVerification: true       // 🆕
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
            step4RenderDelay: restorationConfig.step4RenderDelay,
            enableLazyLoadingTrigger: restorationConfig.enableLazyLoadingTrigger,
            enableParentScrollRestore: restorationConfig.enableParentScrollRestore,
            enableIOVerification: restorationConfig.enableIOVerification
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
        TabPersistenceManager.debugMessages.append("🆕 Lazy Loading 트리거: \(restorationConfig.enableLazyLoadingTrigger ? "활성화" : "비활성화")")
        TabPersistenceManager.debugMessages.append("🆕 부모 스크롤 복원: \(restorationConfig.enableParentScrollRestore ? "활성화" : "비활성화")")
        TabPersistenceManager.debugMessages.append("🆕 IO 검증: \(restorationConfig.enableIOVerification ? "활성화" : "비활성화")")
        
        // 복원 컨텍스트 생성
        let context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: completion
        )
        
        // Step 1 시작
        executeStep1_RestoreContentHeight(context: context)
    }
    
    // MARK: - Step 1: 🆕 Lazy Loading 트리거 → 부모 스크롤 복원 → 콘텐츠 높이 복원 + ⚡ 강도 조절
    private func executeStep1_RestoreContentHeight(context: RestorationContext, attempt: Int = 0) {
        TabPersistenceManager.debugMessages.append("📦 [Step 1] Lazy Loading 트리거 + 부모 스크롤 + 콘텐츠 복원 시작")
        
        guard restorationConfig.enableContentRestore else {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 비활성화됨 - 스킵")
            // 렌더링 대기 후 다음 단계
            DispatchQueue.main.asyncAfter(deadline: .now() + restorationConfig.step1RenderDelay) {
                self.executeStep2_PercentScroll(context: context)
            }
            return
        }
        
        // 🆕 부모 스크롤 복원 데이터 추출
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
            let maxStep1Retries = 2
            var shouldRetry = false
            var percentageValue: Double = 0
            var targetHeightValue: Double = 0
            var isStaticSiteFlag = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step1Success = (resultDict["success"] as? Bool) ?? false
                
                // 🆕 Lazy Loading 결과
                if let lazyLoadingResults = resultDict["lazyLoadingResults"] as? [String: Any] {
                    if let triggered = lazyLoadingResults["triggered"] as? Int {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 1] Lazy Loading 트리거: \(triggered)개")
                    }
                    if let method = lazyLoadingResults["method"] as? String {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 1] Lazy Loading 방식: \(method)")
                    }
                }
                
                // 🆕 부모 스크롤 복원 결과
                if let parentScrollCount = resultDict["parentScrollCount"] as? Int {
                    TabPersistenceManager.debugMessages.append("🆕 [Step 1] 부모 스크롤 복원: \(parentScrollCount)개")
                }
                if let parentScrollResults = resultDict["parentScrollResults"] as? [[String: Any]] {
                    for result in parentScrollResults.prefix(3) {
                        if let selector = result["selector"] as? String,
                           let success = result["success"] as? Bool {
                            TabPersistenceManager.debugMessages.append("   \(selector): \(success ? "성공" : "실패")")
                        }
                    }
                }
                
                // 🐛 **디버그: 이벤트 추적 결과**
                if let eventDebug = resultDict["eventDebugResults"] as? [String: Any] {
                    if let domEventTargets = eventDebug["domEventTargets"] as? [String] {
                        TabPersistenceManager.debugMessages.append("🐛 [Step 1] 이벤트가 닿은 DOM: \(domEventTargets.prefix(5).joined(separator: ", "))")
                    }
                    if let historyPushStates = eventDebug["historyPushStates"] as? [String] {
                        TabPersistenceManager.debugMessages.append("🐛 [Step 1] pushState 호출: \(historyPushStates.prefix(3).joined(separator: ", "))")
                    }
                    if let navigationAttempts = eventDebug["navigationAttempts"] as? [String] {
                        TabPersistenceManager.debugMessages.append("🐛 [Step 1] 네비게이션 시도: \(navigationAttempts.prefix(3).joined(separator: ", "))")
                    }
                }
                
                // 기존 콘텐츠 복원 결과
                if let currentHeight = resultDict["currentHeight"] as? Double {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 현재 높이: \(String(format: "%.0f", currentHeight))px")
                }
                if let targetHeight = resultDict["targetHeight"] as? Double {
                    targetHeightValue = targetHeight
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 목표 높이: \(String(format: "%.0f", targetHeight))px")
                }
                if let restoredHeight = resultDict["restoredHeight"] as? Double {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 복원된 높이: \(String(format: "%.0f", restoredHeight))px")
                }
                if let percentage = resultDict["percentage"] as? Double {
                    percentageValue = percentage
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 복원률: \(String(format: "%.1f", percentage))%")
                }
                
                let isStaticSite = (resultDict["isStaticSite"] as? Bool) ?? false
                isStaticSiteFlag = isStaticSite
                if isStaticSite {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 정적 사이트 - 콘텐츠 복원 불필요")
                }
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(5) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }

                if !step1Success && !isStaticSiteFlag && targetHeightValue > 0 && percentageValue < 70 && attempt < maxStep1Retries {
                    shouldRetry = true
                    TabPersistenceManager.debugMessages.append("🔄 [Step 1] 복원률 부족 - 재시도 예정 (\(attempt + 1)/\(maxStep1Retries + 1))")
                } else if !step1Success && attempt >= maxStep1Retries && !shouldRetry {
                    TabPersistenceManager.debugMessages.append("⚠️ [Step 1] 복원 재시도 한계 도달")
                }
            }
            
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 완료: \(step1Success ? "성공" : "실패") - \(shouldRetry ? "재시도 진행" : "다음 단계 이동")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 1] 렌더링 대기: \(self.restorationConfig.step1RenderDelay)초")
            
            // 성공/실패 관계없이 다음 단계 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.step1RenderDelay) {
                if shouldRetry {
                    self.executeStep1_RestoreContentHeight(context: context, attempt: attempt + 1)
                } else {
                    self.executeStep2_PercentScroll(context: context)
                }
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
    
    // MARK: - Step 3: 무한스크롤 전용 앵커 복원 + 🆕 IntersectionObserver 검증
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 무한스크롤 전용 앵커 정밀 복원 시작 (IO 검증 포함)")
        
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
        
        let js = generateStep3_InfiniteScrollAnchorRestoreScriptWithIO(
            anchorDataJSON: infiniteScrollAnchorDataJSON,
            enableIOVerification: restorationConfig.enableIOVerification
        )
        
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
                
                // 🆕 IntersectionObserver 검증 결과
                if let ioResults = resultDict["ioVerification"] as? [String: Any] {
                    if let visibleAnchors = ioResults["visibleAnchors"] as? Int {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 3] IO 검증: \(visibleAnchors)개 앵커 뷰포트 내 확인")
                    }
                    if let targetAnchorVisible = ioResults["targetAnchorVisible"] as? Bool {
                        TabPersistenceManager.debugMessages.append("🆕 [Step 3] 타겟 앵커 가시성: \(targetAnchorVisible ? "보임" : "안 보임")")
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
    
    // MARK: - JavaScript 생성 메서드들
    
    // 🆕 Step 1 개선: Lazy Loading 우선 트리거 + 부모 스크롤 복원 + 콘텐츠 복원 + 🐛 디버그 강화 + 🎯 하단 더보기 선택자 개선 + 🚫 A.btn_more, A.item_more 제외 + ⚡ 강도 조절
    private func generateStep1_LazyLoadAndContentRestoreScript(parentScrollDataJSON: String, enableLazyLoading: Bool) -> String {
        let targetHeight = restorationConfig.savedContentHeight
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetHeight = parseFloat('\(targetHeight)') || 0;
                const targetY = parseFloat('\(targetY)') || 0;
                const parentScrollStates = \(parentScrollDataJSON);
                const enableLazyLoading = \(enableLazyLoading ? "true" : "false");
                
                // 🐛 **디버그 강화: 이벤트 및 히스토리 추적**
                const eventDebugResults = {
                    domEventTargets: [],
                    historyPushStates: [],
                    navigationAttempts: [],
                    clickedElements: [],
                    scrollEventTargets: []
                };
                
                // 🐛 **history.pushState 모니터링**
                const originalPushState = window.history.pushState;
                window.history.pushState = function(state, title, url) {
                    eventDebugResults.historyPushStates.push('[pushState] url=' + (url || 'null') + ', title=' + (title || 'null') + ', state=' + JSON.stringify(state));
                    logs.push('🐛 pushState 감지: ' + (url || 'null'));
                    return originalPushState.apply(this, arguments);
                };
                
                // 🐛 **네비게이션 이벤트 모니터링**
                const originalLocation = window.location.href;
                function checkNavigation() {
                    const newLocation = window.location.href;
                    if (newLocation !== originalLocation) {
                        eventDebugResults.navigationAttempts.push('[Navigation] ' + originalLocation + ' -> ' + newLocation);
                        logs.push('🐛 네비게이션 감지: ' + newLocation);
                    }
                }
                
                // 🐛 **DOM 이벤트 추적 함수**
                function trackEventTarget(eventType, target) {
                    try {
                        let targetInfo = target.tagName || 'unknown';
                        if (target.id) targetInfo += '#' + target.id;
                        if (target.className) targetInfo += '.' + target.className.split(' ')[0];
                        if (target.textContent) {
                            const text = target.textContent.trim().substring(0, 30);
                            if (text) targetInfo += ' "' + text + '"';
                        }
                        eventDebugResults.domEventTargets.push('[' + eventType + '] ' + targetInfo);
                        logs.push('🐛 ' + eventType + ' 이벤트 대상: ' + targetInfo);
                    } catch(e) {
                        eventDebugResults.domEventTargets.push('[' + eventType + '] 추적 실패: ' + e.message);
                    }
                }
                
                const currentHeight = Math.max(
                    document.documentElement ? document.documentElement.scrollHeight : 0,
                    document.body ? document.body.scrollHeight : 0
                ) || 0;
                
                logs.push('[Step 1] 🐛 디버그 강화 - Lazy Loading + 부모 스크롤 + 콘텐츠 복원 시작');
                logs.push('현재 높이: ' + currentHeight.toFixed(0) + 'px');
                logs.push('목표 높이: ' + targetHeight.toFixed(0) + 'px');
                logs.push('목표 Y 위치: ' + targetY.toFixed(0) + 'px');
                
                // 🆕 Phase 1: Lazy Loading 트리거 (Lozad 스타일)
                const lazyLoadingResults = {
                    triggered: 0,
                    method: 'none'
                };
                
                if (enableLazyLoading) {
                    logs.push('🆕 Phase 1: Lazy Loading 트리거 시작');
                    
                    // 1. 목표 위치로 임시 스크롤 (lazy loading 트리거용)
                    window.scrollTo(0, targetY);
                    document.documentElement.scrollTop = targetY;
                    document.body.scrollTop = targetY;
                    
                    // 🐛 스크롤 이벤트 대상 추적
                    trackEventTarget('scroll', document.body);
                    eventDebugResults.scrollEventTargets.push('window, documentElement, body');
                    
                    // 2. Lozad 스타일 triggerLoad 함수 찾기 및 실행
                    if (typeof window.lozad !== 'undefined' && window.lozad.triggerLoad) {
                        try {
                            // 모든 lazy 요소에 대해 triggerLoad 실행
                            const lazyElements = document.querySelectorAll('.lozad, [data-src], [data-background-image]');
                            lazyElements.forEach(function(element) {
                                if (typeof window.lozad.triggerLoad === 'function') {
                                    window.lozad.triggerLoad(element);
                                    lazyLoadingResults.triggered++;
                                }
                            });
                            lazyLoadingResults.method = 'lozad';
                            logs.push('Lozad triggerLoad 실행: ' + lazyLoadingResults.triggered + '개');
                        } catch(e) {
                            logs.push('Lozad triggerLoad 실행 오류: ' + e.message);
                        }
                    }
                    
                    // 3. IntersectionObserver 기반 lazy loading 트리거
                    const lazyImages = document.querySelectorAll('img[loading="lazy"], img[data-src], iframe[loading="lazy"]');
                    lazyImages.forEach(function(element) {
                        // data-src가 있으면 src로 복사
                        if (element.dataset.src && !element.src) {
                            element.src = element.dataset.src;
                            lazyLoadingResults.triggered++;
                        }
                        
                        // loading 속성 제거하여 즉시 로드
                        if (element.loading === 'lazy') {
                            element.loading = 'eager';
                            lazyLoadingResults.triggered++;
                        }
                    });
                    
                    if (lazyLoadingResults.method === 'none' && lazyLoadingResults.triggered > 0) {
                        lazyLoadingResults.method = 'intersection_observer';
                    }
                    
                    logs.push('Lazy 이미지 트리거: ' + lazyLoadingResults.triggered + '개');
                    
                    // 4. 스크롤 이벤트 디스패치 (lazy loading 활성화)
                    const scrollEvent = new Event('scroll', { bubbles: true });
                    window.dispatchEvent(scrollEvent);
                    trackEventTarget('scroll_dispatch', window);
                    
                    window.dispatchEvent(new Event('resize', { bubbles: true }));
                    document.dispatchEvent(new Event('scroll', { bubbles: true }));
                    
                    // 5. 강제 리플로우 (IntersectionObserver 트리거)
                    void(document.body.offsetHeight);
                }
                
                // 🆕 Phase 2: 부모 컨테이너 스크롤 복원 (네이버 카페 스타일)
                let parentScrollCount = 0;
                const parentScrollResults = [];
                
                if (parentScrollStates && parentScrollStates.length > 0) {
                    logs.push('🆕 Phase 2: 부모 스크롤 복원 시작: ' + parentScrollStates.length + '개');
                    
                    for (let i = 0; i < parentScrollStates.length; i++) {
                        const state = parentScrollStates[i];
                        if (state.selector) {
                            const element = document.querySelector(state.selector);
                            if (element) {
                                element.scrollTop = state.scrollTop || 0;
                                element.scrollLeft = state.scrollLeft || 0;
                                parentScrollCount++;
                                parentScrollResults.push({
                                    selector: state.selector,
                                    success: true,
                                    scrollTop: state.scrollTop,
                                    scrollLeft: state.scrollLeft
                                });
                                logs.push('부모 스크롤 복원 성공: ' + state.selector);
                                
                                // 🐛 부모 스크롤 이벤트 추적
                                trackEventTarget('parent_scroll', element);
                            } else {
                                parentScrollResults.push({
                                    selector: state.selector,
                                    success: false,
                                    reason: 'element_not_found'
                                });
                                logs.push('부모 스크롤 복원 실패: ' + state.selector + ' (요소 없음)');
                            }
                        }
                    }
                }
                
                // Phase 3: 콘텐츠 높이 복원 (기존 로직)
                logs.push('Phase 3: 콘텐츠 높이 복원');
                
                // 타입 안전성 체크
                if (!targetHeight || targetHeight === 0) {
                    logs.push('목표 높이가 유효하지 않음 - 스킵');
                    
                    // 🐛 디버그 결과 복원
                    window.history.pushState = originalPushState;
                    
                    return {
                        success: false,
                        currentHeight: currentHeight,
                        targetHeight: 0,
                        restoredHeight: currentHeight,
                        percentage: 100,
                        lazyLoadingResults: lazyLoadingResults,
                        parentScrollCount: parentScrollCount,
                        parentScrollResults: parentScrollResults,
                        eventDebugResults: eventDebugResults, // 🐛 디버그 결과 포함
                        logs: logs
                    };
                }
                
                // 정적 사이트 판단 (90% 이상 이미 로드됨)
                const percentage = targetHeight > 0 ? (currentHeight / targetHeight) * 100 : 100;
                const isStaticSite = percentage >= 90;
                
                if (isStaticSite) {
                    logs.push('정적 사이트 - 콘텐츠 이미 충분함');
                    
                    // 🐛 디버그 결과 복원
                    window.history.pushState = originalPushState;
                    
                    return {
                        success: true,
                        isStaticSite: true,
                        currentHeight: currentHeight,
                        targetHeight: targetHeight,
                        restoredHeight: currentHeight,
                        percentage: percentage,
                        lazyLoadingResults: lazyLoadingResults,
                        parentScrollCount: parentScrollCount,
                        parentScrollResults: parentScrollResults,
                        eventDebugResults: eventDebugResults, // 🐛 디버그 결과 포함
                        logs: logs
                    };
                }
                
                // 동적 사이트 - 콘텐츠 로드 시도
                logs.push('동적 사이트 - 콘텐츠 로드 시도');
                
                // 🎯 **개선된 하단 더보기 버튼 선택자 (상단 탭/카테고리 제외) + 🚫 A.btn_more, A.item_more 제외**
                function isElementInBottomArea(element) {
                    try {
                        const rect = element.getBoundingClientRect();
                        const elementTop = window.scrollY + rect.top;
                        const documentHeight = Math.max(
                            document.documentElement.scrollHeight,
                            document.body.scrollHeight
                        );
                        const viewportHeight = window.innerHeight;
                        
                        // 하단 50% 영역에 있는지 확인
                        const bottomThreshold = documentHeight * 0.5;
                        const isInBottomArea = elementTop > bottomThreshold;
                        
                        // 현재 뷰포트 기준으로도 확인 (현재 스크롤 위치 하단 영역)
                        const currentViewportBottom = window.scrollY + viewportHeight;
                        const isNearCurrentView = Math.abs(elementTop - currentViewportBottom) < viewportHeight * 2;
                        
                        return isInBottomArea || isNearCurrentView;
                    } catch(e) {
                        return false;
                    }
                }
                
                function hasLoadMoreLikeText(element) {
                    try {
                        const text = (element.textContent || '').trim().toLowerCase();
                        const loadMoreTexts = [
                            '더보기', '더 보기', '더 불러오기', '계속', '다음', '추가', 
                            'load more', 'show more', 'view more', 'see more', 'more', 'next', 
                            'continue', 'load', 'expand', '펼치기'
                        ];
                        
                        return loadMoreTexts.some(function(keyword) {
                            return text.includes(keyword);
                        });
                    } catch(e) {
                        return false;
                    }
                }
                
                function isInContentListArea(element) {
                    try {
                        // 리스트나 콘텐츠 컨테이너 내부에 있는지 확인
                        let parent = element.parentElement;
                        let depth = 0;
                        while (parent && depth < 5) {
                            const classList = Array.from(parent.classList);
                            const hasListClass = classList.some(function(className) {
                                return className.toLowerCase().includes('list') ||
                                       className.toLowerCase().includes('content') ||
                                       className.toLowerCase().includes('feed') ||
                                       className.toLowerCase().includes('items') ||
                                       className.toLowerCase().includes('container');
                            });
                            
                            if (hasListClass) return true;
                            
                            parent = parent.parentElement;
                            depth++;
                        }
                        return false;
                    } catch(e) {
                        return false;
                    }
                }
                
                // 🚫 **추가: A.btn_more, A.item_more 제외 함수**
                function isExcludedSelector(element) {
                    try {
                        if (element.tagName === 'A') {
                            const classList = Array.from(element.classList);
                            // A.btn_more, A.item_more 선택자 제외
                            if (classList.includes('btn_more') || classList.includes('item_more')) {
                                return true;
                            }
                        }
                        return false;
                    } catch(e) {
                        return false;
                    }
                }
                
                // 🎯 **하단 더보기 전용 선택자 (상단 탭 제외) + 🚫 A.btn_more, A.item_more 제외**
                const bottomLoadMoreSelectors = [
                    // 명확한 하단 더보기 선택자 (클래스명 기반) - A.btn_more, A.item_more 제외됨
                    '.load-more', '.show-more', '.view-more', '.see-more', '.more-btn',
                    '.btn-load', '.btn-show', '.more-button', '.load-button',
                    
                    // data 속성 기반 (더 안전함)
                    '[data-action="load-more"]', '[data-action="show-more"]', 
                    '[data-testid*="load-more"]', '[data-testid*="show-more"]',
                    '[data-role="load-more"]', '[data-role="show-more"]',
                    
                    // ID 기반 (명확한 더보기)
                    '#load-more', '#show-more', '#view-more', '#loadmore', '#showmore',
                    '[id*="load-more"]', '[id*="loadmore"]', '[id*="show-more"]', '[id*="showmore"]',
                    
                    // 페이지네이션 (하단 영역)
                    '.pagination .next', '.pagination .more', '.pager .next', '.pager .more',
                    '.next-page', '.next-btn', '.load-next'
                ];
                
                // 🎯 **추가 검증이 필요한 선택자 (위치/텍스트 확인 필요) + 🚫 A.btn_more, A.item_more 제외됨**
                const conditionalSelectors = [
                    'button[class*="more"]', 'button[class*="load"]', 'button[class*="show"]',
                    // A 태그는 필터링에서 제외할 선택자들을 별도로 처리
                    'a[class*="more"]:not(.btn_more):not(.item_more)', 
                    'a[class*="load"]:not(.btn_more):not(.item_more)', 
                    'a[class*="show"]:not(.btn_more):not(.item_more)',
                    'button[aria-label*="more"]', 'button[aria-label*="load"]',
                    'button:contains("더보기")', 'button:contains("더 보기")',
                    'button:contains("Load More")', 'button:contains("Show More")',
                    'button:contains("More")', 'button:contains("Next")'
                ];
                
                const loadMoreButtons = [];
                
                // 1. 명확한 하단 더보기 선택자로 찾기
                for (let i = 0; i < bottomLoadMoreSelectors.length; i++) {
                    try {
                        const selector = bottomLoadMoreSelectors[i];
                        const elements = document.querySelectorAll(selector);
                        if (elements && elements.length > 0) {
                            for (let j = 0; j < elements.length; j++) {
                                const element = elements[j];
                                if (element && !loadMoreButtons.includes(element) && !isExcludedSelector(element)) {
                                    // 하단 영역에 있는지 확인
                                    if (isElementInBottomArea(element)) {
                                        loadMoreButtons.push(element);
                                        logs.push('명확한 하단 더보기 버튼 발견: ' + selector);
                                    }
                                }
                            }
                        }
                    } catch(selectorError) {
                        // 선택자 에러 무시
                    }
                }
                
                // 2. 조건부 선택자로 추가 찾기 (위치, 텍스트, 컨텍스트 확인) + 🚫 제외 선택자 필터링
                for (let i = 0; i < conditionalSelectors.length; i++) {
                    try {
                        const selector = conditionalSelectors[i];
                        const elements = document.querySelectorAll(selector);
                        if (elements && elements.length > 0) {
                            for (let j = 0; j < elements.length; j++) {
                                const element = elements[j];
                                if (element && !loadMoreButtons.includes(element) && !isExcludedSelector(element)) {
                                    // 여러 조건 검사
                                    const inBottomArea = isElementInBottomArea(element);
                                    const hasLoadText = hasLoadMoreLikeText(element);
                                    const inContentArea = isInContentListArea(element);
                                    
                                    // 3개 조건 중 2개 이상 만족해야 함
                                    const conditionCount = [inBottomArea, hasLoadText, inContentArea].filter(Boolean).length;
                                    
                                    if (conditionCount >= 2) {
                                        loadMoreButtons.push(element);
                                        logs.push('조건부 하단 더보기 버튼 발견: ' + selector + ' (조건: ' + conditionCount + '/3)');
                                    }
                                }
                            }
                        }
                    } catch(selectorError) {
                        // 선택자 에러 무시
                    }
                }
                
                logs.push('하단 더보기 버튼 후보: ' + loadMoreButtons.length + '개 발견 (상단 탭/카테고리 + A.btn_more/A.item_more 제외)');
                
                // 더보기 버튼 클릭 (최대 10개로 제한) + 🐛 디버그 추적
                let clicked = 0;
                const maxClicks = Math.min(10, loadMoreButtons.length);
                
                for (let i = 0; i < maxClicks; i++) {
                    try {
                        const btn = loadMoreButtons[i];
                        if (btn && typeof btn.click === 'function') {
                            // 버튼이 보이는지 확인
                            const computedStyle = window.getComputedStyle(btn);
                            const isVisible = computedStyle && 
                                             computedStyle.display !== 'none' && 
                                             computedStyle.visibility !== 'hidden';
                            
                            if (isVisible) {
                                // 🐛 클릭 전 디버깅
                                trackEventTarget('click_before', btn);
                                eventDebugResults.clickedElements.push(btn.tagName + (btn.className ? '.' + btn.className.split(' ')[0] : '') + (btn.textContent ? ' "' + btn.textContent.trim().substring(0, 20) + '"' : ''));
                                
                                btn.click();
                                clicked++;
                                
                                // 🐛 클릭 후 네비게이션 체크
                                setTimeout(checkNavigation, 100);
                                
                                // 추가 이벤트 디스패치
                                const clickEvent = new MouseEvent('click', {
                                    view: window,
                                    bubbles: true,
                                    cancelable: true
                                });
                                btn.dispatchEvent(clickEvent);
                                
                                // 🐛 클릭 후 디버깅
                                trackEventTarget('click_after', btn);
                            }
                        }
                    } catch(clickError) {
                        eventDebugResults.clickedElements.push('클릭 오류: ' + clickError.message);
                        logs.push('🐛 버튼 클릭 오류: ' + clickError.message);
                    }
                }
                
                if (clicked > 0) {
                    logs.push('하단 더보기 버튼 ' + clicked + '개 클릭 완료 (상단 탭 + A.btn_more/A.item_more 제외)');
                }
                
                // 🚀 무한스크롤 트리거 - 최대 8번 시도 + 🐛 디버그 추적 + ⚡ 강도 조절 (증가 없으면 중단)
                logs.push('무한스크롤 트리거 시작 (최대 8번 시도, 강도 조절 적용)');
                const maxScrollAttempts = 8;
                let previousHeight = currentHeight;
                let noGrowthCount = 0; // ⚡ 연속으로 증가가 없었던 횟수
                const maxNoGrowthAttempts = 3; // ⚡ 연속 3번 증가 없으면 중단
                
                for (let attempt = 1; attempt <= maxScrollAttempts; attempt++) {
                    try {
                        // 페이지 하단으로 스크롤
                        const maxScrollY = Math.max(0, previousHeight - (window.innerHeight || 0));
                        
                        // 다양한 스크롤 방법 시도
                        window.scrollTo(0, maxScrollY);
                        document.documentElement.scrollTop = maxScrollY;
                        document.body.scrollTop = maxScrollY;
                        
                        if (document.scrollingElement) {
                            document.scrollingElement.scrollTop = maxScrollY;
                        }
                        
                        // 🐛 스크롤 이벤트 대상 추적
                        trackEventTarget('infinite_scroll', window);
                        eventDebugResults.scrollEventTargets.push('attempt_' + attempt + '_scrollY_' + maxScrollY);
                        
                        // 스크롤 이벤트 디스패치
                        window.dispatchEvent(new Event('scroll', { bubbles: true, cancelable: true }));
                        document.dispatchEvent(new Event('scroll', { bubbles: true, cancelable: true }));
                        
                        // 추가 이벤트들
                        window.dispatchEvent(new Event('scrollend', { bubbles: true }));
                        window.dispatchEvent(new Event('wheel', { bubbles: true }));
                        
                        // IntersectionObserver 트리거를 위한 강제 리플로우
                        void(document.body.offsetHeight);
                        
                        // 🐛 네비게이션 체크
                        checkNavigation();
                        
                        // 새로운 높이 측정
                        const newHeight = Math.max(
                            document.documentElement ? document.documentElement.scrollHeight : 0,
                            document.body ? document.body.scrollHeight : 0
                        ) || 0;
                        
                        if (newHeight > previousHeight) {
                            const growthAmount = newHeight - previousHeight;
                            logs.push('시도 ' + attempt + ': 콘텐츠 증가 ' + growthAmount.toFixed(0) + 'px');
                            previousHeight = newHeight;
                            noGrowthCount = 0; // ⚡ 증가가 있었으므로 카운터 리셋
                        } else {
                            noGrowthCount++; // ⚡ 증가가 없었으므로 카운터 증가
                            logs.push('시도 ' + attempt + ': 콘텐츠 변화 없음 (연속 ' + noGrowthCount + '회)');
                        }
                        
                        // ⚡ **강도 조절: 연속으로 증가가 없으면 중단**
                        if (noGrowthCount >= maxNoGrowthAttempts) {
                            logs.push('연속 ' + maxNoGrowthAttempts + '회 증가 없음 - 무한스크롤 트리거 중단 (강도 조절)');
                            break;
                        }
                        
                        // 목표에 도달했는지 확인
                        if (newHeight >= targetHeight * 0.8) {
                            logs.push('목표 높이의 80% 도달 - 트리거 중단');
                            break;
                        }
                        
                    } catch(scrollError) {
                        logs.push('시도 ' + attempt + ' 실패: ' + (scrollError.message || 'unknown'));
                        eventDebugResults.scrollEventTargets.push('attempt_' + attempt + '_error: ' + scrollError.message);
                    }
                }
                
                // 최종 높이 측정
                const restoredHeight = Math.max(
                    document.documentElement ? document.documentElement.scrollHeight : 0,
                    document.body ? document.body.scrollHeight : 0
                ) || currentHeight;
                
                const finalPercentage = targetHeight > 0 ? (restoredHeight / targetHeight) * 100 : 100;
                const success = finalPercentage >= 70; // 70% 이상 복원 시 성공
                
                logs.push('복원된 높이: ' + restoredHeight.toFixed(0) + 'px');
                logs.push('복원률: ' + finalPercentage.toFixed(1) + '%');
                logs.push('콘텐츠 증가량: ' + (restoredHeight - currentHeight).toFixed(0) + 'px');
                logs.push('Lazy Loading 트리거: ' + lazyLoadingResults.triggered + '개 (' + lazyLoadingResults.method + ')');
                logs.push('부모 스크롤 복원: ' + parentScrollCount + '개 성공');
                logs.push('🎯 하단 더보기 클릭: ' + clicked + '개 (상단 탭 + A.btn_more/A.item_more 제외)');
                logs.push('🐛 클릭된 요소: ' + eventDebugResults.clickedElements.length + '개');
                logs.push('🐛 이벤트 대상: ' + eventDebugResults.domEventTargets.length + '개');
                logs.push('🐛 pushState 호출: ' + eventDebugResults.historyPushStates.length + '회');
                logs.push('🐛 네비게이션 시도: ' + eventDebugResults.navigationAttempts.length + '회');
                logs.push('⚡ 강도 조절: 연속 무증가 ' + noGrowthCount + '회 (최대 ' + maxNoGrowthAttempts + '회)');
                
                // 🐛 디버그 결과 복원
                window.history.pushState = originalPushState;
                
                return {
                    success: success,
                    isStaticSite: false,
                    currentHeight: currentHeight,
                    targetHeight: targetHeight,
                    restoredHeight: restoredHeight,
                    percentage: finalPercentage,
                    scrollAttempts: maxScrollAttempts,
                    buttonsClicked: clicked,
                    lazyLoadingResults: lazyLoadingResults,
                    parentScrollCount: parentScrollCount,
                    parentScrollResults: parentScrollResults,
                    eventDebugResults: eventDebugResults, // 🐛 디버그 결과 포함
                    noGrowthCount: noGrowthCount, // ⚡ 강도 조절 결과 포함
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message || 'Unknown error',
                    eventDebugResults: eventDebugResults || {},
                    logs: ['[Step 1] 오류: ' + (e.message || 'Unknown error')]
                };
            }
        })()
        """
    }
    
    private func generateStep2_PercentScrollScript() -> String {
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        let savedContentHeight = restorationConfig.savedContentHeight
        
        return """
        (function() {
            try {
                const logs = [];
                const targetPercentX = parseFloat('\(targetPercentX)');
                const targetPercentY = parseFloat('\(targetPercentY)');
                
                logs.push('[Step 2] 상대좌표 기반 스크롤 복원');
                logs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                
                // 현재 콘텐츠 크기와 뷰포트 크기
                const savedContentHeight = parseFloat('\(savedContentHeight)');

                const measuredContentHeight = Math.max(
                    document.documentElement.scrollHeight,
                    document.body.scrollHeight
                );
                const measuredContentWidth = Math.max(
                    document.documentElement.scrollWidth,
                    document.body.scrollWidth
                );
                const fallbackSavedHeight = Number.isFinite(savedContentHeight) ? savedContentHeight : 0;
                const effectiveContentHeight = Math.max(fallbackSavedHeight, measuredContentHeight);
                const contentWidth = measuredContentWidth;
                const viewportHeight = window.innerHeight;
                const viewportWidth = window.innerWidth;

                logs.push('Content height (measured / used): ' + measuredContentHeight.toFixed(0) + 'px / ' + effectiveContentHeight.toFixed(0) + 'px');

                const maxScrollY = Math.max(0, effectiveContentHeight - viewportHeight);
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
    
    // 🆕 Step 3 개선: IntersectionObserver 검증 추가
    private func generateStep3_InfiniteScrollAnchorRestoreScriptWithIO(anchorDataJSON: String, enableIOVerification: Bool) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (function() {
            try {
                const logs = [];
                const targetX = parseFloat('\(targetX)');
                const targetY = parseFloat('\(targetY)');
                const infiniteScrollAnchorData = \(anchorDataJSON);
                const enableIOVerification = \(enableIOVerification ? "true" : "false");
                
                logs.push('[Step 3] 무한스크롤 전용 앵커 복원 (IO 검증 포함)');
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
                
                // 🆕 IntersectionObserver 검증
                const ioVerification = {
                    visibleAnchors: 0,
                    targetAnchorVisible: false
                };
                
                if (enableIOVerification && foundElement) {
                    logs.push('🆕 IntersectionObserver 검증 시작');
                    
                    // IntersectionObserver로 가시성 검증
                    const observer = new IntersectionObserver(function(entries) {
                        entries.forEach(function(entry) {
                            if (entry.isIntersecting) {
                                ioVerification.visibleAnchors++;
                                if (entry.target === foundElement) {
                                    ioVerification.targetAnchorVisible = true;
                                }
                            }
                        });
                    }, {
                        root: null,
                        rootMargin: '0px',
                        threshold: 0.1
                    });
                    
                    // 모든 앵커 관찰
                    const allAnchorElements = document.querySelectorAll('li, .item, .list-item, [class*="item"]');
                    allAnchorElements.forEach(function(element) {
                        observer.observe(element);
                    });
                    
                    // 즉시 체크
                    observer.takeRecords();
                    observer.disconnect();
                    
                    logs.push('IO 검증: ' + ioVerification.visibleAnchors + '개 앵커 뷰포트 내 확인');
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
                        ioVerification: ioVerification,
                        restoredPosition: { x: actualX, y: actualY },
                        targetDifference: { x: diffX, y: diffY },
                        logs: logs
                    };
                }
                
                logs.push('무한스크롤 앵커 매칭 실패');
                return {
                    success: false,
                    anchorCount: anchors.length,
                    ioVerification: ioVerification,
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

// MARK: - BFCacheTransitionSystem 캐처/복원 확장
extension BFCacheTransitionSystem {
    
    // MARK: - 🔧 **핵심 개선: 원자적 캐처 작업 (🚀 무한스크롤 전용 앵커 캐처 + 🔄 iframe 재귀적 수집)**
    
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
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 캐처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
            
            // 🆕 부모 스크롤 상태 로깅
            if let parentScrollStates = jsState["parentScrollStates"] as? [[String: Any]] {
                TabPersistenceManager.debugMessages.append("🆕 부모 스크롤 상태 캡처: \(parentScrollStates.count)개")
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
        
        let snapshotForPersistence = captureResult.snapshot
        let hasDomSnapshot = snapshotForPersistence.domSnapshot != nil
        let hasJsState = snapshotForPersistence.jsState != nil
        let captureFailed = snapshotForPersistence.captureStatus == .failed

        if captureFailed || !hasDomSnapshot || !hasJsState {
            TabPersistenceManager.debugMessages.append("⚠️ 캡처 데이터 불완전 - 기존 스냅쇼 유지 (dom=\(hasDomSnapshot), js=\(hasJsState), status=\(snapshotForPersistence.captureStatus.rawValue))")
            return
        }

        // 캐처 완료 후 저장
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
                    var readiness = document.readyState;
                    if (readiness !== 'complete') {
                        console.warn('[DOM Capture] readyState=' + readiness + ' - capturing early');
                    }
                    
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
                    
                    var html = document.documentElement.outerHTML || '';
                    if (!html) {
                        return null;
                    }
                    var maxDomLength = 200000;
                    return html.length > maxDomLength ? html.substring(0, maxDomLength) : html;
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
        _ = domSemaphore.wait(timeout: .now() + 2.0) // 🔧 기존 캡처 타임아웃 유지 (1초)
        
        // 3. ✅ **수정: 무한스크롤 전용 앵커 JS 상태 캡처 + 부모 스크롤 상태 추가 + 🔄 iframe 재귀적 수집** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 JS 상태 캡처 시작 (iframe 재귀적 수집 포함)")
        
        DispatchQueue.main.sync {
            let jsScript = generateInfiniteScrollAnchorCaptureScriptWithParentScrollAndIframe() // 🔄 iframe 추가
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                    
                    // 📊 **상세 캐처 결과 로깅**
                    if let parentScrollStates = data["parentScrollStates"] as? [[String: Any]] {
                        TabPersistenceManager.debugMessages.append("🆕 부모 스크롤 상태: \(parentScrollStates.count)개 캡처")
                    }
                    
                    // 🔄 **iframe 캡처 결과 로깅**
                    if let iframeResults = data["iframeResults"] as? [String: Any] {
                        if let iframeCount = iframeResults["iframeCount"] as? Int {
                            TabPersistenceManager.debugMessages.append("🔄 iframe 재귀적 수집: \(iframeCount)개 iframe 처리")
                        }
                        if let accessibleCount = iframeResults["accessibleCount"] as? Int {
                            TabPersistenceManager.debugMessages.append("🔄 접근 가능한 iframe: \(accessibleCount)개")
                        }
                        if let totalAnchorsFromIframes = iframeResults["totalAnchorsFromIframes"] as? Int {
                            TabPersistenceManager.debugMessages.append("🔄 iframe에서 수집된 앵커: \(totalAnchorsFromIframes)개")
                        }
                    }
                    
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
            TabPersistenceManager.debugMessages.append("⚡ 부분 캐처 성공: visual=\(visualSnapshot != nil), dom=\(domSnapshot != nil), js=\(jsState != nil)")
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
            step1RenderDelay: 0.4,
            step2RenderDelay: 0.2,
            step3RenderDelay: 0.1,
            step4RenderDelay: 0.4,
            enableLazyLoadingTrigger: true,  // 🆕
            enableParentScrollRestore: true, // 🆕
            enableIOVerification: true       // 🆕
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
    
    // 🔄 **새로운 JavaScript 앵커 캐처 스크립트 - 부모 스크롤 상태 + iframe 재귀적 수집 추가**
    private func generateInfiniteScrollAnchorCaptureScriptWithParentScrollAndIframe() -> String {
        return """
        (function() {
            try {
                console.log('🚀 무한스크롤 전용 앵커 및 부모 스크롤 + iframe 재귀적 캡처 시작');
                
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
                
                detailedLogs.push('🚀 무한스크롤 전용 앵커 캡처 시작 (iframe 재귀적 수집 포함)');
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
                
                // 🆕 부모 컨테이너 스크롤 상태 수집 (네이버 카페 스타일)
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
                                    // CSS 경로 생성
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
                
                // 🔄 **iframe 재귀적 앵커 수집**
                function collectIframeAnchorsRecursively() {
                    const iframeResults = {
                        iframeCount: 0,
                        accessibleCount: 0,
                        totalAnchorsFromIframes: 0,
                        iframeAnchors: []
                    };
                    
                    try {
                        const iframes = document.querySelectorAll('iframe');
                        iframeResults.iframeCount = iframes.length;
                        
                        detailedLogs.push('🔄 iframe 재귀적 수집 시작: ' + iframes.length + '개 iframe 발견');
                        
                        for (let i = 0; i < iframes.length; i++) {
                            try {
                                const iframe = iframes[i];
                                
                                // iframe 접근 가능성 확인
                                if (!iframe.contentWindow || !iframe.contentDocument) {
                                    detailedLogs.push('🔄 iframe[' + i + '] 접근 불가: contentWindow/contentDocument 없음');
                                    continue;
                                }
                                
                                // Same-origin 정책 확인
                                let iframeDoc;
                                try {
                                    iframeDoc = iframe.contentDocument || iframe.contentWindow.document;
                                    if (!iframeDoc) {
                                        detailedLogs.push('🔄 iframe[' + i + '] 접근 불가: document 없음');
                                        continue;
                                    }
                                } catch(securityError) {
                                    detailedLogs.push('🔄 iframe[' + i + '] 접근 불가: CORS 제한 - ' + securityError.message);
                                    continue;
                                }
                                
                                iframeResults.accessibleCount++;
                                detailedLogs.push('🔄 iframe[' + i + '] 접근 성공');
                                
                                // iframe 내부 앵커 수집
                                const iframeWindow = iframe.contentWindow;
                                const iframeScrollY = iframeWindow.scrollY || iframeWindow.pageYOffset || 0;
                                const iframeScrollX = iframeWindow.scrollX || iframeWindow.pageXOffset || 0;
                                
                                // iframe 내부의 콘텐츠 요소들 수집
                                const iframeContentSelectors = [
                                    'li', 'tr', 'td', '.item', '.list-item', '.card', '.post', '.article',
                                    '.comment', '.reply', '.feed', '.thread', '.message', '.product', 
                                    '.news', '.media', '.content-item', '[class*="item"]', 
                                    '[class*="post"]', '[class*="card"]', '[data-testid]', 
                                    '[data-id]', '[data-key]', '[data-item-id]'
                                ];
                                
                                let iframeAnchors = [];
                                for (let j = 0; j < iframeContentSelectors.length; j++) {
                                    try {
                                        const elements = iframeDoc.querySelectorAll(iframeContentSelectors[j]);
                                        for (let k = 0; k < Math.min(elements.length, 10); k++) { // iframe당 최대 10개
                                            const element = elements[k];
                                            if (element && element.getBoundingClientRect) {
                                                const rect = element.getBoundingClientRect();
                                                if (rect.width > 10 && rect.height > 10) {
                                                    const elementText = (element.textContent || '').trim();
                                                    if (elementText.length > 5) {
                                                        // iframe 내부 요소를 메인 페이지 좌표계로 변환
                                                        const iframeRect = iframe.getBoundingClientRect();
                                                        const absoluteTop = scrollY + iframeRect.top + rect.top;
                                                        const absoluteLeft = scrollX + iframeRect.left + rect.left;
                                                        
                                                        const iframeAnchor = {
                                                            anchorType: 'iframeContent',
                                                            iframeIndex: i,
                                                            elementIndex: k,
                                                            selector: iframeContentSelectors[j],
                                                            absolutePosition: { top: absoluteTop, left: absoluteLeft },
                                                            iframePosition: { top: rect.top, left: rect.left },
                                                            size: { width: rect.width, height: rect.height },
                                                            textContent: elementText.substring(0, 100),
                                                            qualityScore: 60, // iframe 앵커는 60점
                                                            captureTimestamp: Date.now(),
                                                            isVisible: true,
                                                            visibilityReason: 'iframe_content_visible'
                                                        };
                                                        
                                                        iframeAnchors.push(iframeAnchor);
                                                        iframeResults.totalAnchorsFromIframes++;
                                                    }
                                                }
                                            }
                                        }
                                    } catch(selectorError) {
                                        // iframe 내부 선택자 오류 무시
                                    }
                                }
                                
                                if (iframeAnchors.length > 0) {
                                    iframeResults.iframeAnchors.push({
                                        iframeIndex: i,
                                        iframeSrc: iframe.src || 'about:blank',
                                        anchors: iframeAnchors,
                                        scrollPosition: { x: iframeScrollX, y: iframeScrollY }
                                    });
                                    detailedLogs.push('🔄 iframe[' + i + '] 앵커 수집: ' + iframeAnchors.length + '개');
                                }
                                
                            } catch(iframeError) {
                                detailedLogs.push('🔄 iframe[' + i + '] 처리 오류: ' + iframeError.message);
                            }
                        }
                        
                        detailedLogs.push('🔄 iframe 재귀적 수집 완료: ' + iframeResults.accessibleCount + '/' + iframeResults.iframeCount + '개 접근, 총 ' + iframeResults.totalAnchorsFromIframes + '개 앵커');
                        
                    } catch(iframeCollectionError) {
                        detailedLogs.push('🔄 iframe 수집 전체 오류: ' + iframeCollectionError.message);
                    }
                    
                    return iframeResults;
                }
                
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
                            const selector = contentSelectors[i];
                            const elements = document.querySelectorAll(selector);
                            if (elements && elements.length > 0) {
                                for (let j = 0; j < elements.length; j++) {
                                    contentElements.push(elements[j]);
                                }
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
                
                // 🆕 **메인 실행 - 부모 스크롤 상태, 무한스크롤 앵커, iframe 재귀적 수집**
                const startTime = Date.now();
                const parentScrollStates = collectParentScrollStates(); // 🆕 부모 스크롤 수집
                const iframeResults = collectIframeAnchorsRecursively(); // 🔄 iframe 재귀적 수집
                const infiniteScrollAnchorsData = collectInfiniteScrollAnchors();
                const endTime = Date.now();
                const captureTime = endTime - startTime;
                
                // 🔄 **iframe 앵커를 메인 앵커 배열에 통합**
                if (iframeResults.totalAnchorsFromIframes > 0) {
                    for (let i = 0; i < iframeResults.iframeAnchors.length; i++) {
                        const iframeData = iframeResults.iframeAnchors[i];
                        for (let j = 0; j < iframeData.anchors.length; j++) {
                            infiniteScrollAnchorsData.anchors.push(iframeData.anchors[j]);
                        }
                    }
                    infiniteScrollAnchorsData.stats.finalAnchors = infiniteScrollAnchorsData.anchors.length;
                    detailedLogs.push('iframe 앵커 통합 완료: 총 ' + infiniteScrollAnchorsData.anchors.length + '개');
                }
                
                pageAnalysis.capturePerformance = {
                    totalTime: captureTime,
                    anchorsPerSecond: infiniteScrollAnchorsData.anchors.length > 0 ? (infiniteScrollAnchorsData.anchors.length / (captureTime / 1000)).toFixed(2) : 0
                };
                
                detailedLogs.push('=== 무한스크롤 전용 앵커, 부모 스크롤, iframe 재귀적 캡처 완료 (' + captureTime + 'ms) ===');
                detailedLogs.push('최종 무한스크롤 앵커: ' + infiniteScrollAnchorsData.anchors.length + '개');
                detailedLogs.push('부모 스크롤 컨테이너: ' + parentScrollStates.length + '개');
                detailedLogs.push('iframe 재귀적 수집: ' + iframeResults.accessibleCount + '/' + iframeResults.iframeCount + '개 iframe, ' + iframeResults.totalAnchorsFromIframes + '개 앵커');
                detailedLogs.push('처리 성능: ' + pageAnalysis.capturePerformance.anchorsPerSecond + ' 앵커/초');
                
                console.log('🚀 무한스크롤 전용 앵커 캡처 완료:', {
                    infiniteScrollAnchorsCount: infiniteScrollAnchorsData.anchors.length,
                    parentScrollStatesCount: parentScrollStates.length,
                    iframeResultsCount: iframeResults.totalAnchorsFromIframes,
                    stats: infiniteScrollAnchorsData.stats,
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight],
                    captureTime: captureTime,
                    actualViewportRect: actualViewportRect
                });
                
                // ✅ **수정: 정리된 반환 구조 (부모 스크롤 + iframe 결과 추가)**
                return {
                    infiniteScrollAnchors: infiniteScrollAnchorsData, // 🚀 **무한스크롤 전용 앵커 데이터**
                    parentScrollStates: parentScrollStates,           // 🆕 **부모 스크롤 상태**
                    iframeResults: iframeResults,                     // 🔄 **iframe 재귀적 수집 결과**
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
                    parentScrollStates: [],  // 🆕
                    iframeResults: { iframeCount: 0, accessibleCount: 0, totalAnchorsFromIframes: 0, iframeAnchors: [] }, // 🔄
                    scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
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
