//
//  BFCacheSwipeTransition.swift
//  🎯 **동적 사이트 최적화 BFCache 시스템**
//  🔄 **Step 순서 역전**: 앵커(3) → 백분율(2) → 높이(1) → 검증(4)
//  🚀 **다중 구역 앵커**: 상·중·하 3구역 × 10개씩 총 30개 앵커
//  ⚡ **비동기 안정화**: requestAnimationFrame 기반 (busy-wait 제거)
//  🎯 **단일 스크롤러 자동 검출**: 가장 큰 scrollHeight 자동 선택
//  ♾️ **프리롤 로더**: 앵커 등장까지 자동 바닥 스크롤
//  🔒 **overflow-anchor 구간 제어**: 복원 중에만 비활성화

import UIKit
import WebKit
import SwiftUI

// MARK: - 📸 **동적 사이트 최적화 BFCache 스냅샷**
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
    
    // 🔄 **동적 사이트 최적화 복원 설정**
    let restorationConfig: RestorationConfig
    
    struct RestorationConfig: Codable {
        let enableAnchorRestore: Bool       // Step 3 (최우선)
        let enablePercentRestore: Bool       // Step 2 (차순위)
        let enableContentRestore: Bool       // Step 1 (보조)
        let enableFinalVerification: Bool    // Step 4 (검증)
        let savedContentHeight: CGFloat
        let anchorRenderDelay: Double       // 앵커 복원 후 대기
        let percentRenderDelay: Double       // 백분율 복원 후 대기
        let contentRenderDelay: Double       // 콘텐츠 복원 후 대기
        let verificationRenderDelay: Double  // 검증 후 대기
        let enablePreroll: Bool              // 프리롤 로더 활성화
        let prerollMaxDuration: Double       // 프리롤 최대 시간
        
        static let `default` = RestorationConfig(
            enableAnchorRestore: true,
            enablePercentRestore: true,
            enableContentRestore: true,
            enableFinalVerification: true,
            savedContentHeight: 0,
            anchorRenderDelay: 0.1,
            percentRenderDelay: 0.15,
            contentRenderDelay: 0.2,
            verificationRenderDelay: 0.1,
            enablePreroll: true,
            prerollMaxDuration: 6.0
        )
    }
    
    enum CaptureStatus: String, Codable {
        case complete
        case partial
        case visualOnly
        case failed
    }
    
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
        
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
    }
    
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
            enableAnchorRestore: restorationConfig.enableAnchorRestore,
            enablePercentRestore: restorationConfig.enablePercentRestore,
            enableContentRestore: restorationConfig.enableContentRestore,
            enableFinalVerification: restorationConfig.enableFinalVerification,
            savedContentHeight: max(actualScrollableSize.height, contentSize.height),
            anchorRenderDelay: restorationConfig.anchorRenderDelay,
            percentRenderDelay: restorationConfig.percentRenderDelay,
            contentRenderDelay: restorationConfig.contentRenderDelay,
            verificationRenderDelay: restorationConfig.verificationRenderDelay,
            enablePreroll: restorationConfig.enablePreroll,
            prerollMaxDuration: restorationConfig.prerollMaxDuration
        )
    }
    
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // MARK: - 🎯 **동적 사이트 최적화: 역전된 4단계 복원**
    
    private struct RestorationContext {
        let snapshot: BFCacheSnapshot
        weak var webView: WKWebView?
        let completion: (Bool) -> Void
        var overallSuccess: Bool = false
    }
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 동적 최적화 BFCache 복원 시작 (역전 순서)")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("⚡ 프리롤 로더: \(restorationConfig.enablePreroll ? "활성" : "비활성")")
        TabPersistenceManager.debugMessages.append("🔄 복원 순서: 앵커(3) → 백분율(2) → 높이(1) → 검증(4)")
        
        let context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: completion
        )
        
        // 🔄 **역전된 순서: Step 3 먼저 시작**
        executeStep3_AnchorRestore(context: context)
    }
    
    // MARK: - Step 3: 앵커 복원 (최우선)
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("🔍 [Step 3 - 최우선] 다중 구역 앵커 복원 시작")
        
        guard restorationConfig.enableAnchorRestore else {
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 비활성화됨 - 백분율 복원으로")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.executeStep2_PercentScroll(context: context)
            }
            return
        }
        
        var infiniteScrollAnchorDataJSON = "null"
        if let jsState = self.jsState,
           let infiniteScrollAnchorData = jsState["infiniteScrollAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(infiniteScrollAnchorData) {
            infiniteScrollAnchorDataJSON = dataJSON
        }
        
        let js = generateStep3_DynamicAnchorRestoreScript(anchorDataJSON: infiniteScrollAnchorDataJSON)
        
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
                if let prerollInfo = resultDict["prerollInfo"] as? [String: Any] {
                    if let iterations = prerollInfo["iterations"] as? Int {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 프리롤 반복: \(iterations)회")
                    }
                    if let finalHeight = prerollInfo["finalHeight"] as? Double {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 최종 콘텐츠 높이: \(String(format: "%.0f", finalHeight))px")
                    }
                }
                if let matchedAnchor = resultDict["matchedAnchor"] as? [String: Any] {
                    if let anchorType = matchedAnchor["anchorType"] as? String {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭된 앵커: \(anchorType)")
                    }
                    if let zone = matchedAnchor["zone"] as? String {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 앵커 구역: \(zone)")
                    }
                }
                if let restoredPosition = resultDict["restoredPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 복원 위치: Y=\(String(format: "%.1f", restoredPosition["y"] ?? 0))px")
                }
                
                if step3Success {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] ✅ 앵커 복원 성공 - 전체 성공")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 완료: \(step3Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 3] 렌더링 대기: \(self.restorationConfig.anchorRenderDelay)초")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.anchorRenderDelay) {
                if step3Success {
                    // 앵커 성공 시 바로 검증으로
                    self.executeStep4_FinalVerification(context: updatedContext)
                } else {
                    // 앵커 실패 시 백분율로
                    self.executeStep2_PercentScroll(context: updatedContext)
                }
            }
        }
    }
    
    // MARK: - Step 2: 백분율 스크롤 (차순위)
    private func executeStep2_PercentScroll(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📏 [Step 2 - 차순위] 백분율 기반 스크롤 복원")
        
        guard restorationConfig.enablePercentRestore else {
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 비활성화됨 - 콘텐츠 복원으로")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.executeStep1_ContentRestore(context: context)
            }
            return
        }
        
        let js = generateStep2_AsyncPercentScrollScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step2Success = false
            var updatedContext = context
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📏 [Step 2] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step2Success = (resultDict["success"] as? Bool) ?? false
                
                if let targetPercent = resultDict["targetPercent"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] 목표 백분율: Y=\(String(format: "%.2f", targetPercent["y"] ?? 0))%")
                }
                if let actualPosition = resultDict["actualPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] 실제 위치: Y=\(String(format: "%.1f", actualPosition["y"] ?? 0))px")
                }
                
                if step2Success && !updatedContext.overallSuccess {
                    updatedContext.overallSuccess = true
                    TabPersistenceManager.debugMessages.append("📏 [Step 2] ✅ 백분율 복원 성공")
                }
            }
            
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 완료: \(step2Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 2] 렌더링 대기: \(self.restorationConfig.percentRenderDelay)초")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.percentRenderDelay) {
                if step2Success {
                    self.executeStep4_FinalVerification(context: updatedContext)
                } else {
                    self.executeStep1_ContentRestore(context: updatedContext)
                }
            }
        }
    }
    
    // MARK: - Step 1: 콘텐츠 높이 복원 (보조)
    private func executeStep1_ContentRestore(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("📦 [Step 1 - 보조] 콘텐츠 높이 복원")
        
        guard restorationConfig.enableContentRestore else {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 비활성화됨 - 검증으로")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.executeStep4_FinalVerification(context: context)
            }
            return
        }
        
        let js = generateStep1_AsyncContentRestoreScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step1Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step1Success = (resultDict["success"] as? Bool) ?? false
                
                if let restoredHeight = resultDict["restoredHeight"] as? Double {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] 복원 높이: \(String(format: "%.0f", restoredHeight))px")
                }
            }
            
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 완료: \(step1Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 1] 렌더링 대기: \(self.restorationConfig.contentRenderDelay)초")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.contentRenderDelay) {
                self.executeStep4_FinalVerification(context: context)
            }
        }
    }
    
    // MARK: - Step 4: 최종 검증
    private func executeStep4_FinalVerification(context: RestorationContext) {
        TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 검증 및 미세 보정")
        
        guard restorationConfig.enableFinalVerification else {
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 비활성화됨 - 완료")
            context.completion(context.overallSuccess)
            return
        }
        
        let js = generateStep4_AsyncFinalVerificationScript()
        
        context.webView?.evaluateJavaScript(js) { result, error in
            var step4Success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                step4Success = (resultDict["success"] as? Bool) ?? false
                
                if let finalPosition = resultDict["finalPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 위치: Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
                }
                if let correctionApplied = resultDict["correctionApplied"] as? Bool, correctionApplied {
                    TabPersistenceManager.debugMessages.append("✅ [Step 4] 미세 보정 적용됨")
                }
            }
            
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 완료: \(step4Success ? "성공" : "실패")")
            TabPersistenceManager.debugMessages.append("⏰ [Step 4] 렌더링 대기: \(self.restorationConfig.verificationRenderDelay)초")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + self.restorationConfig.verificationRenderDelay) {
                let finalSuccess = context.overallSuccess || step4Success
                TabPersistenceManager.debugMessages.append("🎯 동적 최적화 BFCache 복원 완료: \(finalSuccess ? "성공" : "실패")")
                context.completion(finalSuccess)
            }
        }
    }
    
    // MARK: - 🎯 동적 사이트 최적화 JavaScript 생성
    
    private func generateCommonDynamicUtilityScript() -> String {
        return """
        // 🎯 **동적 사이트 최적화 유틸리티 (비동기 버전)**
        
        // 단일 스크롤러 자동 검출
        function detectSingleScroller() {
            const cands = [
                document.scrollingElement,
                document.documentElement,
                document.body,
                ...Array.from(document.querySelectorAll('[style*="overflow"], [class*="scroll"], .viewport, .main-content'))
            ].filter(el => el);
            
            let best = cands[0];
            let bestScore = 0;
            
            cands.forEach(el => {
                const score = (el.scrollHeight - el.clientHeight) + (el.scrollWidth - el.clientWidth);
                if (score > bestScore) {
                    best = el;
                    bestScore = score;
                }
            });
            
            return best || document.scrollingElement || document.documentElement;
        }
        
        // 캐시된 ROOT
        let _cachedROOT = null;
        function getROOT() {
            if (!_cachedROOT) {
                _cachedROOT = detectSingleScroller();
            }
            return _cachedROOT;
        }
        
        function getMaxScroll() {
            const r = getROOT();
            return {
                x: Math.max(0, r.scrollWidth - (r.clientWidth || window.innerWidth)),
                y: Math.max(0, r.scrollHeight - (r.clientHeight || window.innerHeight))
            };
        }
        
        // 비동기 레이아웃 안정화 (requestAnimationFrame 기반)
        async function waitForStableLayout(options = {}) {
            const { frames = 6, timeout = 1500, threshold = 2 } = options;
            const ROOT = getROOT();
            let last = ROOT.scrollHeight;
            let stable = 0;
            const t0 = performance.now();
            
            while (performance.now() - t0 < timeout) {
                await new Promise(r => requestAnimationFrame(r));
                const h = ROOT.scrollHeight;
                stable = (Math.abs(h - last) <= threshold) ? (stable + 1) : 0;
                last = h;
                if (stable >= frames) break;
            }
            
            return ROOT.scrollHeight;
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
        
        // 고정 헤더 높이
        function fixedHeaderHeight() {
            const cands = document.querySelectorAll('header, [class*="header"], [class*="gnb"], [class*="navbar"]');
            let h = 0;
            cands.forEach(el => {
                const cs = getComputedStyle(el);
                if (cs.position === 'fixed' || cs.position === 'sticky') {
                    h = Math.max(h, el.getBoundingClientRect().height);
                }
            });
            return h;
        }
        
        // overflow-anchor 제어
        function setOverflowAnchor(enabled) {
            document.documentElement.style.overflowAnchor = enabled ? '' : 'none';
            document.body.style.overflowAnchor = enabled ? '' : 'none';
        }
        
        // 환경 초기화
        (function initEnv() {
            if (window._bfcacheEnvInit) return;
            window._bfcacheEnvInit = true;
            
            try { history.scrollRestoration = 'manual'; } catch(e) {}
            
            const style = document.createElement('style');
            style.textContent = 'html, body { scroll-behavior: auto !important; }';
            document.head.appendChild(style);
        })();
        """
    }
    
    private func generateStep3_DynamicAnchorRestoreScript(anchorDataJSON: String) -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        let prerollMaxMs = restorationConfig.prerollMaxDuration * 1000
        
        return """
        (async function() {
            try {
                \(generateCommonDynamicUtilityScript())
                
                const logs = [];
                const targetX = \(targetX);
                const targetY = \(targetY);
                const infiniteScrollAnchorData = \(anchorDataJSON);
                const prerollMaxMs = \(prerollMaxMs);
                
                logs.push('[Step 3] 다중 구역 앵커 복원 (최우선)');
                
                if (!infiniteScrollAnchorData || !infiniteScrollAnchorData.anchors || infiniteScrollAnchorData.anchors.length === 0) {
                    return { success: false, anchorCount: 0, logs: logs };
                }
                
                const anchors = infiniteScrollAnchorData.anchors;
                logs.push('앵커 총 ' + anchors.length + '개');
                
                // overflow-anchor 비활성화
                setOverflowAnchor(false);
                
                // 구역별 앵커 분류
                const zoneAnchors = {
                    upper: [],
                    middle: [],
                    lower: []
                };
                
                anchors.forEach(anchor => {
                    if (!anchor.absolutePosition) return;
                    const y = anchor.absolutePosition.top;
                    const relativeY = y / (infiniteScrollAnchorData.content?.height || 10000);
                    
                    if (relativeY < 0.33) {
                        zoneAnchors.upper.push(anchor);
                    } else if (relativeY < 0.67) {
                        zoneAnchors.middle.push(anchor);
                    } else {
                        zoneAnchors.lower.push(anchor);
                    }
                });
                
                logs.push('구역별 앵커: 상=' + zoneAnchors.upper.length + 
                         ', 중=' + zoneAnchors.middle.length + 
                         ', 하=' + zoneAnchors.lower.length);
                
                // 프리롤 로더: 앵커가 나타날 때까지 바닥 스크롤
                const ROOT = getROOT();
                const deadline = performance.now() + prerollMaxMs;
                let matchedAnchor = null;
                let iterations = 0;
                let prerollInfo = {};
                
                while (!matchedAnchor && performance.now() < deadline) {
                    iterations++;
                    
                    // 모든 구역의 앵커 확인
                    for (const zone of ['middle', 'upper', 'lower']) {
                        for (const anchor of zoneAnchors[zone]) {
                            const found = await findAnchorElement(anchor);
                            if (found) {
                                matchedAnchor = { ...anchor, element: found, zone: zone };
                                break;
                            }
                        }
                        if (matchedAnchor) break;
                    }
                    
                    if (!matchedAnchor) {
                        // 바닥으로 스크롤하여 동적 로딩 트리거
                        const beforeHeight = ROOT.scrollHeight;
                        ROOT.scrollTop = ROOT.scrollHeight;
                        window.dispatchEvent(new Event('scroll', { bubbles: true }));
                        
                        await new Promise(r => requestAnimationFrame(r));
                        await new Promise(r => requestAnimationFrame(r));
                        
                        const afterHeight = ROOT.scrollHeight;
                        if (afterHeight - beforeHeight < 50 && iterations > 10) {
                            break; // 더 이상 로드되지 않음
                        }
                    }
                }
                
                prerollInfo = {
                    iterations: iterations,
                    finalHeight: ROOT.scrollHeight,
                    duration: performance.now() - (deadline - prerollMaxMs)
                };
                
                let success = false;
                let restoredPosition = { x: 0, y: 0 };
                
                if (matchedAnchor) {
                    // 매칭된 앵커로 스크롤
                    const rect = matchedAnchor.element.getBoundingClientRect();
                    const absY = ROOT.scrollTop + rect.top;
                    const headerHeight = fixedHeaderHeight();
                    const finalY = Math.max(0, absY - headerHeight - (matchedAnchor.offsetFromTop || 0));
                    
                    const result = await preciseScrollTo(targetX, finalY);
                    restoredPosition = result;
                    
                    const diffY = Math.abs(result.y - targetY);
                    success = diffY <= 200; // 동적 사이트는 오차 허용 증가
                    
                    logs.push('앵커 매칭: ' + matchedAnchor.anchorType + ' (구역: ' + matchedAnchor.zone + ')');
                    logs.push('복원 위치: Y=' + result.y.toFixed(1) + 'px (차이: ' + diffY.toFixed(1) + 'px)');
                } else {
                    logs.push('앵커 매칭 실패 - 프리롤 ' + iterations + '회 시도');
                }
                
                // overflow-anchor 복원
                setOverflowAnchor(true);
                
                // 앵커 찾기 헬퍼 함수
                async function findAnchorElement(anchor) {
                    try {
                        // Vue Component
                        if (anchor.anchorType === 'vueComponent' && anchor.vueComponent) {
                            const dataV = anchor.vueComponent.dataV;
                            if (dataV) {
                                const elements = document.querySelectorAll('[' + dataV + ']');
                                for (const el of elements) {
                                    if (el.textContent && anchor.textContent && 
                                        el.textContent.includes(anchor.textContent.substring(0, 30))) {
                                        return el;
                                    }
                                }
                            }
                        }
                        
                        // Content Hash
                        if (anchor.anchorType === 'contentHash' && anchor.contentHash) {
                            const searchText = anchor.contentHash.text?.substring(0, 50);
                            if (searchText && searchText.length > 10) {
                                const allElements = document.querySelectorAll('*');
                                for (const el of allElements) {
                                    if (el.textContent && el.textContent.includes(searchText)) {
                                        return el;
                                    }
                                }
                            }
                        }
                        
                        // Virtual Index
                        if (anchor.anchorType === 'virtualIndex' && anchor.virtualIndex) {
                            const listElements = document.querySelectorAll('li, .item, .list-item');
                            const idx = anchor.virtualIndex.listIndex;
                            if (idx >= 0 && idx < listElements.length) {
                                return listElements[idx];
                            }
                        }
                        
                        // Structural Path
                        if (anchor.anchorType === 'structuralPath' && anchor.structuralPath) {
                            try {
                                const el = document.querySelector(anchor.structuralPath.cssPath);
                                if (el) return el;
                            } catch(e) {}
                        }
                    } catch(e) {}
                    return null;
                }
                
                return {
                    success: success,
                    anchorCount: anchors.length,
                    prerollInfo: prerollInfo,
                    matchedAnchor: matchedAnchor ? {
                        anchorType: matchedAnchor.anchorType,
                        zone: matchedAnchor.zone
                    } : null,
                    restoredPosition: restoredPosition,
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
    
    private func generateStep2_AsyncPercentScrollScript() -> String {
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        
        return """
        (async function() {
            try {
                \(generateCommonDynamicUtilityScript())
                
                const logs = [];
                const targetPercentX = \(targetPercentX);
                const targetPercentY = \(targetPercentY);
                
                logs.push('[Step 2] 백분율 기반 스크롤 (차순위)');
                
                // 비동기 안정화
                await waitForStableLayout({ frames: 4, timeout: 1000 });
                
                const ROOT = getROOT();
                const max = getMaxScroll();
                
                // 백분율 계산
                const targetX = (targetPercentX / 100) * max.x;
                const targetY = (targetPercentY / 100) * max.y;
                
                // 비동기 스크롤
                const result = await preciseScrollTo(targetX, targetY);
                
                const diffY = Math.abs(result.y - targetY);
                const success = diffY <= 100; // 동적 사이트는 오차 허용
                
                logs.push('목표: Y=' + targetY.toFixed(1) + 'px');
                logs.push('실제: Y=' + result.y.toFixed(1) + 'px');
                logs.push('차이: ' + diffY.toFixed(1) + 'px');
                
                return {
                    success: success,
                    targetPercent: { x: targetPercentX, y: targetPercentY },
                    actualPosition: { x: result.x, y: result.y },
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
    
    private func generateStep1_AsyncContentRestoreScript() -> String {
        let targetHeight = restorationConfig.savedContentHeight
        
        return """
        (async function() {
            try {
                \(generateCommonDynamicUtilityScript())
                
                const logs = [];
                const targetHeight = \(targetHeight);
                const ROOT = getROOT();
                
                logs.push('[Step 1] 콘텐츠 높이 복원 (보조)');
                
                // 더보기 버튼 클릭
                const loadMoreButtons = document.querySelectorAll(
                    '[data-testid*="load"], [class*="load"], [class*="more"], button[class*="more"]'
                );
                
                for (let i = 0; i < Math.min(3, loadMoreButtons.length); i++) {
                    const btn = loadMoreButtons[i];
                    if (btn && typeof btn.click === 'function') {
                        btn.click();
                        await new Promise(r => setTimeout(r, 200));
                    }
                }
                
                await waitForStableLayout({ frames: 4, timeout: 1500 });
                
                const restoredHeight = ROOT.scrollHeight;
                const percentage = (restoredHeight / targetHeight) * 100;
                const success = percentage >= 70; // 70% 이상이면 성공
                
                logs.push('복원 높이: ' + restoredHeight.toFixed(0) + 'px');
                logs.push('복원률: ' + percentage.toFixed(1) + '%');
                
                return {
                    success: success,
                    targetHeight: targetHeight,
                    restoredHeight: restoredHeight,
                    percentage: percentage,
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
    
    private func generateStep4_AsyncFinalVerificationScript() -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        
        return """
        (async function() {
            try {
                \(generateCommonDynamicUtilityScript())
                
                const logs = [];
                const targetX = \(targetX);
                const targetY = \(targetY);
                const tolerance = 50;
                
                logs.push('[Step 4] 최종 검증 및 보정');
                
                const ROOT = getROOT();
                let currentX = ROOT.scrollLeft || 0;
                let currentY = ROOT.scrollTop || 0;
                
                let diffY = Math.abs(currentY - targetY);
                let correctionApplied = false;
                
                if (diffY > tolerance) {
                    // 미세 보정
                    const result = await preciseScrollTo(targetX, targetY);
                    currentX = result.x;
                    currentY = result.y;
                    diffY = Math.abs(currentY - targetY);
                    correctionApplied = true;
                    logs.push('미세 보정 적용');
                }
                
                const success = diffY <= 100;
                
                return {
                    success: success,
                    targetPosition: { x: targetX, y: targetY },
                    finalPosition: { x: currentX, y: currentY },
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

// MARK: - BFCacheTransitionSystem 캡처 확장
extension BFCacheTransitionSystem {
    
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
        TabPersistenceManager.debugMessages.append("🚀 다중 구역 앵커 캡처 시작: \(pageRecord.url.host ?? "unknown")")
        
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
        
        TabPersistenceManager.debugMessages.append("🚀 다중 구역 앵커 직렬 캡처: \(task.pageRecord.title)")
        
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵")
                return nil
            }
            
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
        
        guard let data = captureData else { return }
        
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        // 앵커 통계 로깅
        if let jsState = captureResult.snapshot.jsState,
           let anchors = jsState["infiniteScrollAnchors"] as? [String: Any],
           let anchorList = anchors["anchors"] as? [[String: Any]] {
            
            // 구역별 분류
            var upperCount = 0, middleCount = 0, lowerCount = 0
            
            for anchor in anchorList {
                if let pos = anchor["absolutePosition"] as? [String: Double],
                   let top = pos["top"],
                   let contentHeight = (anchors["content"] as? [String: Double])?["height"] {
                    let relativeY = top / contentHeight
                    if relativeY < 0.33 { upperCount += 1 }
                    else if relativeY < 0.67 { middleCount += 1 }
                    else { lowerCount += 1 }
                }
            }
            
            TabPersistenceManager.debugMessages.append("🚀 다중 구역 앵커 캡처 완료: 상=\(upperCount), 중=\(middleCount), 하=\(lowerCount)")
        }
        
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ 다중 구역 앵커 캡처 완료: \(task.pageRecord.title)")
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
                    TabPersistenceManager.debugMessages.append("🔄 재시도 후 캡처 성공: 시도 \(attempt + 1)")
                }
                return result
            }
            
            TabPersistenceManager.debugMessages.append("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1))")
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        return (BFCacheSnapshot(
            pageRecord: pageRecord,
            scrollPosition: captureData.scrollPosition,
            actualScrollableSize: captureData.actualScrollableSize,
            timestamp: Date(),
            captureStatus: .failed,
            version: 1
        ), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 시도: \(pageRecord.title)")
        
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
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 성공")
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
                    
                    document.querySelectorAll('[class*="active"], [class*="pressed"]').forEach(function(el) {
                        var classList = Array.from(el.classList);
                        classList.filter(c => c.includes('active') || c.includes('pressed')).forEach(c => el.classList.remove(c));
                    });
                    
                    document.querySelectorAll('input:focus, textarea:focus').forEach(el => el.blur());
                    
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
        
        // 3. 다중 구역 앵커 JS 캡처
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 다중 구역 앵커 JS 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateMultiZoneAnchorCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 캡처 성공: \(Array(data.keys))")
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 3.0)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.height > captureData.viewportSize.height ||
           captureData.actualScrollableSize.width > captureData.viewportSize.width {
            let maxScrollX = max(0, captureData.actualScrollableSize.width - captureData.viewportSize.width)
            let maxScrollY = max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height)
            
            scrollPercent = CGPoint(
                x: maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        // 동적 사이트 최적화 설정
        let restorationConfig = BFCacheSnapshot.RestorationConfig(
            enableAnchorRestore: true,      // 최우선
            enablePercentRestore: true,      // 차순위
            enableContentRestore: true,      // 보조
            enableFinalVerification: true,
            savedContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height),
            anchorRenderDelay: 0.1,
            percentRenderDelay: 0.15,
            contentRenderDelay: 0.2,
            verificationRenderDelay: 0.1,
            enablePreroll: true,
            prerollMaxDuration: 6.0
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
    
    // 🚀 다중 구역 앵커 캡처 스크립트
    private func generateMultiZoneAnchorCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 다중 구역 앵커 캡처 시작');
                
                // 단일 스크롤러 검출
                function detectSingleScroller() {
                    const cands = [
                        document.scrollingElement,
                        document.documentElement,
                        document.body,
                        ...Array.from(document.querySelectorAll('[style*="overflow"], .viewport'))
                    ].filter(el => el);
                    
                    let best = cands[0];
                    let bestScore = 0;
                    
                    cands.forEach(el => {
                        const score = (el.scrollHeight - el.clientHeight) + (el.scrollWidth - el.clientWidth);
                        if (score > bestScore) {
                            best = el;
                            bestScore = score;
                        }
                    });
                    
                    return best || document.scrollingElement || document.documentElement;
                }
                
                const ROOT = detectSingleScroller();
                const scrollY = parseFloat(ROOT.scrollTop) || 0;
                const scrollX = parseFloat(ROOT.scrollLeft) || 0;
                const viewportHeight = parseFloat(ROOT.clientHeight || window.innerHeight) || 0;
                const viewportWidth = parseFloat(ROOT.clientWidth || window.innerWidth) || 0;
                const contentHeight = parseFloat(ROOT.scrollHeight) || 0;
                const contentWidth = parseFloat(ROOT.scrollWidth) || 0;
                
                console.log('🚀 스크롤러 정보:', {
                    element: ROOT.tagName,
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                const actualViewportRect = {
                    top: scrollY,
                    left: scrollX,
                    bottom: scrollY + viewportHeight,
                    right: scrollX + viewportWidth,
                    width: viewportWidth,
                    height: viewportHeight
                };
                
                function isElementVisible(element) {
                    try {
                        if (!element || !element.getBoundingClientRect) return false;
                        if (!document.contains(element)) return false;
                        
                        const rect = element.getBoundingClientRect();
                        if (rect.width === 0 || rect.height === 0) return false;
                        
                        const elementTop = scrollY + rect.top;
                        const elementBottom = scrollY + rect.bottom;
                        
                        // 뷰포트 근처 100px 이내면 가시로 판정 (동적 로딩 대비)
                        const isNearViewport = 
                            elementBottom > (actualViewportRect.top - 100) &&
                            elementTop < (actualViewportRect.bottom + 100);
                        
                        if (!isNearViewport) return false;
                        
                        const style = window.getComputedStyle(element);
                        if (style.display === 'none' || style.visibility === 'hidden') return false;
                        
                        return true;
                    } catch(e) {
                        return false;
                    }
                }
                
                function isQualityText(text) {
                    if (!text || text.length < 10) return false;
                    const patterns = [/^[\\s\\.\\-_=+]+$/, /^[0-9\\s\\.\\/\\-:]+$/];
                    return !patterns.some(p => p.test(text.trim()));
                }
                
                function simpleHash(str) {
                    let hash = 0;
                    for (let i = 0; i < str.length; i++) {
                        hash = ((hash << 5) - hash) + str.charCodeAt(i);
                        hash = hash & hash;
                    }
                    return Math.abs(hash).toString(36);
                }
                
                function findDataVAttribute(element) {
                    for (let i = 0; i < element.attributes.length; i++) {
                        if (element.attributes[i].name.startsWith('data-v-')) {
                            return element.attributes[i].name;
                        }
                    }
                    return null;
                }
                
                // 다중 구역 앵커 수집
                function collectMultiZoneAnchors() {
                    const anchors = [];
                    const zones = ['upper', 'middle', 'lower'];
                    const zoneRanges = [
                        [0, 0.33],      // upper
                        [0.33, 0.67],   // middle
                        [0.67, 1.0]     // lower
                    ];
                    
                    // 모든 가능한 요소 수집
                    const selectors = [
                        'li', 'tr', '.item', '.list-item', '.card', '.post',
                        '.comment', '.feed', '.product', '.news',
                        '[class*="item"]', '[class*="list"]', '[data-v-]',
                        '[data-testid]', '[data-id]', '.ListItem', '.ArticleListItem'
                    ];
                    
                    let allElements = [];
                    selectors.forEach(sel => {
                        try {
                            const els = document.querySelectorAll(sel);
                            allElements.push(...Array.from(els));
                        } catch(e) {}
                    });
                    
                    // 중복 제거 및 가시성 필터링
                    const processedSet = new Set();
                    const visibleElements = [];
                    
                    allElements.forEach(el => {
                        if (!processedSet.has(el) && isElementVisible(el)) {
                            processedSet.add(el);
                            const rect = el.getBoundingClientRect();
                            const elementY = scrollY + rect.top;
                            const relativeY = contentHeight > 0 ? elementY / contentHeight : 0;
                            
                            // 구역 결정
                            let zone = 'middle';
                            for (let i = 0; i < zoneRanges.length; i++) {
                                const [min, max] = zoneRanges[i];
                                if (relativeY >= min && relativeY < max) {
                                    zone = zones[i];
                                    break;
                                }
                            }
                            
                            visibleElements.push({
                                element: el,
                                rect: rect,
                                absoluteY: elementY,
                                relativeY: relativeY,
                                zone: zone,
                                text: el.textContent?.trim() || ''
                            });
                        }
                    });
                    
                    console.log('🚀 가시 요소:', visibleElements.length + '개');
                    
                    // 각 구역별로 10개씩 선택
                    zones.forEach(zone => {
                        const zoneElements = visibleElements.filter(v => v.zone === zone);
                        
                        // 뷰포트 중심에 가까운 순으로 정렬
                        const viewportCenterY = scrollY + (viewportHeight / 2);
                        zoneElements.sort((a, b) => {
                            const aDist = Math.abs(a.absoluteY - viewportCenterY);
                            const bDist = Math.abs(b.absoluteY - viewportCenterY);
                            return aDist - bDist;
                        });
                        
                        // 상위 10개 선택
                        zoneElements.slice(0, 10).forEach((item, idx) => {
                            const el = item.element;
                            
                            // Vue Component 앵커
                            const dataVAttr = findDataVAttribute(el);
                            if (dataVAttr) {
                                anchors.push({
                                    anchorType: 'vueComponent',
                                    vueComponent: {
                                        name: el.className.split(' ')[0] || 'unknown',
                                        dataV: dataVAttr,
                                        index: idx
                                    },
                                    absolutePosition: { top: item.absoluteY, left: scrollX + item.rect.left },
                                    textContent: item.text.substring(0, 100),
                                    zone: zone
                                });
                            }
                            
                            // Content Hash 앵커
                            if (isQualityText(item.text)) {
                                const hash = simpleHash(item.text);
                                anchors.push({
                                    anchorType: 'contentHash',
                                    contentHash: {
                                        fullHash: hash,
                                        shortHash: hash.substring(0, 8),
                                        text: item.text.substring(0, 100)
                                    },
                                    absolutePosition: { top: item.absoluteY, left: scrollX + item.rect.left },
                                    textContent: item.text.substring(0, 100),
                                    zone: zone
                                });
                            }
                            
                            // Virtual Index 앵커
                            anchors.push({
                                anchorType: 'virtualIndex',
                                virtualIndex: {
                                    listIndex: idx,
                                    offsetInPage: item.absoluteY,
                                    zone: zone
                                },
                                absolutePosition: { top: item.absoluteY, left: scrollX + item.rect.left },
                                textContent: item.text.substring(0, 100),
                                zone: zone
                            });
                            
                            // Structural Path (상위 5개만)
                            if (idx < 5) {
                                let cssPath = '';
                                let current = el;
                                let depth = 0;
                                
                                while (current && current !== document.body && depth < 3) {
                                    let selector = current.tagName.toLowerCase();
                                    if (current.id) {
                                        selector += '#' + current.id;
                                        cssPath = selector + (cssPath ? ' > ' + cssPath : '');
                                        break;
                                    } else if (current.className) {
                                        const cls = current.className.split(' ')[0];
                                        if (cls) selector += '.' + cls;
                                    }
                                    cssPath = selector + (cssPath ? ' > ' + cssPath : '');
                                    current = current.parentElement;
                                    depth++;
                                }
                                
                                if (cssPath) {
                                    anchors.push({
                                        anchorType: 'structuralPath',
                                        structuralPath: { cssPath: cssPath },
                                        absolutePosition: { top: item.absoluteY, left: scrollX + item.rect.left },
                                        textContent: item.text.substring(0, 100),
                                        zone: zone
                                    });
                                }
                            }
                        });
                    });
                    
                    // 구역별 통계
                    const stats = {
                        upper: anchors.filter(a => a.zone === 'upper').length,
                        middle: anchors.filter(a => a.zone === 'middle').length,
                        lower: anchors.filter(a => a.zone === 'lower').length,
                        total: anchors.length
                    };
                    
                    console.log('🚀 다중 구역 앵커:', stats);
                    
                    return { anchors: anchors, stats: stats };
                }
                
                const result = collectMultiZoneAnchors();
                
                return {
                    infiniteScrollAnchors: result,
                    scroll: { x: scrollX, y: scrollY },
                    viewport: { width: viewportWidth, height: viewportHeight },
                    content: { width: contentWidth, height: contentHeight },
                    actualScrollable: {
                        width: Math.max(contentWidth, viewportWidth),
                        height: Math.max(contentHeight, viewportHeight)
                    },
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now(),
                    scrollerInfo: {
                        element: ROOT.tagName,
                        id: ROOT.id || 'none',
                        className: ROOT.className || 'none'
                    }
                };
                
            } catch(e) {
                console.error('🚀 다중 구역 앵커 캡처 실패:', e);
                return {
                    infiniteScrollAnchors: { anchors: [], stats: {} },
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
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🚀 동적 최적화 BFCache 페이지 복원');
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 동적 최적화 BFCache 페이지 저장');
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
