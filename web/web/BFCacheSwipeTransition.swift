//
//  BFCacheSnapshotManager.swift
//  📸 **가상 스크롤 대응 순차적 5단계 BFCache 복원 시스템**
//  🆕 **Step 0**: 가상 스크롤 프리렌더링 (목표 높이 90% 도달까지 무한 반복)
//  🎯 **Step 1**: 저장 콘텐츠 높이 복원 (동적 사이트만) - 🆕 복원위치 중심 로드
//  📏 **Step 2**: 절대좌표 기반 스크롤 복원 (최우선)
//  🔍 **Step 3**: 무한스크롤 전용 앵커 정밀 복원
//  ✅ **Step 4**: 최종 검증 및 스크롤 확정
//  ⏰ **렌더링 대기**: 각 단계별 필수 대기시간 적용
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용
//  🆕 **복원위치 중심 로드**: 가상 스페이서로 높이 유지하며 복원 위치부터 로드
//  🔧 **통합 순차 실행**: 독립 JS가 아닌 단일 컨텍스트 순차 실행
//  🔧 **Promise 체이닝**: async/await 대신 then 체이닝으로 Swift 호환성 확보

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
    
    // 🔄 **순차 실행 설정 + 가상 스크롤 대응**
    let restorationConfig: RestorationConfig
    
    struct RestorationConfig: Codable {
        let enablePreRendering: Bool        // 🆕 Step 0: 가상 스크롤 프리렌더링
        let enableContentRestore: Bool      // Step 1 활성화
        let enableAbsoluteRestore: Bool     // Step 2 활성화 (절대좌표)
        let enableAnchorRestore: Bool       // Step 3 활성화
        let enableFinalVerification: Bool   // Step 4 활성화
        let savedContentHeight: CGFloat     // 저장 시점 콘텐츠 높이
        let clampedHeight: CGFloat          // 🆕 클램핑된 높이 기록
        let preRenderRadius: CGFloat        // 🆕 프리렌더링 반경 (px)
        let step0RenderDelay: Double        // 🆕 Step 0 후 렌더링 대기
        let step1RenderDelay: Double        // Step 1 후 렌더링 대기 (0.8초)
        let step2RenderDelay: Double        // Step 2 후 렌더링 대기 (0.3초)
        let step3RenderDelay: Double        // Step 3 후 렌더링 대기 (0.5초)
        let step4RenderDelay: Double        // Step 4 후 렌더링 대기 (0.3초)
        
        static let `default` = RestorationConfig(
            enablePreRendering: true,
            enableContentRestore: true,
            enableAbsoluteRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: 0,
            clampedHeight: 0,
            preRenderRadius: 6000,   // ±3000px 영역 프리렌더링
            step0RenderDelay: 0.5,
            step1RenderDelay: 0.2,
            step2RenderDelay: 0.2,
            step3RenderDelay: 0.2,
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
        
        // 🆕 클램핑 높이 계산 (5000px 클램핑 감지)
        let maxHeight = max(actualScrollableSize.height, contentSize.height)
        let clampedHeight = min(maxHeight, 6000)
        
        self.restorationConfig = RestorationConfig(
            enablePreRendering: restorationConfig.enablePreRendering,
            enableContentRestore: restorationConfig.enableContentRestore,
            enableAbsoluteRestore: restorationConfig.enableAbsoluteRestore,
            enableAnchorRestore: restorationConfig.enableAnchorRestore,
            enableFinalVerification: restorationConfig.enableFinalVerification,
            savedContentHeight: maxHeight,
            clampedHeight: clampedHeight,
            preRenderRadius: restorationConfig.preRenderRadius,
            step0RenderDelay: restorationConfig.step0RenderDelay,
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
    
    // MARK: - 🎯 **핵심: 통합 순차 실행 복원 시스템**
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 통합 순차 실행 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 저장 콘텐츠 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")
        TabPersistenceManager.debugMessages.append("🚨 클램핑 감지 높이: \(String(format: "%.0f", restorationConfig.clampedHeight))px")
        TabPersistenceManager.debugMessages.append("⏰ 렌더링 대기시간: Step0=\(restorationConfig.step0RenderDelay)s, Step1=\(restorationConfig.step1RenderDelay)s, Step2=\(restorationConfig.step2RenderDelay)s, Step3=\(restorationConfig.step3RenderDelay)s, Step4=\(restorationConfig.step4RenderDelay)s")
        
        // 무한스크롤 앵커 데이터 준비
        var infiniteScrollAnchorDataJSON = "null"
        if let jsState = self.jsState,
           let infiniteScrollAnchorData = jsState["infiniteScrollAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(infiniteScrollAnchorData) {
            infiniteScrollAnchorDataJSON = dataJSON
        }
        
        // 🔧 통합 순차 실행 스크립트 생성 (Promise 체이닝 방식)
        let integratedScript = generateIntegratedSequentialScript(infiniteScrollAnchorDataJSON: infiniteScrollAnchorDataJSON)
        
        // 통합 스크립트 실행
        webView.evaluateJavaScript(integratedScript) { result, error in
            var overallSuccess = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("❌ 통합 복원 JavaScript 오류: \(error.localizedDescription)")
            } else if let resultString = result as? String {
                // JSON 문자열을 파싱
                if let data = resultString.data(using: .utf8),
                   let resultDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    overallSuccess = (resultDict["success"] as? Bool) ?? false
                    
                    // Step별 결과 로깅
                    if let step0 = resultDict["step0"] as? [String: Any] {
                        self.logStep0Results(step0)
                    }
                    if let step1 = resultDict["step1"] as? [String: Any] {
                        self.logStep1Results(step1)
                    }
                    if let step2 = resultDict["step2"] as? [String: Any] {
                        self.logStep2Results(step2)
                    }
                    if let step3 = resultDict["step3"] as? [String: Any] {
                        self.logStep3Results(step3)
                    }
                    if let step4 = resultDict["step4"] as? [String: Any] {
                        self.logStep4Results(step4)
                    }
                    
                    if let finalPosition = resultDict["finalPosition"] as? [String: Double] {
                        TabPersistenceManager.debugMessages.append("🎯 최종 복원 위치: X=\(String(format: "%.1f", finalPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
                    }
                    
                    if let executionTime = resultDict["executionTime"] as? Double {
                        TabPersistenceManager.debugMessages.append("⏱️ 전체 실행 시간: \(String(format: "%.2f", executionTime))초")
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("⚠️ JSON 파싱 실패")
                }
            } else {
                TabPersistenceManager.debugMessages.append("⚠️ 예상치 못한 결과 타입: \(type(of: result))")
            }
            
            TabPersistenceManager.debugMessages.append("🎯 통합 BFCache 복원 완료: \(overallSuccess ? "성공" : "실패")")
            completion(overallSuccess)
        }
    }
    
    // MARK: - Step 결과 로깅 메서드들
    
    private func logStep0Results(_ step0: [String: Any]) {
        TabPersistenceManager.debugMessages.append("🚀 [Step 0] 결과:")
        if let success = step0["success"] as? Bool {
            TabPersistenceManager.debugMessages.append("  성공: \(success)")
        }
        if let currentHeight = step0["currentHeight"] as? Double {
            TabPersistenceManager.debugMessages.append("  시작 높이: \(String(format: "%.0f", currentHeight))px")
        }
        if let preRenderedHeight = step0["preRenderedHeight"] as? Double {
            TabPersistenceManager.debugMessages.append("  프리렌더 후 높이: \(String(format: "%.0f", preRenderedHeight))px")
        }
        if let scrollAttempts = step0["scrollAttempts"] as? Int {
            TabPersistenceManager.debugMessages.append("  스크롤 시도: \(scrollAttempts)회")
        }
    }
    
    private func logStep1Results(_ step1: [String: Any]) {
        TabPersistenceManager.debugMessages.append("📦 [Step 1] 결과:")
        if let success = step1["success"] as? Bool {
            TabPersistenceManager.debugMessages.append("  성공: \(success)")
        }
        if let restoredHeight = step1["restoredHeight"] as? Double {
            TabPersistenceManager.debugMessages.append("  복원된 높이: \(String(format: "%.0f", restoredHeight))px")
        }
        if let percentage = step1["percentage"] as? Double {
            TabPersistenceManager.debugMessages.append("  복원률: \(String(format: "%.1f", percentage))%")
        }
    }
    
    private func logStep2Results(_ step2: [String: Any]) {
        TabPersistenceManager.debugMessages.append("📏 [Step 2] 결과:")
        if let success = step2["success"] as? Bool {
            TabPersistenceManager.debugMessages.append("  성공: \(success)")
        }
        if let currentHeight = step2["currentHeight"] as? Double {
            TabPersistenceManager.debugMessages.append("  현재 페이지 높이: \(String(format: "%.0f", currentHeight))px")
        }
        if let actualPosition = step2["actualPosition"] as? [String: Double] {
            TabPersistenceManager.debugMessages.append("  실제 스크롤 위치: Y=\(String(format: "%.1f", actualPosition["y"] ?? 0))px")
        }
    }
    
    private func logStep3Results(_ step3: [String: Any]) {
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 결과:")
        if let success = step3["success"] as? Bool {
            TabPersistenceManager.debugMessages.append("  성공: \(success)")
        }
        if let anchorCount = step3["anchorCount"] as? Int {
            TabPersistenceManager.debugMessages.append("  사용 가능한 앵커: \(anchorCount)개")
        }
        if let matchedAnchor = step3["matchedAnchor"] as? [String: Any],
           let anchorType = matchedAnchor["anchorType"] as? String {
            TabPersistenceManager.debugMessages.append("  매칭된 앵커 타입: \(anchorType)")
        }
    }
    
    private func logStep4Results(_ step4: [String: Any]) {
        TabPersistenceManager.debugMessages.append("✅ [Step 4] 결과:")
        if let success = step4["success"] as? Bool {
            TabPersistenceManager.debugMessages.append("  성공: \(success)")
        }
        if let finalHeight = step4["finalHeight"] as? Double {
            TabPersistenceManager.debugMessages.append("  최종 페이지 높이: \(String(format: "%.0f", finalHeight))px")
        }
        if let finalPosition = step4["finalPosition"] as? [String: Double] {
            TabPersistenceManager.debugMessages.append("  최종 확정 위치: Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
        }
    }
    
    // MARK: - 🔧 통합 순차 실행 JavaScript 생성 (Promise 체이닝)
    
    private func generateIntegratedSequentialScript(infiniteScrollAnchorDataJSON: String) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        let savedContentHeight = restorationConfig.savedContentHeight
        let step0Delay = Int(restorationConfig.step0RenderDelay * 1000)
        let step1Delay = Int(restorationConfig.step1RenderDelay * 1000)
        let step2Delay = Int(restorationConfig.step2RenderDelay * 1000)
        let step3Delay = Int(restorationConfig.step3RenderDelay * 1000)
        let step4Delay = Int(restorationConfig.step4RenderDelay * 1000)
        
        return """
        (function() {
            const startTime = Date.now();
            const logs = [];
            const results = {
                step0: null,
                step1: null,
                step2: null,
                step3: null,
                step4: null,
                success: false,
                finalPosition: null,
                executionTime: 0
            };
            
            // 공통 상태 변수 (모든 Step이 공유)
            let persistedHeight = 0;
            let targetScrollY = parseFloat('\(targetY)') || 0;
            let targetScrollX = parseFloat('\(targetX)') || 0;
            let savedContentHeight = parseFloat('\(savedContentHeight)') || 0;
            const infiniteScrollAnchorData = \(infiniteScrollAnchorDataJSON);
            
            logs.push('🎯 통합 순차 실행 시작');
            logs.push('목표 위치: X=' + targetScrollX.toFixed(1) + ', Y=' + targetScrollY.toFixed(1));
            logs.push('저장된 콘텐츠 높이: ' + savedContentHeight.toFixed(0));
            
            // 지연 함수를 Promise로 구현
            function delay(ms) {
                return new Promise(function(resolve) {
                    setTimeout(resolve, ms);
                });
            }
            
            // ========== Step 0: 프리렌더링 ==========
            function performStep0() {
                return new Promise(function(resolve) {
                    const step0Logs = [];
                    const targetHeight = savedContentHeight;
                    
                    step0Logs.push('[Step 0] 가상 스크롤 프리렌더링 시작');
                    step0Logs.push('목표 스크롤: ' + targetScrollY.toFixed(0) + 'px');
                    step0Logs.push('목표 높이: ' + targetHeight.toFixed(0) + 'px (90% = ' + (targetHeight * 0.9).toFixed(0) + 'px)');
                    
                    const currentHeight = Math.max(
                        document.documentElement ? document.documentElement.scrollHeight : 0,
                        document.body ? document.body.scrollHeight : 0
                    ) || 0;
                    
                    step0Logs.push('현재 페이지 높이: ' + currentHeight.toFixed(0) + 'px');
                    persistedHeight = currentHeight;  // 초기 높이 저장
                    
                    // 이미 목표의 90% 이상이면 스킵
                    if (currentHeight >= targetHeight * 0.9) {
                        step0Logs.push('✅ 이미 목표 높이의 90% 이상 도달 - 프리렌더링 스킵');
                        persistedHeight = currentHeight;
                        resolve({
                            success: true,
                            currentHeight: currentHeight,
                            preRenderedHeight: currentHeight,
                            scrollAttempts: 0,
                            loadedItems: 0,
                            logs: step0Logs
                        });
                        return;
                    }
                    
                    step0Logs.push('🚀 목표 높이의 90% 도달까지 프리렌더링 시작');
                    
                    const viewportHeight = window.innerHeight;
                    let scrollAttempts = 0;
                    let loadedItems = 0;
                    let previousHeight = currentHeight;
                    
                    // 목표 높이의 90%에 도달할 때까지 반복
                    function scrollLoop() {
                        const currentScrollHeight = Math.max(
                            document.documentElement ? document.documentElement.scrollHeight : 0,
                            document.body ? document.body.scrollHeight : 0
                        ) || previousHeight;
                        
                        persistedHeight = currentScrollHeight;  // 높이 갱신
                        
                        // 90% 도달 체크
                        if (currentScrollHeight >= targetHeight * 0.9) {
                            step0Logs.push('✅ 목표 높이의 90% 도달! (' + currentScrollHeight.toFixed(0) + 'px >= ' + (targetHeight * 0.9).toFixed(0) + 'px)');
                            
                            const preRenderedHeight = currentScrollHeight;
                            persistedHeight = preRenderedHeight;  // 최종 높이 저장
                            
                            step0Logs.push('프리렌더링 완료: ' + currentHeight.toFixed(0) + 'px → ' + preRenderedHeight.toFixed(0) + 'px');
                            step0Logs.push('높이 증가: ' + (preRenderedHeight - currentHeight).toFixed(0) + 'px');
                            step0Logs.push('스크롤 시도: ' + scrollAttempts + '회');
                            step0Logs.push('로드된 항목: ' + loadedItems + '개');
                            step0Logs.push('목표 달성률: ' + ((preRenderedHeight / targetHeight) * 100).toFixed(1) + '%');
                            
                            resolve({
                                success: preRenderedHeight >= targetHeight * 0.9,
                                currentHeight: currentHeight,
                                targetHeight: targetHeight,
                                preRenderedHeight: preRenderedHeight,
                                scrollAttempts: scrollAttempts,
                                loadedItems: loadedItems,
                                logs: step0Logs
                            });
                            return;
                        }
                        
                        // 높이 증가가 없으면 중단 (무한루프 방지)
                        if (scrollAttempts > 0 && currentScrollHeight <= previousHeight) {
                            step0Logs.push('⚠️ 더 이상 높이 증가 없음 - 중단 (' + currentScrollHeight.toFixed(0) + 'px)');
                            
                            const preRenderedHeight = currentScrollHeight;
                            persistedHeight = preRenderedHeight;
                            
                            resolve({
                                success: preRenderedHeight >= targetHeight * 0.9,
                                currentHeight: currentHeight,
                                targetHeight: targetHeight,
                                preRenderedHeight: preRenderedHeight,
                                scrollAttempts: scrollAttempts,
                                loadedItems: loadedItems,
                                logs: step0Logs
                            });
                            return;
                        }
                        
                        previousHeight = currentScrollHeight;
                        
                        // 목표 위치로 스크롤 (높이 복원용)
                        window.scrollTo(0, targetScrollY);
                        window.dispatchEvent(new Event('scroll', { bubbles: true }));
                        scrollAttempts++;
                        
                        // IntersectionObserver 트리거
                        const elements = document.querySelectorAll('*');
                        let triggered = 0;
                        for (let j = 0; j < Math.min(elements.length, 100); j++) {
                            const el = elements[j];
                            const rect = el.getBoundingClientRect();
                            if (rect.top > -viewportHeight && rect.bottom < viewportHeight * 2) {
                                el.classList.add('bfcache-prerender');
                                void(el.offsetHeight);
                                el.classList.remove('bfcache-prerender');
                                triggered++;
                            }
                        }
                        loadedItems += triggered;
                        
                        // 위쪽으로 스크롤
                        const scrollUpTo = Math.max(0, targetScrollY - viewportHeight);
                        window.scrollTo(0, scrollUpTo);
                        window.dispatchEvent(new Event('scroll', { bubbles: true }));
                        scrollAttempts++;
                        
                        // 아래쪽으로 스크롤
                        const maxScrollY = Math.max(
                            document.documentElement.scrollHeight,
                            document.body.scrollHeight
                        ) - viewportHeight;
                        const scrollDownTo = Math.min(maxScrollY, targetScrollY + viewportHeight);
                        window.scrollTo(0, scrollDownTo);
                        window.dispatchEvent(new Event('scroll', { bubbles: true }));
                        scrollAttempts++;
                        
                        // 로그 업데이트
                        if (scrollAttempts % 10 === 0) {
                            step0Logs.push('진행중... 높이: ' + currentScrollHeight.toFixed(0) + 'px / ' + (targetHeight * 0.9).toFixed(0) + 'px (' + ((currentScrollHeight / targetHeight) * 100).toFixed(1) + '%)');
                        }
                        
                        // 다음 루프 스케줄
                        setTimeout(scrollLoop, 50);
                    }
                    
                    // 루프 시작
                    scrollLoop();
                });
            }
            
            // ========== Step 1: 복원 위치 중심 콘텐츠 로드 ==========
            function performStep1() {
                return new Promise(function(resolve) {
                    const step1Logs = [];
                    const targetHeight = savedContentHeight;
                    const currentHeight = persistedHeight;  // Step0에서 유지된 높이 사용
                    
                    step1Logs.push('[Step 1] 복원 위치 중심 콘텐츠 로드 시작');
                    step1Logs.push('Step0에서 유지된 높이: ' + currentHeight.toFixed(0) + 'px');
                    step1Logs.push('목표 높이: ' + targetHeight.toFixed(0) + 'px');
                    step1Logs.push('목표 스크롤 위치: ' + targetScrollY.toFixed(0) + 'px');
                    
                    if (!targetHeight || targetHeight === 0) {
                        step1Logs.push('목표 높이가 유효하지 않음 - 스킵');
                        resolve({
                            success: false,
                            currentHeight: currentHeight,
                            targetHeight: 0,
                            restoredHeight: currentHeight,
                            percentage: 100,
                            logs: step1Logs
                        });
                        return;
                    }
                    
                    const percentage = targetHeight > 0 ? (currentHeight / targetHeight) * 100 : 100;
                    const isStaticSite = percentage >= 90;
                    
                    if (isStaticSite) {
                        step1Logs.push('정적 사이트 - 콘텐츠 이미 충분함');
                        resolve({
                            success: true,
                            isStaticSite: true,
                            currentHeight: currentHeight,
                            targetHeight: targetHeight,
                            restoredHeight: currentHeight,
                            percentage: percentage,
                            logs: step1Logs
                        });
                        return;
                    }
                    
                    step1Logs.push('동적 사이트 - 복원 위치 중심 로드 시도');
                    
                    const createVirtualSpacer = function(height) {
                        try {
                            const existingSpacer = document.querySelector('#bfcache-virtual-spacer');
                            if (existingSpacer) {
                                existingSpacer.remove();
                            }
                            
                            const spacer = document.createElement('div');
                            spacer.id = 'bfcache-virtual-spacer';
                            spacer.style.height = height + 'px';
                            spacer.style.width = '1px';
                            spacer.style.position = 'absolute';
                            spacer.style.bottom = '0';
                            spacer.style.left = '-9999px';
                            spacer.style.visibility = 'hidden';
                            spacer.style.pointerEvents = 'none';
                            document.body.appendChild(spacer);
                            
                            step1Logs.push('가상 스페이서 생성: ' + height.toFixed(0) + 'px');
                            return spacer;
                        } catch(e) {
                            step1Logs.push('가상 스페이서 생성 실패: ' + e.message);
                            return null;
                        }
                    };
                    
                    const spacerHeight = Math.max(0, targetHeight - currentHeight);
                    let virtualSpacer = null;
                    
                    if (spacerHeight > 100) {
                        virtualSpacer = createVirtualSpacer(spacerHeight);
                        void(document.body.offsetHeight);
                        step1Logs.push('가상 공간 확보 완료: ' + spacerHeight.toFixed(0) + 'px');
                    }
                    
                    // 높이 복원용 임시 스크롤만 수행
                    window.scrollTo(0, targetScrollY);
                    step1Logs.push('임시 스크롤 (높이 복원용): ' + targetScrollY.toFixed(0) + 'px');
                    
                    const triggerIntersectionObserver = function() {
                        try {
                            const viewportHeight = window.innerHeight;
                            const currentScrollY = window.scrollY || window.pageYOffset;
                            const allElements = document.querySelectorAll('*');
                            let triggeredCount = 0;
                            
                            for (let i = 0; i < allElements.length; i++) {
                                const el = allElements[i];
                                const rect = el.getBoundingClientRect();
                                
                                if (rect.bottom > -viewportHeight && rect.top < viewportHeight * 2) {
                                    const event = new Event('scrollintoview', { bubbles: true });
                                    el.dispatchEvent(event);
                                    
                                    el.classList.add('bfcache-trigger');
                                    void(el.offsetHeight);
                                    el.classList.remove('bfcache-trigger');
                                    
                                    triggeredCount++;
                                    if (triggeredCount > 50) break;
                                }
                            }
                            
                            step1Logs.push('IntersectionObserver 트리거: ' + triggeredCount + '개 요소');
                        } catch(e) {
                            step1Logs.push('IntersectionObserver 트리거 실패: ' + e.message);
                        }
                    };
                    
                    triggerIntersectionObserver();
                    
                    const loadMoreSelectors = [
                        '[data-testid*="load"]', '[data-testid*="more"]',
                        '[class*="load"]', '[class*="more"]', '[class*="show"]',
                        'button[class*="more"]', 'button[class*="load"]',
                        '.load-more', '.show-more', '.view-more',
                        '[role="button"][class*="more"]',
                        '.pagination button', '.pagination a',
                        '.next-page', '.next-btn'
                    ];
                    
                    const loadMoreButtons = [];
                    for (let i = 0; i < loadMoreSelectors.length; i++) {
                        try {
                            const selector = loadMoreSelectors[i];
                            const elements = document.querySelectorAll(selector);
                            if (elements && elements.length > 0) {
                                for (let j = 0; j < elements.length; j++) {
                                    const el = elements[j];
                                    const rect = el.getBoundingClientRect();
                                    
                                    if (rect.bottom > -500 && rect.top < window.innerHeight + 500) {
                                        if (!loadMoreButtons.includes(el)) {
                                            loadMoreButtons.push(el);
                                        }
                                    }
                                }
                            }
                        } catch(selectorError) {
                        }
                    }
                    
                    step1Logs.push('뷰포트 근처 더보기 버튼: ' + loadMoreButtons.length + '개 발견');
                    
                    let clicked = 0;
                    const maxClicks = Math.min(5, loadMoreButtons.length);
                    
                    for (let i = 0; i < maxClicks; i++) {
                        try {
                            const btn = loadMoreButtons[i];
                            if (btn && typeof btn.click === 'function') {
                                const computedStyle = window.getComputedStyle(btn);
                                const isVisible = computedStyle && 
                                                 computedStyle.display !== 'none' && 
                                                 computedStyle.visibility !== 'hidden';
                                
                                if (isVisible) {
                                    btn.click();
                                    clicked++;
                                    
                                    const clickEvent = new MouseEvent('click', {
                                        view: window,
                                        bubbles: true,
                                        cancelable: true
                                    });
                                    btn.dispatchEvent(clickEvent);
                                }
                            }
                        } catch(clickError) {
                        }
                    }
                    
                    if (clicked > 0) {
                        step1Logs.push('더보기 버튼 ' + clicked + '개 클릭 완료');
                    }
                    
                    step1Logs.push('양방향 스크롤 트리거 시작');
                    const biDirectionalScrollLoad = function() {
                        const startY = targetScrollY;
                        const viewportHeight = window.innerHeight;
                        let loadAttempts = 0;
                        const maxAttempts = 6;
                        
                        for (let i = 1; i <= 3; i++) {
                            const scrollUpTo = Math.max(0, startY - (viewportHeight * i * 0.5));
                            window.scrollTo(0, scrollUpTo);
                            window.dispatchEvent(new Event('scroll', { bubbles: true }));
                            loadAttempts++;
                            step1Logs.push('위쪽 스크롤 ' + i + ': ' + scrollUpTo.toFixed(0) + 'px');
                        }
                        
                        const maxScrollY = Math.max(
                            document.documentElement.scrollHeight,
                            document.body.scrollHeight
                        ) - viewportHeight;
                        
                        for (let i = 1; i <= 3; i++) {
                            const scrollDownTo = Math.min(maxScrollY, startY + (viewportHeight * i * 0.5));
                            window.scrollTo(0, scrollDownTo);
                            window.dispatchEvent(new Event('scroll', { bubbles: true }));
                            loadAttempts++;
                            step1Logs.push('아래쪽 스크롤 ' + i + ': ' + scrollDownTo.toFixed(0) + 'px');
                        }
                        
                        return loadAttempts;
                    };
                    
                    const scrollAttempts = biDirectionalScrollLoad();
                    step1Logs.push('양방향 스크롤 완료: ' + scrollAttempts + '회 시도');
                    
                    setTimeout(function() {
                        if (virtualSpacer) {
                            virtualSpacer.remove();
                            step1Logs.push('가상 스페이서 제거됨');
                        }
                    }, 100);
                    
                    const restoredHeight = Math.max(
                        document.documentElement ? document.documentElement.scrollHeight : 0,
                        document.body ? document.body.scrollHeight : 0
                    ) || currentHeight;
                    
                    persistedHeight = restoredHeight;  // 복원된 높이 저장
                    
                    const finalPercentage = targetHeight > 0 ? (restoredHeight / targetHeight) * 100 : 100;
                    const success = finalPercentage >= 50;
                    
                    step1Logs.push('복원된 높이: ' + restoredHeight.toFixed(0) + 'px');
                    step1Logs.push('복원률: ' + finalPercentage.toFixed(1) + '%');
                    step1Logs.push('콘텐츠 증가량: ' + (restoredHeight - currentHeight).toFixed(0) + 'px');
                    
                    resolve({
                        success: success,
                        isStaticSite: false,
                        currentHeight: currentHeight,
                        targetHeight: targetHeight,
                        restoredHeight: restoredHeight,
                        percentage: finalPercentage,
                        spacerHeight: spacerHeight,
                        loadedFromPosition: targetScrollY,
                        scrollAttempts: scrollAttempts,
                        buttonsClicked: clicked,
                        logs: step1Logs
                    });
                });
            }
            
            // ========== Step 2: 절대좌표 기반 스크롤 ==========
            function performStep2() {
                return new Promise(function(resolve) {
                    const step2Logs = [];
                    
                    step2Logs.push('[Step 2] 절대좌표 기반 스크롤 복원');
                    step2Logs.push('목표 절대좌표: X=' + targetScrollX.toFixed(1) + 'px, Y=' + targetScrollY.toFixed(1) + 'px');
                    
                    // Step0/1에서 유지된 높이 사용
                    const currentHeight = persistedHeight;
                    
                    step2Logs.push('Step0/1에서 유지된 페이지 높이: ' + currentHeight.toFixed(0) + 'px');
                    
                    // 절대좌표로 임시 스크롤 (Step 4에서 최종 확정)
                    const tempY = Math.min(targetScrollY, currentHeight - window.innerHeight);
                    const tempX = targetScrollX;
                    
                    window.scrollTo(tempX, tempY);
                    step2Logs.push('임시 스크롤 설정: X=' + tempX.toFixed(1) + 'px, Y=' + tempY.toFixed(1) + 'px');
                    
                    const actualX = window.scrollX || window.pageXOffset || 0;
                    const actualY = window.scrollY || window.pageYOffset || 0;
                    
                    step2Logs.push('실제 스크롤 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                    
                    resolve({
                        success: true,
                        targetPosition: { x: targetScrollX, y: targetScrollY },
                        currentHeight: currentHeight,
                        tempPosition: { x: tempX, y: tempY },
                        actualPosition: { x: actualX, y: actualY },
                        logs: step2Logs
                    });
                });
            }
            
            // ========== Step 3: 무한스크롤 앵커 복원 ==========
            function performStep3() {
                return new Promise(function(resolve) {
                    const step3Logs = [];
                    
                    step3Logs.push('[Step 3] 무한스크롤 전용 앵커 복원');
                    step3Logs.push('목표 위치: X=' + targetScrollX.toFixed(1) + 'px, Y=' + targetScrollY.toFixed(1) + 'px');
                    
                    const currentHeight = persistedHeight;  // 유지된 높이 사용
                    
                    if (!infiniteScrollAnchorData || !infiniteScrollAnchorData.anchors || infiniteScrollAnchorData.anchors.length === 0) {
                        step3Logs.push('무한스크롤 앵커 데이터 없음 - 스킵');
                        resolve({
                            success: false,
                            anchorCount: 0,
                            currentHeight: currentHeight,
                            logs: step3Logs
                        });
                        return;
                    }
                    
                    const anchors = infiniteScrollAnchorData.anchors;
                    step3Logs.push('사용 가능한 앵커: ' + anchors.length + '개');
                    
                    const vueComponentAnchors = anchors.filter(function(anchor) {
                        return anchor.anchorType === 'vueComponent' && anchor.vueComponent;
                    });
                    const contentHashAnchors = anchors.filter(function(anchor) {
                        return anchor.anchorType === 'contentHash' && anchor.contentHash;
                    });
                    const virtualIndexAnchors = anchors.filter(function(anchor) {
                        return anchor.anchorType === 'virtualIndex' && anchor.virtualIndex;
                    });
                    
                    step3Logs.push('Vue Component 앵커: ' + vueComponentAnchors.length + '개');
                    step3Logs.push('Content Hash 앵커: ' + contentHashAnchors.length + '개');
                    step3Logs.push('Virtual Index 앵커: ' + virtualIndexAnchors.length + '개');
                    
                    let foundElement = null;
                    let matchedAnchor = null;
                    let matchMethod = '';
                    let confidence = 0;
                    
                    if (!foundElement && vueComponentAnchors.length > 0) {
                        for (let i = 0; i < vueComponentAnchors.length && !foundElement; i++) {
                            const anchor = vueComponentAnchors[i];
                            const vueComp = anchor.vueComponent;
                            
                            if (vueComp.dataV) {
                                const vueElements = document.querySelectorAll('[' + vueComp.dataV + ']');
                                for (let j = 0; j < vueElements.length; j++) {
                                    const element = vueElements[j];
                                    if (vueComp.name && element.className.includes(vueComp.name)) {
                                        if (vueComp.index !== undefined) {
                                            const elementIndex = Array.from(element.parentElement.children).indexOf(element);
                                            if (Math.abs(elementIndex - vueComp.index) <= 2) {
                                                foundElement = element;
                                                matchedAnchor = anchor;
                                                matchMethod = 'vue_component_with_index';
                                                confidence = 95;
                                                step3Logs.push('Vue 컴포넌트로 매칭: ' + vueComp.name + '[' + vueComp.index + ']');
                                                break;
                                            }
                                        } else {
                                            foundElement = element;
                                            matchedAnchor = anchor;
                                            matchMethod = 'vue_component';
                                            confidence = 85;
                                            step3Logs.push('Vue 컴포넌트로 매칭: ' + vueComp.name);
                                            break;
                                        }
                                    }
                                }
                                if (foundElement) break;
                            }
                        }
                    }
                    
                    if (!foundElement && contentHashAnchors.length > 0) {
                        for (let i = 0; i < contentHashAnchors.length && !foundElement; i++) {
                            const anchor = contentHashAnchors[i];
                            const contentHash = anchor.contentHash;
                            
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
                                        step3Logs.push('콘텐츠 해시로 매칭: "' + searchText + '"');
                                        break;
                                    }
                                }
                                if (foundElement) break;
                            }
                            
                            if (!foundElement && contentHash.shortHash) {
                                const hashElements = document.querySelectorAll('[data-hash*="' + contentHash.shortHash + '"]');
                                if (hashElements.length > 0) {
                                    foundElement = hashElements[0];
                                    matchedAnchor = anchor;
                                    matchMethod = 'short_hash';
                                    confidence = 75;
                                    step3Logs.push('짧은 해시로 매칭: ' + contentHash.shortHash);
                                    break;
                                }
                            }
                        }
                    }
                    
                    if (!foundElement && virtualIndexAnchors.length > 0) {
                        for (let i = 0; i < virtualIndexAnchors.length && !foundElement; i++) {
                            const anchor = virtualIndexAnchors[i];
                            const virtualIndex = anchor.virtualIndex;
                            
                            if (virtualIndex.listIndex !== undefined) {
                                const listElements = document.querySelectorAll('li, .item, .list-item, [class*="item"]');
                                const targetIndex = virtualIndex.listIndex;
                                if (targetIndex >= 0 && targetIndex < listElements.length) {
                                    foundElement = listElements[targetIndex];
                                    matchedAnchor = anchor;
                                    matchMethod = 'virtual_index';
                                    confidence = 60;
                                    step3Logs.push('가상 인덱스로 매칭: [' + targetIndex + ']');
                                    break;
                                }
                            }
                            
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
                                    step3Logs.push('페이지 오프셋으로 매칭: ' + estimatedY.toFixed(0) + 'px (오차: ' + minDistance.toFixed(0) + 'px)');
                                    break;
                                }
                            }
                        }
                    }
                    
                    if (foundElement && matchedAnchor) {
                        // 임시로만 스크롤 (Step 4에서 최종 확정)
                        foundElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                        
                        if (matchedAnchor.offsetFromTop) {
                            window.scrollBy(0, -matchedAnchor.offsetFromTop);
                        }
                        
                        const actualX = window.scrollX || window.pageXOffset || 0;
                        const actualY = window.scrollY || window.pageYOffset || 0;
                        const diffX = Math.abs(actualX - targetScrollX);
                        const diffY = Math.abs(actualY - targetScrollY);
                        
                        step3Logs.push('임시 앵커 복원 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                        step3Logs.push('목표와의 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                        step3Logs.push('매칭 신뢰도: ' + confidence + '%');
                        
                        resolve({
                            success: diffY <= 100,
                            anchorCount: anchors.length,
                            matchedAnchor: {
                                anchorType: matchedAnchor.anchorType,
                                matchMethod: matchMethod,
                                confidence: confidence
                            },
                            restoredPosition: { x: actualX, y: actualY },
                            currentHeight: currentHeight,
                            targetDifference: { x: diffX, y: diffY },
                            logs: step3Logs
                        });
                        return;
                    }
                    
                    step3Logs.push('무한스크롤 앵커 매칭 실패');
                    resolve({
                        success: false,
                        anchorCount: anchors.length,
                        currentHeight: currentHeight,
                        logs: step3Logs
                    });
                });
            }
            
            // ========== Step 4: 최종 검증 ==========
            function performStep4() {
                return new Promise(function(resolve) {
                    const step4Logs = [];
                    const tolerance = 30;
                    
                    step4Logs.push('[Step 4] 최종 검증 및 스크롤 확정');
                    step4Logs.push('목표 위치: X=' + targetScrollX.toFixed(1) + 'px, Y=' + targetScrollY.toFixed(1) + 'px');
                    
                    // Step 0-3에서 복원한 최종 높이 확인 (persistedHeight 사용)
                    const finalHeight = persistedHeight;
                    
                    step4Logs.push('Step 0-3에서 유지된 최종 높이: ' + finalHeight.toFixed(0) + 'px');
                    
                    // 이제 최종 스크롤 위치 확정
                    const viewportHeight = window.innerHeight;
                    const maxScrollY = Math.max(0, finalHeight - viewportHeight);
                    const finalTargetY = Math.min(targetScrollY, maxScrollY);
                    
                    step4Logs.push('최대 스크롤 가능: ' + maxScrollY.toFixed(0) + 'px');
                    step4Logs.push('최종 목표 Y: ' + finalTargetY.toFixed(0) + 'px');
                    
                    // 최종 스크롤 확정
                    window.scrollTo(targetScrollX, finalTargetY);
                    document.documentElement.scrollTop = finalTargetY;
                    document.documentElement.scrollLeft = targetScrollX;
                    document.body.scrollTop = finalTargetY;
                    document.body.scrollLeft = targetScrollX;
                    
                    if (document.scrollingElement) {
                        document.scrollingElement.scrollTop = finalTargetY;
                        document.scrollingElement.scrollLeft = targetScrollX;
                    }
                    
                    const actualX = window.scrollX || window.pageXOffset || 0;
                    const actualY = window.scrollY || window.pageYOffset || 0;
                    
                    const diffX = Math.abs(actualX - targetScrollX);
                    const diffY = Math.abs(actualY - finalTargetY);
                    
                    step4Logs.push('최종 확정 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                    step4Logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                    
                    const withinTolerance = diffX <= tolerance && diffY <= tolerance;
                    let correctionApplied = false;
                    
                    if (!withinTolerance && diffY > tolerance) {
                        step4Logs.push('허용 오차 초과 - 미세 보정 적용');
                        
                        window.scrollTo(targetScrollX, finalTargetY);
                        document.documentElement.scrollTop = finalTargetY;
                        document.documentElement.scrollLeft = targetScrollX;
                        document.body.scrollTop = finalTargetY;
                        document.body.scrollLeft = targetScrollX;
                        
                        if (document.scrollingElement) {
                            document.scrollingElement.scrollTop = finalTargetY;
                            document.scrollingElement.scrollLeft = targetScrollX;
                        }
                        
                        correctionApplied = true;
                        
                        const correctedX = window.scrollX || window.pageXOffset || 0;
                        const correctedY = window.scrollY || window.pageYOffset || 0;
                        
                        step4Logs.push('보정 후 위치: X=' + correctedX.toFixed(1) + 'px, Y=' + correctedY.toFixed(1) + 'px');
                    }
                    
                    const success = diffY <= 50;
                    
                    resolve({
                        success: success,
                        finalHeight: finalHeight,
                        restoredHeightFromContext: finalHeight,
                        targetPosition: { x: targetScrollX, y: finalTargetY },
                        finalPosition: { x: actualX, y: actualY },
                        finalDifference: { x: diffX, y: diffY },
                        withinTolerance: withinTolerance,
                        correctionApplied: correctionApplied,
                        logs: step4Logs
                    });
                });
            }
            
            // ========== Promise 체이닝으로 순차 실행 ==========
            performStep0()
                .then(function(step0Result) {
                    results.step0 = step0Result;
                    logs.push('Step 0 완료, ' + \(step0Delay) + 'ms 대기');
                    return delay(\(step0Delay));
                })
                .then(function() {
                    logs.push('=== Step 1 실행 ===');
                    return performStep1();
                })
                .then(function(step1Result) {
                    results.step1 = step1Result;
                    logs.push('Step 1 완료, ' + \(step1Delay) + 'ms 대기');
                    return delay(\(step1Delay));
                })
                .then(function() {
                    logs.push('=== Step 2 실행 ===');
                    return performStep2();
                })
                .then(function(step2Result) {
                    results.step2 = step2Result;
                    logs.push('Step 2 완료, ' + \(step2Delay) + 'ms 대기');
                    return delay(\(step2Delay));
                })
                .then(function() {
                    logs.push('=== Step 3 실행 ===');
                    return performStep3();
                })
                .then(function(step3Result) {
                    results.step3 = step3Result;
                    logs.push('Step 3 완료, ' + \(step3Delay) + 'ms 대기');
                    return delay(\(step3Delay));
                })
                .then(function() {
                    logs.push('=== Step 4 실행 ===');
                    return performStep4();
                })
                .then(function(step4Result) {
                    results.step4 = step4Result;
                    logs.push('Step 4 완료, ' + \(step4Delay) + 'ms 대기');
                    return delay(\(step4Delay));
                })
                .then(function() {
                    // 최종 결과 수집
                    const finalX = window.scrollX || window.pageXOffset || 0;
                    const finalY = window.scrollY || window.pageYOffset || 0;
                    
                    results.finalPosition = { x: finalX, y: finalY };
                    results.success = results.step4.success || results.step2.success;
                    results.executionTime = (Date.now() - startTime) / 1000;
                    
                    logs.push('=== 통합 실행 완료 ===');
                    logs.push('최종 위치: X=' + finalX.toFixed(1) + 'px, Y=' + finalY.toFixed(1) + 'px');
                    logs.push('실행 시간: ' + results.executionTime.toFixed(2) + '초');
                    logs.push('최종 높이: ' + persistedHeight.toFixed(0) + 'px (유지됨)');
                    
                    results.logs = logs;
                    
                    // JSON 문자열로 반환
                    return JSON.stringify(results);
                })
                .catch(function(error) {
                    logs.push('오류 발생: ' + error.message);
                    results.error = error.message;
                    results.logs = logs;
                    
                    // JSON 문자열로 반환
                    return JSON.stringify(results);
                });
        })()
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
        
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
        
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        if let jsState = captureResult.snapshot.jsState {
            TabPersistenceManager.debugMessages.append("🔥 캡처된 jsState 키: \(Array(jsState.keys))")
            
            if let infiniteScrollAnchors = jsState["infiniteScrollAnchors"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🚀 캡처된 무한스크롤 앵커 데이터 키: \(Array(infiniteScrollAnchors.keys))")
                
                if let anchors = infiniteScrollAnchors["anchors"] as? [[String: Any]] {
                    let vueComponentCount = anchors.filter { ($0["anchorType"] as? String) == "vueComponent" }.count
                    let contentHashCount = anchors.filter { ($0["anchorType"] as? String) == "contentHash" }.count
                    let virtualIndexCount = anchors.filter { ($0["anchorType"] as? String) == "virtualIndex" }.count
                    let structuralPathCount = anchors.filter { ($0["anchorType"] as? String) == "structuralPath" }.count
                    let intersectionCount = anchors.filter { ($0["anchorType"] as? String) == "intersectionInfo" }.count
                    
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 타입별: Vue=\(vueComponentCount), Hash=\(contentHashCount), Index=\(virtualIndexCount), Path=\(structuralPathCount), Intersection=\(intersectionCount)")
                    
                    if anchors.count > 0 {
                        let firstAnchor = anchors[0]
                        TabPersistenceManager.debugMessages.append("🚀 첫 번째 앵커 키: \(Array(firstAnchor.keys))")
                        
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
        
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ 무한스크롤 앵커 직렬 캡처 완료: \(task.pageRecord.title)")
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
                    TabPersistenceManager.debugMessages.append("🔄 재시도 후 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            TabPersistenceManager.debugMessages.append("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 시도: \(pageRecord.title)")
        
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
        
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateInfiniteScrollAnchorCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                    
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
        _ = jsSemaphore.wait(timeout: .now() + 2.0)
        
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
        
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
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
        
        let restorationConfig = BFCacheSnapshot.RestorationConfig(
            enablePreRendering: true,
            enableContentRestore: true,
            enableAbsoluteRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height),
            clampedHeight: 0,
            preRenderRadius: 3000,
            step0RenderDelay: 0.5,
            step1RenderDelay: 0.2,
            step2RenderDelay: 0.1,
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
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version,
            restorationConfig: restorationConfig
        )
        
        return (snapshot, visualSnapshot)
    }
    
    private func generateInfiniteScrollAnchorCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 무한스크롤 전용 앵커 캡처 시작');
                
                const detailedLogs = [];
                const pageAnalysis = {};
                
                const scrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                const scrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                
                detailedLogs.push('🚀 무한스크롤 전용 앵커 캡처 시작');
                detailedLogs.push('스크롤 위치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포트 크기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                const actualViewportRect = {
                    top: scrollY,
                    left: scrollX,
                    bottom: scrollY + viewportHeight,
                    right: scrollX + viewportWidth,
                    width: viewportWidth,
                    height: viewportHeight
                };
                
                detailedLogs.push('실제 보이는 영역: top=' + actualViewportRect.top.toFixed(1) + ', bottom=' + actualViewportRect.bottom.toFixed(1));
                
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
                
                function isQualityText(text) {
                    if (!text || typeof text !== 'string') return false;
                    
                    const cleanText = text.trim();
                    if (cleanText.length < 10) return false;
                    
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
                
                function collectVueComponentElements() {
                    const vueElements = [];
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
                    
                    const vueComponentElements = collectVueComponentElements();
                    anchorStats.totalCandidates += vueComponentElements.length;
                    anchorStats.actuallyVisible += vueComponentElements.length;
                    
                    const contentSelectors = [
                        'li', 'tr', 'td', '.item', '.list-item', '.card', '.post', '.article',
                        '.comment', '.reply', '.feed', '.thread', '.message', '.product', 
                        '.news', '.media', '.content-item', '[class*="item"]', 
                        '[class*="post"]', '[class*="card"]', '[data-testid]', 
                        '[data-id]', '[data-key]', '[data-item-id]',
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
                        }
                    }
                    
                    anchorStats.totalCandidates += contentElements.length;
                    
                    const uniqueContentElements = [];
                    const processedElements = new Set();
                    
                    for (let i = 0; i < contentElements.length; i++) {
                        const element = contentElements[i];
                        if (!processedElements.has(element)) {
                            processedElements.add(element);
                            
                            const visibilityResult = isElementActuallyVisible(element, false);
                            anchorStats.visibilityChecked++;
                            
                            if (visibilityResult.visible) {
                                const elementText = (element.textContent || '').trim();
                                if (elementText.length > 5) {
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
                    
                    const viewportCenterY = scrollY + (viewportHeight / 2);
                    const viewportCenterX = scrollX + (viewportWidth / 2);
                    
                    vueComponentElements.sort(function(a, b) {
                        const aTop = scrollY + a.rect.top;
                        const bTop = scrollY + b.rect.top;
                        const aDistance = Math.abs(aTop + (a.rect.height / 2) - viewportCenterY);
                        const bDistance = Math.abs(bTop + (b.rect.height / 2) - viewportCenterY);
                        return aDistance - bDistance;
                    });
                    
                    uniqueContentElements.sort(function(a, b) {
                        const aTop = scrollY + a.rect.top;
                        const bTop = scrollY + b.rect.top;
                        const aDistance = Math.abs(aTop + (a.rect.height / 2) - viewportCenterY);
                        const bDistance = Math.abs(bTop + (b.rect.height / 2) - viewportCenterY);
                        return aDistance - bDistance;
                    });
                    
                    const selectedVueElements = vueComponentElements.slice(0, 20);
                    const selectedContentElements = uniqueContentElements.slice(0, 20);
                    
                    detailedLogs.push('뷰포트 중심 기준 선택: Vue=' + selectedVueElements.length + '개, Content=' + selectedContentElements.length + '개');
                    
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
                    
                    for (let i = 0; i < selectedContentElements.length; i++) {
                        try {
                            const hashAnchor = createContentHashAnchor(selectedContentElements[i], i);
                            if (hashAnchor) {
                                anchors.push(hashAnchor);
                                anchorStats.contentHashAnchors++;
                            }
                            
                            const indexAnchor = createVirtualIndexAnchor(selectedContentElements[i], i);
                            if (indexAnchor) {
                                anchors.push(indexAnchor);
                                anchorStats.virtualIndexAnchors++;
                            }
                            
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
                    
                    return {
                        anchors: anchors,
                        stats: anchorStats
                    };
                }
                
                function createVueComponentAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        const dataVAttr = elementData.dataVAttr;
                        
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        const vueComponent = {
                            name: 'unknown',
                            dataV: dataVAttr,
                            props: {},
                            index: index
                        };
                        
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
                        
                        if (element.parentElement) {
                            const siblingIndex = Array.from(element.parentElement.children).indexOf(element);
                            vueComponent.index = siblingIndex;
                        }
                        
                        const qualityScore = 85;
                        
                        return {
                            anchorType: 'vueComponent',
                            vueComponent: vueComponent,
                            absolutePosition: { top: absoluteTop, left: absoluteLeft },
                            viewportPosition: { top: rect.top, left: rect.left },
                            offsetFromTop: offsetFromTop,
                            size: { width: rect.width, height: rect.height },
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
                
                function createContentHashAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
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
                
                function createVirtualIndexAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
                        const virtualIndex = {
                            listIndex: index,
                            pageIndex: Math.floor(index / 10),
                            offsetInPage: absoluteTop,
                            estimatedTotal: document.querySelectorAll('li, .item, .list-item, .ListItem').length
                        };
                        
                        const qualityScore = 70;
                        
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
                
                function createStructuralPathAnchor(elementData, index) {
                    try {
                        const element = elementData.element;
                        const rect = elementData.rect;
                        const textContent = elementData.textContent;
                        
                        const absoluteTop = scrollY + rect.top;
                        const absoluteLeft = scrollX + rect.left;
                        const offsetFromTop = scrollY - absoluteTop;
                        
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
                        
                        const qualityScore = 50;
                        
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
                
                return {
                    infiniteScrollAnchors: infiniteScrollAnchorsData,
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
                    actualViewportRect: actualViewportRect,
                    detailedLogs: detailedLogs,
                    captureStats: infiniteScrollAnchorsData.stats,
                    pageAnalysis: pageAnalysis,
                    captureTime: captureTime
                };
            } catch(e) { 
                console.error('🚀 무한스크롤 전용 앵커 캡처 실패:', e);
                return {
                    infiniteScrollAnchors: { anchors: [], stats: {} },
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
