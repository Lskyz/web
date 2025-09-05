//
//  BFCacheSwipeTransition.swift
//  🎯 **강화된 BFCache 전환 시스템 - 스냅샷 안전접근 수정**
//  ✅ 모든 스냅샷 작업 메인 스레드 보장
//  🛡️ 웹뷰 상태 검증 강화
//  🔒 스냅샷 요청 직렬화
//  ⚡ 안전한 에러 처리 추가
//

import UIKit
import WebKit
import SwiftUI

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 약한 참조 제스처 컨텍스트 (순환 참조 방지)
private class WeakGestureContext {
    let tabID: UUID
    weak var webView: WKWebView?
    weak var stateModel: WebViewStateModel?
    
    init(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        self.tabID = tabID
        self.webView = webView
        self.stateModel = stateModel
    }
}

// MARK: - 🔄 적응형 타이밍 학습 시스템
struct SiteTimingProfile: Codable {
    let hostname: String
    var loadingSamples: [TimeInterval] = []
    var averageLoadingTime: TimeInterval = 0.5
    var successfulRestores: Int = 0
    var totalRestores: Int = 0
    var lastUpdated: Date = Date()
    
    var successRate: Double {
        guard totalRestores > 0 else { return 0.0 }
        return Double(successfulRestores) / Double(totalRestores)
    }
    
    mutating func recordLoadingTime(_ duration: TimeInterval) {
        loadingSamples.append(duration)
        // 최근 10개 샘플만 유지
        if loadingSamples.count > 10 {
            loadingSamples.removeFirst()
        }
        averageLoadingTime = loadingSamples.reduce(0, +) / Double(loadingSamples.count)
        lastUpdated = Date()
    }
    
    mutating func recordRestoreAttempt(success: Bool) {
        totalRestores += 1
        if success {
            successfulRestores += 1
        }
        lastUpdated = Date()
    }
    
    // 적응형 대기 시간 계산
    func getAdaptiveWaitTime(step: Int) -> TimeInterval {
        let baseTime = averageLoadingTime
        let stepMultiplier = Double(step) * 0.1
        let successFactor = successRate > 0.8 ? 0.8 : 1.0 // 성공률 높으면 빠르게
        return (baseTime + stepMultiplier) * successFactor
    }
}

// MARK: - 📸 **대폭 강화된 BFCache 페이지 스냅샷**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 🆕 **앵커 기반 스크롤 복원 정보**
    var anchorBasedPosition: AnchorBasedPosition?
    
    // 🆕 **무한 스크롤 상태**
    var infiniteScrollState: InfiniteScrollState?
    
    // 🆕 **동적 콘텐츠 안정화 정보**
    var stabilizationInfo: StabilizationInfo?
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
        case stabilizing    // 안정화 중
    }
    
    // 🆕 **앵커 기반 위치 정보**
    struct AnchorBasedPosition: Codable {
        let anchorSelector: String
        let anchorId: String?
        let offsetFromAnchor: CGPoint
        let anchorBounds: CGRect
        let anchorText: String?
        let anchorIndex: Int // 같은 selector의 몇 번째인지
    }
    
    // 🆕 **무한 스크롤 상태**
    struct InfiniteScrollState: Codable {
        let totalItems: Int
        let loadedItems: Int
        let currentPageNumber: Int?
        let lastVisibleItemId: String?
        let scrollContainerSelector: String?
        let hasMoreContent: Bool
        let estimatedTotalHeight: Double
    }
    
    // 🆕 **동적 콘텐츠 안정화 정보**
    struct StabilizationInfo: Codable {
        let stabilizationDuration: TimeInterval
        let domChangeCount: Int
        let finalStableAt: Date
        let contentHash: String
        let adRegionsDetected: [String] // 광고 영역 선택자들
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, jsState, timestamp
        case webViewSnapshotPath, captureStatus, version
        case anchorBasedPosition, infiniteScrollState, stabilizationInfo
    }
    
    // Custom encoding/decoding for [String: Any]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        
        // JSON decode for [String: Any]
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
        
        // 새로운 필드들
        anchorBasedPosition = try container.decodeIfPresent(AnchorBasedPosition.self, forKey: .anchorBasedPosition)
        infiniteScrollState = try container.decodeIfPresent(InfiniteScrollState.self, forKey: .infiniteScrollState)
        stabilizationInfo = try container.decodeIfPresent(StabilizationInfo.self, forKey: .stabilizationInfo)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        
        // JSON encode for [String: Any]
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
        
        // 새로운 필드들
        try container.encodeIfPresent(anchorBasedPosition, forKey: .anchorBasedPosition)
        try container.encodeIfPresent(infiniteScrollState, forKey: .infiniteScrollState)
        try container.encodeIfPresent(stabilizationInfo, forKey: .stabilizationInfo)
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1, anchorBasedPosition: AnchorBasedPosition? = nil, infiniteScrollState: InfiniteScrollState? = nil, stabilizationInfo: StabilizationInfo? = nil) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.anchorBasedPosition = anchorBasedPosition
        self.infiniteScrollState = infiniteScrollState
        self.stabilizationInfo = stabilizationInfo
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // ⚡ **대폭 개선된 다단계 복원 메서드**
    func restore(to webView: WKWebView, siteProfile: SiteTimingProfile?, completion: @escaping (Bool) -> Void) {
        // 캡처 상태에 따른 복원 전략
        switch captureStatus {
        case .failed:
            completion(false)
            return
            
        case .visualOnly:
            // 기본 스크롤만 즉시 복원
            DispatchQueue.main.async {
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                TabPersistenceManager.debugMessages.append("BFCache 기본 스크롤만 즉시 복원")
                completion(true)
            }
            return
            
        case .stabilizing:
            TabPersistenceManager.debugMessages.append("BFCache 안정화 중 상태 - 기본 복원 시도")
            fallthrough
            
        case .partial, .complete:
            break
        }
        
        TabPersistenceManager.debugMessages.append("BFCache 고급 다단계 복원 시작")
        
        // 적응형 타이밍으로 다단계 복원 실행
        DispatchQueue.main.async {
            self.performAdvancedMultiStepRestore(to: webView, siteProfile: siteProfile, completion: completion)
        }
    }
    
    // 🔄 **핵심: 대폭 개선된 다단계 복원 시스템**
    private func performAdvancedMultiStepRestore(to webView: WKWebView, siteProfile: SiteTimingProfile?, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        // 사이트별 적응형 타이밍 계산
        let profile = siteProfile ?? SiteTimingProfile(hostname: "default")
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        // **1단계: 앵커 기반 복원 (최우선) - 0ms**
        if let anchorPos = anchorBasedPosition {
            restoreSteps.append((1, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🎯 1단계: 앵커 기반 복원 (즉시)")
                
                let anchorRestoreJS = self.generateAnchorBasedRestoreScript(anchorPos)
                
                webView.evaluateJavaScript(anchorRestoreJS) { result, error in
                    let success = (result as? Bool) ?? false
                    if success {
                        TabPersistenceManager.debugMessages.append("🎯 앵커 복원 성공: \(anchorPos.anchorSelector)")
                    } else {
                        TabPersistenceManager.debugMessages.append("⚠️ 앵커 복원 실패, 기본 스크롤로 대체")
                        // 앵커 실패시 기본 스크롤 복원
                        webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                    }
                    stepCompletion(success)
                }
            }))
        } else {
            // **1-1단계: 기본 메인 윈도우 스크롤 복원 (0ms)**
            restoreSteps.append((1, { stepCompletion in
                let targetPos = self.scrollPosition
                TabPersistenceManager.debugMessages.append("🔄 1단계: 기본 스크롤 복원 (즉시)")
                
                // 네이티브 스크롤뷰 즉시 설정
                webView.scrollView.setContentOffset(targetPos, animated: false)
                
                // JavaScript 메인 스크롤 복원
                let mainScrollJS = """
                (function() {
                    try {
                        window.scrollTo(\(targetPos.x), \(targetPos.y));
                        document.documentElement.scrollTop = \(targetPos.y);
                        document.body.scrollTop = \(targetPos.y);
                        return true;
                    } catch(e) { return false; }
                })()
                """
                
                webView.evaluateJavaScript(mainScrollJS) { result, _ in
                    let success = (result as? Bool) ?? false
                    TabPersistenceManager.debugMessages.append("🔄 1단계 완료: \(success ? "성공" : "실패")")
                    stepCompletion(success)
                }
            }))
        }
        
        // **2단계: 무한 스크롤 상태 복원 (적응형 대기)**
        if let infiniteState = infiniteScrollState {
            restoreSteps.append((2, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 1)
                TabPersistenceManager.debugMessages.append("♾️ 2단계: 무한 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let infiniteScrollJS = self.generateInfiniteScrollRestoreScript(infiniteState)
                    webView.evaluateJavaScript(infiniteScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("♾️ 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **3단계: 컨테이너 스크롤 복원 (광고 제외) (적응형 대기)**
        if let jsState = self.jsState,
           let scrollData = jsState["scroll"] as? [String: Any],
           let elements = scrollData["elements"] as? [[String: Any]], !elements.isEmpty {
            
            restoreSteps.append((3, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 2)
                TabPersistenceManager.debugMessages.append("📦 3단계: 컨테이너 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let containerScrollJS = self.generateAdvancedContainerScrollScript(elements)
                    webView.evaluateJavaScript(containerScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("📦 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **4단계: iframe 스크롤 복원 (더 긴 대기)**
        if let jsState = self.jsState,
           let iframeData = jsState["iframes"] as? [[String: Any]], !iframeData.isEmpty {
            
            restoreSteps.append((4, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 3)
                TabPersistenceManager.debugMessages.append("🖼️ 4단계: iframe 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let iframeScrollJS = self.generateIframeScrollScript(iframeData)
                    webView.evaluateJavaScript(iframeScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🖼️ 4단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **5단계: 최종 확인 및 보정 (안정화 정보 고려)**
        restoreSteps.append((5, { stepCompletion in
            let waitTime = profile.getAdaptiveWaitTime(step: 4)
            TabPersistenceManager.debugMessages.append("✅ 5단계: 최종 보정 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                let finalVerifyJS = self.generateFinalVerificationScript()
                
                webView.evaluateJavaScript(finalVerifyJS) { result, _ in
                    let success = (result as? Bool) ?? false
                    TabPersistenceManager.debugMessages.append("✅ 5단계 완료: \(success ? "성공" : "실패")")
                    stepCompletion(success)
                }
            }
        }))
        
        // 단계별 실행
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                stepInfo.action { success in
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > totalSteps / 2
                
                TabPersistenceManager.debugMessages.append("🔄 고급 다단계 복원 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                completion(overallSuccess)
            }
        }
        
        executeNextStep()
    }
    
    // 🎯 **새로운 앵커 기반 복원 스크립트**
    private func generateAnchorBasedRestoreScript(_ anchor: AnchorBasedPosition) -> String {
        return """
        (function() {
            try {
                console.log('🎯 앵커 기반 복원 시작:', '\(anchor.anchorSelector)');
                
                // 1. 앵커 요소 찾기 (여러 방법 시도)
                let anchorElement = null;
                
                // ID 우선
                if ('\(anchor.anchorId ?? "")') {
                    anchorElement = document.getElementById('\(anchor.anchorId!)');
                    if (anchorElement) console.log('✅ ID로 앵커 발견');
                }
                
                // Selector로 찾기
                if (!anchorElement) {
                    const elements = document.querySelectorAll('\(anchor.anchorSelector)');
                    if (elements.length > \(anchor.anchorIndex)) {
                        anchorElement = elements[\(anchor.anchorIndex)];
                        console.log('✅ Selector로 앵커 발견 (인덱스: \(anchor.anchorIndex))');
                    } else if (elements.length > 0) {
                        anchorElement = elements[0];
                        console.log('⚠️ 인덱스 불일치, 첫 번째 요소 사용');
                    }
                }
                
                // 텍스트 내용으로 찾기
                if (!anchorElement && '\(anchor.anchorText ?? "")') {
                    const allElements = document.querySelectorAll('*');
                    for (const el of allElements) {
                        if (el.textContent && el.textContent.includes('\(anchor.anchorText!)')) {
                            anchorElement = el;
                            console.log('✅ 텍스트로 앵커 발견');
                            break;
                        }
                    }
                }
                
                if (!anchorElement) {
                    console.log('❌ 앵커 요소를 찾을 수 없음');
                    return false;
                }
                
                // 2. 앵커 기준 스크롤 위치 계산
                const rect = anchorElement.getBoundingClientRect();
                const scrollX = window.scrollX + rect.left + \(anchor.offsetFromAnchor.x);
                const scrollY = window.scrollY + rect.top + \(anchor.offsetFromAnchor.y);
                
                console.log('🎯 계산된 스크롤 위치:', scrollX, scrollY);
                
                // 3. 스크롤 실행
                window.scrollTo(scrollX, scrollY);
                document.documentElement.scrollTop = scrollY;
                document.body.scrollTop = scrollY;
                
                // 4. 결과 확인
                const finalScrollY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop;
                const success = Math.abs(finalScrollY - scrollY) < 50; // 50px 오차 허용
                
                console.log('🎯 앵커 복원 결과:', success ? '성공' : '실패', '최종위치:', finalScrollY);
                return success;
                
            } catch(e) {
                console.error('🎯 앵커 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // ♾️ **새로운 무한 스크롤 복원 스크립트**
    private func generateInfiniteScrollRestoreScript(_ infiniteState: InfiniteScrollState) -> String {
        return """
        (function() {
            try {
                console.log('♾️ 무한 스크롤 복원 시작');
                
                // 1. 스크롤 컨테이너 찾기
                const containerSelector = '\(infiniteState.scrollContainerSelector ?? "")';
                let container = null;
                
                if (containerSelector) {
                    container = document.querySelector(containerSelector);
                }
                
                if (!container) {
                    // 일반적인 무한 스크롤 컨테이너 찾기
                    const commonSelectors = [
                        '[data-infinite-scroll]', '.infinite-scroll', '.infinite-container',
                        '[data-scroll-container]', '.scroll-container', '.feed-container',
                        '[data-virtualized]', '.virtualized', 'main', '[role="main"]'
                    ];
                    
                    for (const sel of commonSelectors) {
                        container = document.querySelector(sel);
                        if (container) break;
                    }
                }
                
                if (!container) {
                    console.log('⚠️ 무한 스크롤 컨테이너를 찾을 수 없음');
                    return false;
                }
                
                // 2. 현재 아이템 수 확인
                const currentItems = container.children.length;
                const targetItems = \(infiniteState.loadedItems);
                
                console.log('♾️ 현재 아이템:', currentItems, '목표 아이템:', targetItems);
                
                // 3. 마지막 보이는 아이템 찾기
                let targetElement = null;
                if ('\(infiniteState.lastVisibleItemId ?? "")') {
                    targetElement = document.getElementById('\(infiniteState.lastVisibleItemId!)');
                    if (targetElement) {
                        console.log('✅ 목표 아이템 발견:', '\(infiniteState.lastVisibleItemId!)');
                        
                        // 해당 아이템으로 스크롤
                        targetElement.scrollIntoView({ behavior: 'auto', block: 'start' });
                        return true;
                    }
                }
                
                // 4. 아이템 수 기반 추정 스크롤
                if (currentItems >= targetItems * 0.8) { // 80% 이상 로드된 경우
                    const estimatedIndex = Math.min(targetItems - 1, currentItems - 1);
                    if (estimatedIndex > 0 && estimatedIndex < currentItems) {
                        const targetChild = container.children[estimatedIndex];
                        if (targetChild) {
                            console.log('♾️ 추정 위치로 스크롤:', estimatedIndex);
                            targetChild.scrollIntoView({ behavior: 'auto', block: 'start' });
                            return true;
                        }
                    }
                }
                
                // 5. 전체 높이 기반 추정
                const estimatedHeight = \(infiniteState.estimatedTotalHeight);
                if (estimatedHeight > 0) {
                    const currentHeight = container.scrollHeight || document.body.scrollHeight;
                    const scrollRatio = Math.min(1.0, estimatedHeight / currentHeight);
                    const targetScroll = currentHeight * scrollRatio;
                    
                    console.log('♾️ 높이 기반 스크롤:', targetScroll);
                    window.scrollTo(0, targetScroll);
                    return true;
                }
                
                console.log('⚠️ 무한 스크롤 복원 방법을 찾을 수 없음');
                return false;
                
            } catch(e) {
                console.error('♾️ 무한 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 📦 **개선된 컨테이너 스크롤 복원 스크립트 (광고 제외)**
    private func generateAdvancedContainerScrollScript(_ elements: [[String: Any]]) -> String {
        let elementsJSON = convertToJSONString(elements) ?? "[]"
        return """
        (function() {
            try {
                const elements = \(elementsJSON);
                let restored = 0;
                
                // 광고 선택자 패턴 (제외 대상)
                const adPatterns = [
                    '[id*="ad"]', '[class*="ad"]', '[data-ad]',
                    '[id*="banner"]', '[class*="banner"]',
                    '[id*="sponsor"]', '[class*="sponsor"]',
                    '.advertisement', '.ads', '.advert',
                    'iframe[src*="doubleclick"]', 'iframe[src*="googlesyndication"]',
                    '[data-google-ad]', '[data-ad-client]'
                ];
                
                function isAdElement(element) {
                    // 광고 관련 선택자나 속성 확인
                    for (const pattern of adPatterns) {
                        try {
                            if (element.matches && element.matches(pattern)) {
                                return true;
                            }
                        } catch(e) {}
                    }
                    
                    // 클래스명이나 ID에 광고 관련 키워드 포함 확인
                    const className = element.className || '';
                    const id = element.id || '';
                    const combinedText = (className + ' ' + id).toLowerCase();
                    
                    const adKeywords = ['ad', 'banner', 'sponsor', 'promo', 'commercial'];
                    return adKeywords.some(keyword => combinedText.includes(keyword));
                }
                
                for (const item of elements) {
                    if (!item.selector) continue;
                    
                    // 다양한 selector 시도
                    const selectors = [
                        item.selector,
                        item.selector.replace(/\\[\\d+\\]/g, ''), // 인덱스 제거
                        item.className ? '.' + item.className : null,
                        item.id ? '#' + item.id : null
                    ].filter(s => s);
                    
                    for (const sel of selectors) {
                        const elements = document.querySelectorAll(sel);
                        if (elements.length > 0) {
                            elements.forEach(el => {
                                // 광고 요소 제외
                                if (isAdElement(el)) {
                                    console.log('📦 광고 요소 제외:', sel);
                                    return;
                                }
                                
                                if (el && typeof el.scrollTop === 'number') {
                                    // 스크롤 값이 의미있는 경우만 적용
                                    const targetTop = item.top || 0;
                                    const targetLeft = item.left || 0;
                                    
                                    if (targetTop > 10 || targetLeft > 10) { // 10px 이상만 의미있다고 간주
                                        el.scrollTop = targetTop;
                                        el.scrollLeft = targetLeft;
                                        restored++;
                                        console.log('📦 컨테이너 스크롤 복원:', sel, targetTop, targetLeft);
                                    }
                                }
                            });
                            break; // 성공하면 다음 selector 시도 안함
                        }
                    }
                }
                
                console.log('📦 컨테이너 스크롤 복원:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('📦 컨테이너 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // ✅ **개선된 최종 확인 스크립트**
    private func generateFinalVerificationScript() -> String {
        return """
        (function() {
            try {
                // 1. 메인 스크롤 확인 및 보정
                const targetY = \(self.scrollPosition.y);
                const currentY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop;
                
                if (Math.abs(currentY - targetY) > 20) {
                    console.log('✅ 최종 보정 - 메인 스크롤 조정:', currentY, '→', targetY);
                    window.scrollTo(\(self.scrollPosition.x), targetY);
                    document.documentElement.scrollTop = targetY;
                    document.body.scrollTop = targetY;
                }
                
                // 2. 페이지 로딩 완료 확인
                if (document.readyState !== 'complete') {
                    console.log('⚠️ 문서 로딩 미완료');
                    return false;
                }
                
                // 3. 이미지 로딩 확인 (주요 이미지만)
                const images = document.querySelectorAll('img[src]:not([data-ad]):not([class*="ad"])');
                let loadedImages = 0;
                let totalImages = 0;
                
                images.forEach(img => {
                    // 뷰포트 근처의 이미지만 확인 (성능상 이유)
                    const rect = img.getBoundingClientRect();
                    if (rect.top < window.innerHeight + 500 && rect.bottom > -500) {
                        totalImages++;
                        if (img.complete && img.naturalHeight > 0) {
                            loadedImages++;
                        }
                    }
                });
                
                const imageLoadRatio = totalImages > 0 ? loadedImages / totalImages : 1;
                console.log('✅ 이미지 로딩 상태:', loadedImages, '/', totalImages, '비율:', imageLoadRatio);
                
                // 4. 최종 스크롤 위치 검증
                const finalY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop;
                const scrollSuccess = Math.abs(finalY - targetY) < 30; // 30px 오차 허용
                
                const overallSuccess = scrollSuccess && imageLoadRatio > 0.7; // 70% 이상 이미지 로드
                
                console.log('✅ 최종 검증 결과:', overallSuccess, '스크롤:', scrollSuccess, '이미지:', imageLoadRatio);
                return overallSuccess;
                
            } catch(e) {
                console.error('✅ 최종 검증 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // iframe 스크롤 복원 스크립트 생성 (기존 유지)
    private func generateIframeScrollScript(_ iframeData: [[String: Any]]) -> String {
        let iframeJSON = convertToJSONString(iframeData) ?? "[]"
        return """
        (function() {
            try {
                const iframes = \(iframeJSON);
                let restored = 0;
                
                for (const iframeInfo of iframes) {
                    const iframe = document.querySelector(iframeInfo.selector);
                    if (iframe && iframe.contentWindow) {
                        try {
                            // Same-origin인 경우에만 접근 가능
                            iframe.contentWindow.scrollTo(
                                iframeInfo.scrollX || 0,
                                iframeInfo.scrollY || 0
                            );
                            restored++;
                        } catch(e) {
                            // Cross-origin iframe은 무시
                            console.log('Cross-origin iframe 스킵:', iframeInfo.selector);
                        }
                    }
                }
                
                console.log('🖼️ iframe 스크롤 복원:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('🖼️ iframe 스크롤 복원 실패:', e);
                return false;
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

// MARK: - 🎯 **대폭 강화된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        loadSiteTimingProfiles()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 **핵심 개선: 단일 직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // 🛡️ **안전접근: 스냅샷 직렬화 큐 (메인 스레드만)**
    private let snapshotQueue = DispatchQueue.main
    
    // MARK: - 💾 스레드 안전 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
    // 🔄 **사이트별 타이밍 프로파일**
    private var _siteTimingProfiles: [String: SiteTimingProfile] = [:]
    
    // 🆕 **동적 콘텐츠 안정화 추적**
    private var _stabilizationTrackers: [UUID: StabilizationTracker] = [:]
    
    // 🛡️ **스냅샷 안전성: 진행 중인 스냅샷 추적**
    private var _activeSnapshotRequests: Set<UUID> = []
    
    // 스레드 안전 액세서
    private var memoryCache: [UUID: BFCacheSnapshot] {
        get { cacheAccessQueue.sync { _memoryCache } }
    }
    
    private func setMemoryCache(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache[pageID] = snapshot
        }
    }
    
    private func removeFromMemoryCache(_ pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache.removeValue(forKey: pageID)
        }
    }
    
    private var diskCacheIndex: [UUID: String] {
        get { cacheAccessQueue.sync { _diskCacheIndex } }
    }
    
    private func setDiskIndex(_ path: String, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._diskCacheIndex[pageID] = path
        }
    }
    
    // 🛡️ **스냅샷 안전성: 중복 요청 방지**
    private func isSnapshotInProgress(for pageID: UUID) -> Bool {
        return cacheAccessQueue.sync { _activeSnapshotRequests.contains(pageID) }
    }
    
    private func markSnapshotInProgress(for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._activeSnapshotRequests.insert(pageID)
        }
    }
    
    private func markSnapshotCompleted(for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._activeSnapshotRequests.remove(pageID)
        }
    }
    
    // 🔄 **사이트별 타이밍 프로파일 관리**
    private func getSiteProfile(for url: URL) -> SiteTimingProfile? {
        guard let hostname = url.host else { return nil }
        return cacheAccessQueue.sync { _siteTimingProfiles[hostname] }
    }
    
    private func updateSiteProfile(_ profile: SiteTimingProfile) {
        cacheAccessQueue.async(flags: .barrier) {
            self._siteTimingProfiles[profile.hostname] = profile
        }
        saveSiteTimingProfiles()
    }
    
    // MARK: - 📁 파일 시스템 경로
    private var bfCacheDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("BFCache", isDirectory: true)
    }
    
    private func tabDirectory(for tabID: UUID) -> URL {
        return bfCacheDirectory.appendingPathComponent("Tab_\(tabID.uuidString)", isDirectory: true)
    }
    
    private func pageDirectory(for pageID: UUID, tabID: UUID, version: Int) -> URL {
        return tabDirectory(for: tabID).appendingPathComponent("Page_\(pageID.uuidString)_v\(version)", isDirectory: true)
    }
    
    // MARK: - 전환 상태
    private var activeTransitions: [UUID: TransitionContext] = [:]
    
    // 전환 컨텍스트
    private struct TransitionContext {
        let tabID: UUID
        weak var webView: WKWebView?
        weak var stateModel: WebViewStateModel?
        var isGesture: Bool
        var direction: NavigationDirection
        var initialTransform: CGAffineTransform
        var previewContainer: UIView?
        var currentSnapshot: UIImage?
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    enum CaptureType {
        case immediate  // 현재 페이지 (높은 우선순위)
        case background // 과거 페이지 (일반 우선순위)
        case leaving    // 떠나는 페이지 (최고 우선순위)
        case arrival    // 도착한 페이지 (안정화 후)
    }
    
    // MARK: - 🆕 **동적 콘텐츠 안정화 추적기**
    private class StabilizationTracker {
        let pageID: UUID
        var domChangeCount = 0
        var lastChangeTime = Date()
        var stabilizationStartTime = Date()
        var contentHashes: [String] = []
        var isStable = false
        
        init(pageID: UUID) {
            self.pageID = pageID
        }
        
        func recordDOMChange(_ contentHash: String) {
            domChangeCount += 1
            lastChangeTime = Date()
            contentHashes.append(contentHash)
            
            // 최근 5개 해시만 유지
            if contentHashes.count > 5 {
                contentHashes.removeFirst()
            }
            
            // 안정성 검사: 3초간 변화 없거나, 최근 3개 해시가 같으면 안정
            let timeSinceLastChange = Date().timeIntervalSince(lastChangeTime)
            let recentHashesStable = contentHashes.count >= 3 && 
                                   Set(contentHashes.suffix(3)).count == 1
            
            isStable = timeSinceLastChange > 3.0 || recentHashesStable
        }
        
        var stabilizationInfo: BFCacheSnapshot.StabilizationInfo {
            return BFCacheSnapshot.StabilizationInfo(
                stabilizationDuration: Date().timeIntervalSince(stabilizationStartTime),
                domChangeCount: domChangeCount,
                finalStableAt: lastChangeTime,
                contentHash: contentHashes.last ?? "",
                adRegionsDetected: [] // TODO: 광고 영역 감지 로직 추가
            )
        }
    }
    
    // MARK: - 🛡️ **스냅샷 안전접근: 웹뷰 상태 검증 강화**
    
    private func validateWebViewForSnapshot(_ webView: WKWebView) -> Bool {
        // 🛡️ **메인 스레드 확인**
        guard Thread.isMainThread else {
            dbg("❌ 스냅샷 실패: 메인 스레드가 아님")
            return false
        }
        
        // 🛡️ **웹뷰 기본 상태 확인**
        guard webView.window != nil else {
            dbg("❌ 스냅샷 실패: 웹뷰가 윈도우에 없음")
            return false
        }
        
        guard !webView.bounds.isEmpty else {
            dbg("❌ 스냅샷 실패: 웹뷰 bounds가 비어있음")
            return false
        }
        
        guard webView.superview != nil else {
            dbg("❌ 스냅샷 실패: 웹뷰가 뷰 계층에 없음")
            return false
        }
        
        // 🛡️ **렌더링 상태 확인**
        guard !webView.isLoading else {
            dbg("⚠️ 스냅샷 주의: 웹뷰 로딩 중")
            // 로딩 중이어도 스냅샷은 시도 (로딩 상태도 캡처할 수 있음)
        }
        
        return true
    }
    
    // MARK: - 🔧 **핵심 개선: 렌더링 완료 대기 + 안정화 캡처 시스템**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
        let waitForStabilization: Bool
    }
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil, waitForStabilization: Bool = false) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let pageID = pageRecord.id
        
        // 🛡️ **중복 스냅샷 방지**
        if isSnapshotInProgress(for: pageID) {
            dbg("⏸️ 중복 스냅샷 방지: \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(
            pageRecord: pageRecord, 
            tabID: tabID, 
            type: type, 
            webView: webView,
            waitForStabilization: waitForStabilization
        )
        
        // 🛡️ **메인 스레드에서 직접 처리 (직렬화)**
        if Thread.isMainThread {
            performSafeCapture(task)
        } else {
            snapshotQueue.async { [weak self] in
                self?.performSafeCapture(task)
            }
        }
    }
    
    private func performSafeCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 🛡️ **스냅샷 진행 중으로 마킹**
        markSnapshotInProgress(for: pageID)
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            markSnapshotCompleted(for: pageID)
            return
        }
        
        // 🛡️ **웹뷰 상태 검증**
        guard validateWebViewForSnapshot(webView) else {
            dbg("❌ 웹뷰 상태 검증 실패 - 캡처 취소: \(task.pageRecord.title)")
            markSnapshotCompleted(for: pageID)
            return
        }
        
        dbg("🎯 안전한 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        if task.waitForStabilization {
            // 🆕 **안정화 대기 후 캡처**
            waitForStabilizationThenCapture(task)
        } else {
            // **즉시 캡처 (기존 로직 강화)**
            performImmediateSafeCapture(task)
        }
    }
    
    // 🆕 **동적 콘텐츠 안정화 대기 시스템**
    private func waitForStabilizationThenCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 안정화 추적기 시작
        let tracker = StabilizationTracker(pageID: pageID)
        cacheAccessQueue.async(flags: .barrier) {
            self._stabilizationTrackers[pageID] = tracker
        }
        
        dbg("⏳ 동적 콘텐츠 안정화 대기 시작: \(task.pageRecord.title)")
        
        // 안정화 확인 스크립트 실행
        checkStabilizationLoop(task, tracker: tracker, attempt: 0)
    }
    
    private func checkStabilizationLoop(_ task: CaptureTask, tracker: StabilizationTracker, attempt: Int) {
        guard let webView = task.webView, attempt < 20 else { // 최대 10초 대기 (0.5초 * 20)
            dbg("⏰ 안정화 대기 타임아웃: \(task.pageRecord.title)")
            performImmediateSafeCapture(task, stabilizationInfo: tracker.stabilizationInfo)
            return
        }
        
        // 🛡️ **웹뷰 상태 재검증**
        guard validateWebViewForSnapshot(webView) else {
            dbg("❌ 안정화 중 웹뷰 상태 변경 - 캡처 취소: \(task.pageRecord.title)")
            markSnapshotCompleted(for: task.pageRecord.id)
            return
        }
        
        let stabilizationCheckJS = generateStabilizationCheckScript()
        
        webView.evaluateJavaScript(stabilizationCheckJS) { [weak self] result, error in
            // 🛡️ **메인 스레드에서 처리**
            DispatchQueue.main.async {
                if let data = result as? [String: Any],
                   let contentHash = data["contentHash"] as? String,
                   let isStable = data["isStable"] as? Bool {
                    
                    tracker.recordDOMChange(contentHash)
                    
                    if tracker.isStable || isStable {
                        self?.dbg("✅ 콘텐츠 안정화 완료: \(task.pageRecord.title) (시도: \(attempt + 1))")
                        self?.performImmediateSafeCapture(task, stabilizationInfo: tracker.stabilizationInfo)
                    } else {
                        // 0.5초 후 재시도
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self?.checkStabilizationLoop(task, tracker: tracker, attempt: attempt + 1)
                        }
                    }
                } else {
                    self?.dbg("⚠️ 안정화 확인 실패, 즉시 캡처: \(task.pageRecord.title)")
                    self?.performImmediateSafeCapture(task, stabilizationInfo: tracker.stabilizationInfo)
                }
            }
        }
    }
    
    // 🆕 **안정화 확인 JavaScript**
    private func generateStabilizationCheckScript() -> String {
        return """
        (function() {
            try {
                // 1. 로딩 상태 확인
                if (document.readyState !== 'complete') {
                    return { isStable: false, contentHash: '', reason: 'loading' };
                }
                
                // 2. 주요 콘텐츠 영역 해시 생성
                const mainContentSelectors = [
                    'main', '[role="main"]', 'article', '.content', '#content',
                    '.main-content', '.post-content', '.article-content'
                ];
                
                let mainContent = null;
                for (const selector of mainContentSelectors) {
                    mainContent = document.querySelector(selector);
                    if (mainContent) break;
                }
                
                if (!mainContent) {
                    mainContent = document.body;
                }
                
                // 3. 이미지 로딩 확인 (뷰포트 근처만)
                const images = mainContent.querySelectorAll('img[src]');
                let loadingImages = 0;
                
                images.forEach(img => {
                    const rect = img.getBoundingClientRect();
                    if (rect.top < window.innerHeight + 200 && rect.bottom > -200) {
                        if (!img.complete || img.naturalHeight === 0) {
                            loadingImages++;
                        }
                    }
                });
                
                // 4. 콘텐츠 해시 생성 (텍스트 + 구조)
                const textContent = (mainContent.textContent || '').trim().slice(0, 1000);
                const structureHash = mainContent.children.length.toString();
                const contentHash = textContent + '|' + structureHash;
                
                // 5. 안정성 판단
                const isStable = loadingImages === 0 && contentHash.length > 10;
                
                return {
                    isStable: isStable,
                    contentHash: contentHash,
                    loadingImages: loadingImages,
                    textLength: textContent.length,
                    childrenCount: mainContent.children.length
                };
                
            } catch(e) {
                return { isStable: false, contentHash: '', error: e.message };
            }
        })()
        """
    }
    
    // 🛡️ **강화된 즉시 캡처 로직 - 완전한 메인 스레드 보장**
    private func performImmediateSafeCapture(_ task: CaptureTask, stabilizationInfo: BFCacheSnapshot.StabilizationInfo? = nil) {
        // 🛡️ **메인 스레드 보장**
        assert(Thread.isMainThread, "스냅샷 캡처는 반드시 메인 스레드에서 수행되어야 합니다")
        
        guard let webView = task.webView else {
            markSnapshotCompleted(for: task.pageRecord.id)
            return
        }
        
        // 🛡️ **웹뷰 상태 최종 검증**
        guard validateWebViewForSnapshot(webView) else {
            dbg("❌ 최종 웹뷰 검증 실패 - 캡처 취소: \(task.pageRecord.title)")
            markSnapshotCompleted(for: task.pageRecord.id)
            return
        }
        
        // 🛡️ **캡처 데이터 수집**
        let captureData = CaptureData(
            scrollPosition: webView.scrollView.contentOffset,
            bounds: webView.bounds,
            isLoading: webView.isLoading
        )
        
        // 🔧 **개선된 캡처 로직 - 렌더링 완료 대기 추가**
        let captureResult = performRenderingCompleteCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: captureData,
            retryCount: task.type == .immediate || task.type == .leaving ? 2 : 0,  // 중요한 캡처는 재시도
            stabilizationInfo: stabilizationInfo
        )
        
        // 캡처 완료 후 저장 (백그라운드에서)
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: task.pageRecord.id)
        }
        
        // 🛡️ **진행 중 해제**
        markSnapshotCompleted(for: task.pageRecord.id)
        
        // 안정화 추적기 제거
        cacheAccessQueue.async(flags: .barrier) {
            self._stabilizationTrackers.removeValue(forKey: task.pageRecord.id)
        }
        
        dbg("✅ 안전한 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🛡️ **렌더링 완료 대기가 포함된 캡처 (완전한 메인 스레드)**
    private func performRenderingCompleteCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0, stabilizationInfo: BFCacheSnapshot.StabilizationInfo?) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        // 🛡️ **메인 스레드 보장**
        assert(Thread.isMainThread, "렌더링 캡처는 반드시 메인 스레드에서 수행되어야 합니다")
        
        for attempt in 0...retryCount {
            // 📍 **1단계: 렌더링 완료 대기**
            if !waitForRenderingComplete(webView: webView, timeout: 2.0) {
                dbg("⏰ 렌더링 완료 대기 타임아웃 (시도: \(attempt + 1))")
            }
            
            // 🛡️ **웹뷰 상태 재검증**
            guard validateWebViewForSnapshot(webView) else {
                dbg("❌ 렌더링 대기 후 웹뷰 상태 변경: \(pageRecord.title)")
                break
            }
            
            let result = attemptSafeAdvancedCapture(
                pageRecord: pageRecord, 
                webView: webView, 
                captureData: captureData,
                stabilizationInfo: stabilizationInfo
            )
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기
            dbg("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.1) // 안정성을 위해 대기 시간 증가
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    // 📍 **렌더링 완료 대기 함수 - 메인 스레드에서만 실행**
    private func waitForRenderingComplete(webView: WKWebView, timeout: TimeInterval) -> Bool {
        // 🛡️ **메인 스레드 확인**
        assert(Thread.isMainThread, "렌더링 완료 대기는 메인 스레드에서만 수행")
        
        let semaphore = DispatchSemaphore(value: 0)
        var renderingComplete = false
        
        let renderingCheckJS = """
        (function() {
            // 1. 기본 로딩 상태 확인
            if (document.readyState !== 'complete') {
                return false;
            }
            
            // 2. 이미지 로딩 확인 (뷰포트 내 + 근처)
            const images = document.querySelectorAll('img[src]');
            let pendingImages = 0;
            
            images.forEach(img => {
                const rect = img.getBoundingClientRect();
                // 뷰포트 + 500px 범위 내 이미지만 확인
                if (rect.top < window.innerHeight + 500 && rect.bottom > -500) {
                    if (!img.complete || img.naturalHeight === 0) {
                        pendingImages++;
                    }
                }
            });
            
            // 3. 스타일시트 로딩 확인
            const stylesheets = document.querySelectorAll('link[rel="stylesheet"]');
            let pendingStylesheets = 0;
            
            stylesheets.forEach(link => {
                if (link.sheet === null) {
                    pendingStylesheets++;
                }
            });
            
            // 4. 주요 콘텐츠 영역 존재 확인
            const mainContent = document.querySelector('main, [role="main"], article, .content, #content') || document.body;
            const hasContent = mainContent && mainContent.children.length > 0;
            
            const isComplete = pendingImages === 0 && pendingStylesheets === 0 && hasContent;
            
            return {
                complete: isComplete,
                pendingImages: pendingImages,
                pendingStylesheets: pendingStylesheets,
                hasContent: hasContent
            };
        })()
        """
        
        webView.evaluateJavaScript(renderingCheckJS) { result, error in
            if let data = result as? [String: Any],
               let complete = data["complete"] as? Bool {
                renderingComplete = complete
            } else {
                renderingComplete = false // 스크립트 실행 실패시 false
            }
            semaphore.signal()
        }
        
        let result = semaphore.wait(timeout: .now() + timeout)
        return result == .success && renderingComplete
    }
    
    // 🛡️ **안전한 고급 캡처 로직 (완전한 메인 스레드)**
    private func attemptSafeAdvancedCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, stabilizationInfo: BFCacheSnapshot.StabilizationInfo?) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        // 🛡️ **메인 스레드 보장**
        assert(Thread.isMainThread, "고급 캡처는 반드시 메인 스레드에서 수행")
        
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var anchorPosition: BFCacheSnapshot.AnchorBasedPosition? = nil
        var infiniteScrollState: BFCacheSnapshot.InfiniteScrollState? = nil
        
        // 🛡️ **1단계: 비주얼 스냅샷 (동기식 - 안전함)**
        let config = WKSnapshotConfiguration()
        config.rect = captureData.bounds
        config.afterScreenUpdates = true // 렌더링 업데이트 후 캡처
        
        let semaphore = DispatchSemaphore(value: 0)
        
        webView.takeSnapshot(with: config) { image, error in
            if let error = error {
                self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                // Fallback: layer 렌더링 (메인 스레드에서만 안전)
                DispatchQueue.main.async {
                    visualSnapshot = self.renderWebViewToImage(webView)
                    semaphore.signal()
                }
            } else {
                visualSnapshot = image
                semaphore.signal()
            }
        }
        
        // ⚡ 적절한 타임아웃 (메인 스레드 블록킹 최소화)
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캐처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 🛡️ **2단계: DOM 캡처 - 동기식**
        let domSemaphore = DispatchSemaphore(value: 0)
        let domScript = """
        (function() {
            try {
                if (document.readyState !== 'complete') return null;
                
                // 🚫 **눌린 상태/활성 상태 모두 제거**
                document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(el => {
                    el.classList.remove(...Array.from(el.classList).filter(c => 
                        c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus')
                    ));
                });
                
                // input focus 제거
                document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(el => {
                    el.blur();
                });
                
                const html = document.documentElement.outerHTML;
                return html.length > 100000 ? html.substring(0, 100000) : html;
            } catch(e) { return null; }
        })()
        """
        
        webView.evaluateJavaScript(domScript) { result, error in
            domSnapshot = result as? String
            domSemaphore.signal()
        }
        _ = domSemaphore.wait(timeout: .now() + 1.0)
        
        // 🛡️ **3단계: 고급 JS 상태 캡처 - 동기식**
        let jsSemaphore = DispatchSemaphore(value: 0)
        let jsScript = generateAdvancedStateScript()
        
        webView.evaluateJavaScript(jsScript) { result, error in
            if let data = result as? [String: Any] {
                jsState = data
                
                // 앵커 정보 추출
                if let anchorData = data["anchor"] as? [String: Any] {
                    anchorPosition = self.parseAnchorPosition(anchorData)
                }
                
                // 무한 스크롤 정보 추출
                if let infiniteData = data["infiniteScroll"] as? [String: Any] {
                    infiniteScrollState = self.parseInfiniteScrollState(infiniteData)
                }
            }
            jsSemaphore.signal()
        }
        _ = jsSemaphore.wait(timeout: .now() + 1.5) // 복잡한 스크립트이므로 여유시간 증가
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = stabilizationInfo != nil ? .complete : .partial
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 버전 증가 (스레드 안전)
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            jsState: jsState,
            timestamp: Date(),
            webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
            captureStatus: captureStatus,
            version: version,
            anchorBasedPosition: anchorPosition,
            infiniteScrollState: infiniteScrollState,
            stabilizationInfo: stabilizationInfo
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🎯 **핵심 개선: 고급 상태 캡처 JavaScript 생성**
    private func generateAdvancedStateScript() -> String {
        return """
        (function() {
            try {
                // 🎯 **1. 앵커 기반 위치 정보 생성**
                function generateAnchorBasedPosition() {
                    const viewportTop = window.scrollY || document.documentElement.scrollTop;
                    const viewportBottom = viewportTop + window.innerHeight;
                    const viewportCenter = viewportTop + (window.innerHeight / 2);
                    
                    // 뷰포트 중앙 근처의 의미있는 요소 찾기
                    const candidateSelectors = [
                        'article', 'section', '[data-id]', '[id]', 'h1', 'h2', 'h3',
                        '.post', '.item', '.card', '.content-item', '.article-item',
                        'p', '.paragraph', '.text-content'
                    ];
                    
                    let bestAnchor = null;
                    let bestDistance = Infinity;
                    
                    for (const selector of candidateSelectors) {
                        const elements = document.querySelectorAll(selector);
                        elements.forEach((el, index) => {
                            const rect = el.getBoundingClientRect();
                            const elementTop = viewportTop + rect.top;
                            const elementCenter = elementTop + (rect.height / 2);
                            
                            // 뷰포트 내에 있거나 근처에 있는 요소만 고려
                            if (elementTop < viewportBottom + 200 && elementTop + rect.height > viewportTop - 200) {
                                const distance = Math.abs(elementCenter - viewportCenter);
                                
                                if (distance < bestDistance && rect.height > 20 && rect.width > 20) {
                                    bestDistance = distance;
                                    bestAnchor = {
                                        element: el,
                                        selector: selector,
                                        index: index,
                                        rect: rect,
                                        elementTop: elementTop
                                    };
                                }
                            }
                        });
                    }
                    
                    if (bestAnchor) {
                        const offsetFromAnchor = {
                            x: window.scrollX - bestAnchor.rect.left,
                            y: viewportTop - bestAnchor.elementTop
                        };
                        
                        return {
                            anchorSelector: bestAnchor.selector,
                            anchorId: bestAnchor.element.id || null,
                            offsetFromAnchor: offsetFromAnchor,
                            anchorBounds: {
                                x: bestAnchor.rect.left,
                                y: bestAnchor.rect.top,
                                width: bestAnchor.rect.width,
                                height: bestAnchor.rect.height
                            },
                            anchorText: (bestAnchor.element.textContent || '').slice(0, 100),
                            anchorIndex: bestAnchor.index
                        };
                    }
                    
                    return null;
                }
                
                // ♾️ **2. 무한 스크롤 상태 감지**
                function detectInfiniteScrollState() {
                    // 무한 스크롤 컨테이너 감지
                    const infiniteScrollSelectors = [
                        '[data-infinite-scroll]', '.infinite-scroll', '.infinite-container',
                        '[data-scroll-container]', '.scroll-container', '.feed-container',
                        '[data-virtualized]', '.virtualized', '.feed', '.timeline',
                        'main', '[role="main"]'
                    ];
                    
                    let container = null;
                    let containerSelector = null;
                    
                    for (const selector of infiniteScrollSelectors) {
                        container = document.querySelector(selector);
                        if (container && container.children.length > 10) { // 10개 이상 아이템이 있어야 무한 스크롤로 간주
                            containerSelector = selector;
                            break;
                        }
                    }
                    
                    if (!container) {
                        return null;
                    }
                    
                    // 아이템 분석
                    const children = Array.from(container.children);
                    const totalItems = children.length;
                    
                    // 현재 뷰포트 내 마지막 보이는 아이템 찾기
                    const viewportBottom = window.scrollY + window.innerHeight;
                    let lastVisibleItem = null;
                    
                    for (let i = children.length - 1; i >= 0; i--) {
                        const child = children[i];
                        const rect = child.getBoundingClientRect();
                        const itemTop = window.scrollY + rect.top;
                        
                        if (itemTop < viewportBottom) {
                            lastVisibleItem = child;
                            break;
                        }
                    }
                    
                    // 더 많은 콘텐츠가 있는지 확인
                    const hasMoreContent = document.querySelector('.loading, .load-more, [data-loading]') !== null ||
                                          container.scrollHeight > container.clientHeight * 1.5;
                    
                    return {
                        totalItems: totalItems,
                        loadedItems: totalItems,
                        currentPageNumber: null, // TODO: 페이지 번호 감지 로직
                        lastVisibleItemId: lastVisibleItem ? lastVisibleItem.id : null,
                        scrollContainerSelector: containerSelector,
                        hasMoreContent: hasMoreContent,
                        estimatedTotalHeight: container.scrollHeight || document.body.scrollHeight
                    };
                }
                
                // 🔍 **3. 기존 스크롤 감지 시스템 (광고 제외 강화)**
                function findAllScrollableElements() {
                    const scrollables = [];
                    const maxElements = 50;
                    
                    // 광고 패턴 강화
                    const adPatterns = [
                        '[id*="ad"]', '[class*="ad"]', '[data-ad]',
                        '[id*="banner"]', '[class*="banner"]',
                        '[id*="sponsor"]', '[class*="sponsor"]',
                        '.advertisement', '.ads', '.advert',
                        'iframe[src*="doubleclick"]', 'iframe[src*="googlesyndication"]',
                        '[data-google-ad]', '[data-ad-client]',
                        '.google-ad', '.adsense', '[class*="adsense"]'
                    ];
                    
                    function isAdElement(element) {
                        for (const pattern of adPatterns) {
                            try {
                                if (element.matches && element.matches(pattern)) {
                                    return true;
                                }
                            } catch(e) {}
                        }
                        
                        const className = element.className || '';
                        const id = element.id || '';
                        const combinedText = (className + ' ' + id).toLowerCase();
                        
                        const adKeywords = ['ad', 'banner', 'sponsor', 'promo', 'commercial', 'adsense'];
                        return adKeywords.some(keyword => combinedText.includes(keyword));
                    }
                    
                    const explicitScrollables = document.querySelectorAll('*');
                    let count = 0;
                    
                    for (const el of explicitScrollables) {
                        if (count >= maxElements) break;
                        
                        // 광고 요소 제외
                        if (isAdElement(el)) continue;
                        
                        const style = window.getComputedStyle(el);
                        const overflowY = style.overflowY;
                        const overflowX = style.overflowX;
                        
                        if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                            (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) {
                            
                            // 의미있는 스크롤 위치만 저장 (5px 이상)
                            if (el.scrollTop > 5 || el.scrollLeft > 5) {
                                const selector = generateBestSelector(el);
                                if (selector) {
                                    scrollables.push({
                                        selector: selector,
                                        top: el.scrollTop,
                                        left: el.scrollLeft,
                                        maxTop: el.scrollHeight - el.clientHeight,
                                        maxLeft: el.scrollWidth - el.clientWidth,
                                        id: el.id || '',
                                        className: el.className || '',
                                        tagName: el.tagName.toLowerCase(),
                                        isImportant: el.scrollTop > 50 || el.scrollLeft > 50 // 중요도 플래그
                                    });
                                    count++;
                                }
                            }
                        }
                    }
                    
                    return scrollables;
                }
                
                // iframe 감지 (기존 로직 유지)
                function detectIframeScrolls() {
                    const iframes = [];
                    const iframeElements = document.querySelectorAll('iframe');
                    
                    for (const iframe of iframeElements) {
                        try {
                            const contentWindow = iframe.contentWindow;
                            if (contentWindow && contentWindow.location) {
                                const scrollX = contentWindow.scrollX || 0;
                                const scrollY = contentWindow.scrollY || 0;
                                
                                if (scrollX > 5 || scrollY > 5) { // 5px 이상만 의미있다고 간주
                                    iframes.push({
                                        selector: generateBestSelector(iframe) || `iframe[src*="${iframe.src.split('/').pop()}"]`,
                                        scrollX: scrollX,
                                        scrollY: scrollY,
                                        src: iframe.src || '',
                                        id: iframe.id || '',
                                        className: iframe.className || ''
                                    });
                                }
                            }
                        } catch(e) {
                            // Cross-origin iframe은 접근 불가 - 무시
                        }
                    }
                    
                    return iframes;
                }
                
                // 최적의 selector 생성 (기존 로직 유지)
                function generateBestSelector(element) {
                    if (!element || element.nodeType !== 1) return null;
                    
                    if (element.id) {
                        return `#${element.id}`;
                    }
                    
                    if (element.className) {
                        const classes = element.className.trim().split(/\\s+/);
                        const uniqueClasses = classes.filter(cls => {
                            const elements = document.querySelectorAll(`.${cls}`);
                            return elements.length === 1 && elements[0] === element;
                        });
                        
                        if (uniqueClasses.length > 0) {
                            return `.${uniqueClasses[0]}`;
                        }
                        
                        if (classes.length > 0) {
                            const classSelector = `.${classes.join('.')}`;
                            if (document.querySelectorAll(classSelector).length === 1) {
                                return classSelector;
                            }
                        }
                    }
                    
                    const tag = element.tagName.toLowerCase();
                    const attributes = [];
                    
                    for (const attr of element.attributes) {
                        if (attr.name.startsWith('data-')) {
                            attributes.push(`[${attr.name}="${attr.value}"]`);
                        }
                    }
                    
                    if (attributes.length > 0) {
                        const attrSelector = tag + attributes.join('');
                        if (document.querySelectorAll(attrSelector).length === 1) {
                            return attrSelector;
                        }
                    }
                    
                    let parent = element.parentElement;
                    if (parent) {
                        const siblings = Array.from(parent.children);
                        const index = siblings.indexOf(element);
                        if (index !== -1) {
                            return `${parent.tagName.toLowerCase()} > ${tag}:nth-child(${index + 1})`;
                        }
                    }
                    
                    return tag;
                }
                
                // 🔍 **메인 실행**
                const anchorPosition = generateAnchorBasedPosition();
                const infiniteScrollState = detectInfiniteScrollState();
                const scrollableElements = findAllScrollableElements();
                const iframeScrolls = detectIframeScrolls();
                
                console.log(`🔍 고급 상태 캡처: 앵커 ${anchorPosition ? '✅' : '❌'}, 무한스크롤 ${infiniteScrollState ? '✅' : '❌'}, 스크롤요소 ${scrollableElements.length}개, iframe ${iframeScrolls.length}개`);
                
                return {
                    anchor: anchorPosition,
                    infiniteScroll: infiniteScrollState,
                    scroll: { 
                        x: window.scrollX, 
                        y: window.scrollY,
                        elements: scrollableElements
                    },
                    iframes: iframeScrolls,
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now(),
                    userAgent: navigator.userAgent,
                    viewport: {
                        width: window.innerWidth,
                        height: window.innerHeight
                    }
                };
            } catch(e) { 
                console.error('고급 상태 캡처 실패:', e);
                return {
                    anchor: null,
                    infiniteScroll: null,
                    scroll: { x: window.scrollX, y: window.scrollY, elements: [] },
                    iframes: [],
                    href: window.location.href,
                    title: document.title,
                    error: e.message
                };
            }
        })()
        """
    }
    
    // 🎯 **앵커 위치 정보 파싱**
    private func parseAnchorPosition(_ data: [String: Any]) -> BFCacheSnapshot.AnchorBasedPosition? {
        guard let selector = data["anchorSelector"] as? String,
              let offsetData = data["offsetFromAnchor"] as? [String: Any],
              let offsetX = offsetData["x"] as? Double,
              let offsetY = offsetData["y"] as? Double,
              let boundsData = data["anchorBounds"] as? [String: Any],
              let boundsX = boundsData["x"] as? Double,
              let boundsY = boundsData["y"] as? Double,
              let boundsWidth = boundsData["width"] as? Double,
              let boundsHeight = boundsData["height"] as? Double,
              let anchorIndex = data["anchorIndex"] as? Int else {
            return nil
        }
        
        return BFCacheSnapshot.AnchorBasedPosition(
            anchorSelector: selector,
            anchorId: data["anchorId"] as? String,
            offsetFromAnchor: CGPoint(x: offsetX, y: offsetY),
            anchorBounds: CGRect(x: boundsX, y: boundsY, width: boundsWidth, height: boundsHeight),
            anchorText: data["anchorText"] as? String,
            anchorIndex: anchorIndex
        )
    }
    
    // ♾️ **무한 스크롤 상태 파싱**
    private func parseInfiniteScrollState(_ data: [String: Any]) -> BFCacheSnapshot.InfiniteScrollState? {
        guard let totalItems = data["totalItems"] as? Int,
              let loadedItems = data["loadedItems"] as? Int,
              let hasMoreContent = data["hasMoreContent"] as? Bool,
              let estimatedTotalHeight = data["estimatedTotalHeight"] as? Double else {
            return nil
        }
        
        return BFCacheSnapshot.InfiniteScrollState(
            totalItems: totalItems,
            loadedItems: loadedItems,
            currentPageNumber: data["currentPageNumber"] as? Int,
            lastVisibleItemId: data["lastVisibleItemId"] as? String,
            scrollContainerSelector: data["scrollContainerSelector"] as? String,
            hasMoreContent: hasMoreContent,
            estimatedTotalHeight: estimatedTotalHeight
        )
    }
    
    // 🛡️ **안전한 이미지 렌더링 (메인 스레드만)**
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        // 🛡️ **메인 스레드 확인**
        assert(Thread.isMainThread, "이미지 렌더링은 메인 스레드에서만 수행")
        
        guard !webView.bounds.isEmpty else { return nil }
        
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 **개선된 디스크 저장 시스템** (기존 로직 유지)
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            // 디렉토리 생성
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // 1. 이미지 저장 (JPEG 압축)
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    do {
                        try jpegData.write(to: imagePath)
                        finalSnapshot.webViewSnapshotPath = imagePath.path
                        self.dbg("💾 이미지 저장 성공: \(imagePath.lastPathComponent)")
                    } catch {
                        self.dbg("❌ 이미지 저장 실패: \(error.localizedDescription)")
                    }
                }
            }
            
            // 2. 상태 데이터 저장 (JSON)
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                do {
                    try stateData.write(to: statePath)
                    self.dbg("💾 상태 저장 성공: \(statePath.lastPathComponent)")
                } catch {
                    self.dbg("❌상태 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 3. 메타데이터 저장
            let metadata = CacheMetadata(
                pageID: pageID,
                tabID: tabID,
                version: version,
                timestamp: Date(),
                url: snapshot.snapshot.pageRecord.url.absoluteString,
                title: snapshot.snapshot.pageRecord.title
            )
            
            let metadataPath = pageDir.appendingPathComponent("metadata.json")
            if let metadataData = try? JSONEncoder().encode(metadata) {
                do {
                    try metadataData.write(to: metadataPath)
                } catch {
                    self.dbg("❌ 메타데이터 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 4. 인덱스 업데이트 (원자적)
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
            // 5. 이전 버전 정리 (최신 3개만 유지)
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
        }
    }
    
    private struct CacheMetadata: Codable {
        let pageID: UUID
        let tabID: UUID
        let version: Int
        let timestamp: Date
        let url: String
        let title: String
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private func cleanupOldVersions(pageID: UUID, tabID: UUID, currentVersion: Int) {
        let tabDir = tabDirectory(for: tabID)
        let pagePrefix = "Page_\(pageID.uuidString)_v"
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil)
            let pageDirs = contents.filter { $0.lastPathComponent.hasPrefix(pagePrefix) }
                .sorted { url1, url2 in
                    let v1 = Int(url1.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    let v2 = Int(url2.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    return v1 > v2  // 최신 버전부터
                }
            
            // 최신 3개 제외하고 삭제
            if pageDirs.count > 3 {
                for i in 3..<pageDirs.count {
                    try FileManager.default.removeItem(at: pageDirs[i])
                    dbg("🗑️ 이전 버전 삭제: \(pageDirs[i].lastPathComponent)")
                }
            }
        } catch {
            dbg("⚠️ 이전 버전 정리 실패: \(error)")
        }
    }
    
    // MARK: - 💾 **개선된 디스크 캐시 로딩** (기존 로직 유지)
    
    private func loadDiskCacheIndex() {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            // BFCache 디렉토리 생성
            self.createDirectoryIfNeeded(at: self.bfCacheDirectory)
            
            var loadedCount = 0
            
            // 모든 탭 디렉토리 스캔
            do {
                let tabDirs = try FileManager.default.contentsOfDirectory(at: self.bfCacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                
                for tabDir in tabDirs {
                    if tabDir.lastPathComponent.hasPrefix("Tab_") {
                        // 각 페이지 디렉토리 스캔
                        let pageDirs = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        
                        for pageDir in pageDirs {
                            if pageDir.lastPathComponent.hasPrefix("Page_") {
                                // metadata.json 로드
                                let metadataPath = pageDir.appendingPathComponent("metadata.json")
                                if let data = try? Data(contentsOf: metadataPath),
                                   let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) {
                                    
                                    // 스레드 안전하게 인덱스 업데이트
                                    self.setDiskIndex(pageDir.path, for: metadata.pageID)
                                    self.cacheAccessQueue.async(flags: .barrier) {
                                        self._cacheVersion[metadata.pageID] = metadata.version
                                    }
                                    loadedCount += 1
                                }
                            }
                        }
                    }
                }
                
                self.dbg("💾 디스크 캐시 인덱스 로드 완료: \(loadedCount)개 항목")
            } catch {
                self.dbg("❌ 디스크 캐시 로드 실패: \(error)")
            }
        }
    }
    
    // MARK: - 🔄 **사이트별 타이밍 프로파일 관리** (기존 로직 유지)
    
    private func loadSiteTimingProfiles() {
        if let data = UserDefaults.standard.data(forKey: "BFCache.SiteTimingProfiles"),
           let profiles = try? JSONDecoder().decode([String: SiteTimingProfile].self, from: data) {
            cacheAccessQueue.async(flags: .barrier) {
                self._siteTimingProfiles = profiles
            }
            dbg("🔄 사이트 타이밍 프로파일 로드: \(profiles.count)개")
        }
    }
    
    private func saveSiteTimingProfiles() {
        let profiles = cacheAccessQueue.sync { _siteTimingProfiles }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "BFCache.SiteTimingProfiles")
        }
    }
    
    // MARK: - 🔍 **개선된 스냅샷 조회 시스템** (기존 로직 유지)
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        // 1. 먼저 메모리 캐시 확인 (스레드 안전)
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인 (스레드 안전)
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장 (최적화)
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title)")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
    // MARK: - 🔧 **수정: hasCache 메서드 추가**
    func hasCache(for pageID: UUID) -> Bool {
        // 메모리 캐시 체크
        if cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) != nil {
            return true
        }
        
        // 디스크 캐시 인덱스 체크
        if cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) != nil {
            return true
        }
        
        return false
    }
    
    // MARK: - 메모리 캐시 관리
    
    private func storeInMemory(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        setMemoryCache(snapshot, for: pageID)
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)]")
    }
    
    // MARK: - 🧹 **개선된 캐시 정리** (기존 로직 유지)
    
    // 탭 닫을 때만 호출 (무제한 캐시 정책)
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        // 메모리에서 제거 (스레드 안전)
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
                self._cacheVersion.removeValue(forKey: pageID)
                self._stabilizationTrackers.removeValue(forKey: pageID)
                self._activeSnapshotRequests.remove(pageID)
            }
        }
        
        // 디스크에서 제거
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            let tabDir = self.tabDirectory(for: tabID)
            do {
                try FileManager.default.removeItem(at: tabDir)
                self.dbg("🗑️ 탭 캐시 완전 삭제: \(tabID.uuidString)")
            } catch {
                self.dbg("⚠️ 탭 캐시 삭제 실패: \(error)")
            }
        }
    }
    
    // 메모리 경고 처리 (메모리 캐시만 일부 정리)
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }
    
    private func handleMemoryWarning() {
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let beforeCount = self._memoryCache.count
            
            // 메모리 캐시의 절반 정리 (오래된 것부터)
            let sorted = self._memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            // 🛡️ **메모리 경고 시 진행 중인 스냅샷도 일부 정리**
            self._activeSnapshotRequests.removeAll()
            
            self.dbg("⚠️ 메모리 경고 - 메모리 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🛡️ **안전한 제스처 시스템** (기존 로직 유지 + 스냅샷 안전성 강화)
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        // 네이티브 제스처 비활성화
        webView.allowsBackForwardNavigationGestures = false
        
        // 왼쪽 엣지 - 뒤로가기
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        webView.addGestureRecognizer(leftEdge)
        
        // 오른쪽 엣지 - 앞으로가기  
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        webView.addGestureRecognizer(rightEdge)
        
        // 약한 참조 컨텍스트 생성 및 연결 (순환 참조 방지)
        if let tabID = stateModel.tabID {
            let ctx = WeakGestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
            objc_setAssociatedObject(leftEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(rightEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        dbg("BFCache 제스처 설정 완료")
    }
    
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        // 약한 참조 컨텍스트 조회 (순환 참조 방지)
        guard let ctx = objc_getAssociatedObject(gesture, "bfcache_ctx") as? WeakGestureContext,
              let stateModel = ctx.stateModel else { return }
        let webView = ctx.webView ?? (gesture.view as? WKWebView)
        guard let webView else { return }
        
        let tabID = ctx.tabID
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        let width = gesture.view?.bounds.width ?? 1
        
        // 수직 슬롭/부호 반대 방지
        let absX = abs(translation.x), absY = abs(translation.y)
        let horizontalEnough = absX > 8 && absX > absY
        let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
        
        switch gesture.state {
        case .began:
            // 🛡️ **핵심 1: 전환 중이면 새 제스처 무시**
            guard activeTransitions[tabID] == nil else { 
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 🛡️ **핵심 3: 혹시 남아있는 기존 전환 강제 정리**
                if let existing = activeTransitions[tabID] {
                    existing.previewContainer?.removeFromSuperview()
                    activeTransitions.removeValue(forKey: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                // 🆕 **개선된 떠나는 페이지 캡처 (최고 우선순위)**
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .leaving, tabID: tabID, waitForStabilization: false)
                }
                
                // 🛡️ **안전한 현재 웹뷰 스냅샷 캡처 후 전환 시작**
                captureSafeCurrentSnapshot(webView: webView) { [weak self] snapshot in
                    self?.beginGestureTransitionWithSnapshot(
                        tabID: tabID,
                        webView: webView,
                        stateModel: stateModel,
                        direction: direction,
                        currentSnapshot: snapshot
                    )
                }
            } else {
                gesture.state = .cancelled
            }
            
        case .changed:
            guard horizontalEnough && signOK else { return }
            updateGestureProgress(tabID: tabID, translation: translation.x, isLeftEdge: isLeftEdge)
            
        case .ended:
            let progress = min(1.0, absX / width)
            let shouldComplete = progress > 0.3 || abs(velocity.x) > 800
            if shouldComplete {
                completeGestureTransition(tabID: tabID)
            } else {
                cancelGestureTransition(tabID: tabID)
            }
            
        case .cancelled, .failed:
            cancelGestureTransition(tabID: tabID)
            
        default:
            break
        }
    }
    
    // MARK: - 🛡️ **안전한 스냅샷 캡처 (제스처용)**
    
    private func captureSafeCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        // 🛡️ **메인 스레드에서만 실행**
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.captureSafeCurrentSnapshot(webView: webView, completion: completion)
            }
            return
        }
        
        // 🛡️ **웹뷰 상태 검증**
        guard validateWebViewForSnapshot(webView) else {
            dbg("❌ 제스처용 스냅샷 - 웹뷰 상태 불량")
            completion(nil)
            return
        }
        
        let captureConfig = WKSnapshotConfiguration()
        captureConfig.rect = webView.bounds
        captureConfig.afterScreenUpdates = true  // 렌더링 업데이트 후 캡처
        
        webView.takeSnapshot(with: captureConfig) { image, error in
            if let error = error {
                self.dbg("📸 제스처 스냅샷 실패: \(error.localizedDescription)")
                // Fallback: 메인 스레드에서 layer 렌더링
                let fallbackImage = self.renderWebViewToImage(webView)
                completion(fallbackImage)
            } else {
                completion(image)
            }
        }
    }
    
    // MARK: - 🎯 **나머지 제스처/전환 로직** (기존 유지 + 캡처 개선)
    
    private func beginGestureTransitionWithSnapshot(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection, currentSnapshot: UIImage?) {
        let initialTransform = webView.transform
        
        let previewContainer = createPreviewContainer(
            webView: webView,
            direction: direction,
            stateModel: stateModel,
            currentSnapshot: currentSnapshot
        )
        
        let context = TransitionContext(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            isGesture: true,
            direction: direction,
            initialTransform: initialTransform,
            previewContainer: previewContainer,
            currentSnapshot: currentSnapshot
        )
        activeTransitions[tabID] = context
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentWebView = previewContainer.viewWithTag(1001)
        let targetPreview = previewContainer.viewWithTag(1002)
        
        if isLeftEdge {
            let moveDistance = max(0, min(screenWidth, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = -screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (moveDistance / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        } else {
            let moveDistance = max(-screenWidth, min(0, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (abs(moveDistance) / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        }
    }
    
    private func createPreviewContainer(webView: WKWebView, direction: NavigationDirection, stateModel: WebViewStateModel, currentSnapshot: UIImage? = nil) -> UIView {
        let container = UIView(frame: webView.bounds)
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        
        // 현재 웹뷰 스냅샷 사용
        let currentView: UIView
        if let snapshot = currentSnapshot {
            let imageView = UIImageView(image: snapshot)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            currentView = imageView
        } else {
            if let fallbackImage = renderWebViewToImage(webView) {
                let imageView = UIImageView(image: fallbackImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                currentView = imageView
            } else {
                currentView = UIView(frame: webView.bounds)
                currentView.backgroundColor = .systemBackground
            }
        }
        
        currentView.frame = webView.bounds
        currentView.tag = 1001
        
        // 그림자 설정
        currentView.layer.shadowColor = UIColor.black.cgColor
        currentView.layer.shadowOpacity = 0.3
        currentView.layer.shadowOffset = CGSize(width: direction == .back ? -5 : 5, height: 0)
        currentView.layer.shadowRadius = 10
        
        container.addSubview(currentView)
        
        // 타겟 페이지 미리보기
        let targetIndex = direction == .back ?
            stateModel.dataModel.currentPageIndex - 1 :
            stateModel.dataModel.currentPageIndex + 1
        
        var targetView: UIView
        
        if targetIndex >= 0, targetIndex < stateModel.dataModel.pageHistory.count {
            let targetRecord = stateModel.dataModel.pageHistory[targetIndex]
            
            if let snapshot = retrieveSnapshot(for: targetRecord.id),
               let targetImage = snapshot.loadImage() {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
                dbg("📸 타겟 페이지 BFCache 스냅샷 사용: \(targetRecord.title)")
            } else {
                targetView = createInfoCard(for: targetRecord, in: webView.bounds)
                dbg("ℹ️ 타겟 페이지 정보 카드 생성: \(targetRecord.title)")
            }
        } else {
            targetView = UIView()
            targetView.backgroundColor = .systemBackground
        }
        
        targetView.frame = webView.bounds
        targetView.tag = 1002
        
        if direction == .back {
            targetView.frame.origin.x = -webView.bounds.width
        } else {
            targetView.frame.origin.x = webView.bounds.width
        }
        
        container.insertSubview(targetView, at: 0)
        webView.addSubview(container)
        return container
    }
    
    private func createInfoCard(for record: PageRecord, in bounds: CGRect) -> UIView {
        let card = UIView(frame: bounds)
        card.backgroundColor = .systemBackground
        
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 12
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.1
        contentView.layer.shadowOffset = CGSize(width: 0, height: 2)
        contentView.layer.shadowRadius = 8
        card.addSubview(contentView)
        
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "globe")
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        contentView.addSubview(iconView)
        
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = record.title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)
        
        let urlLabel = UILabel()
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.text = record.url.host ?? record.url.absoluteString
        urlLabel.font = .systemFont(ofSize: 14)
        urlLabel.textColor = .secondaryLabel
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 1
        contentView.addSubview(urlLabel)
        
        let timeLabel = UILabel()
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        timeLabel.text = formatter.string(from: record.lastAccessed)
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.textAlignment = .center
        contentView.addSubview(timeLabel)
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 180),
            
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            timeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            timeLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
        
        return card
    }
    
    // 🎬 **핵심 개선: 미리보기 컨테이너 타이밍 수정 - 적응형 타이밍 적용**
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                if context.direction == .back {
                    currentView?.frame.origin.x = screenWidth
                    targetView?.frame.origin.x = 0
                } else {
                    currentView?.frame.origin.x = -screenWidth
                    targetView?.frame.origin.x = 0
                }
                currentView?.layer.shadowOpacity = 0
            },
            completion: { [weak self] _ in
                // 🎬 **적응형 타이밍으로 네비게이션 수행**
                self?.performNavigationWithAdaptiveTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🔄 **적응형 타이밍을 적용한 네비게이션 수행**
    private func performNavigationWithAdaptiveTiming(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            // 실패 시 즉시 정리
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 로딩 시간 측정 시작
        let navigationStartTime = Date()
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // 🔄 **적응형 BFCache 복원 + 타이밍 학습**
        tryAdaptiveBFCacheRestore(stateModel: stateModel, direction: context.direction, navigationStartTime: navigationStartTime) { [weak self] success in
            // BFCache 복원 완료 또는 실패 시 즉시 정리 (깜빡임 최소화)
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - BFCache \(success ? "성공" : "실패")")
            }
        }
        
        // 🛡️ **안전장치: 최대 1초 후 강제 정리** (적응형 타이밍으로 조금 더 여유)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (1초 타임아웃)")
            }
        }
    }
    
    // 🔄 **적응형 BFCache 복원 + 타이밍 학습** 
    private func tryAdaptiveBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, navigationStartTime: Date, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // 사이트별 프로파일 조회/생성
        var siteProfile = getSiteProfile(for: currentRecord.url) ?? SiteTimingProfile(hostname: currentRecord.url.host ?? "unknown")
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 적응형 복원
            snapshot.restore(to: webView, siteProfile: siteProfile) { [weak self] success in
                // 로딩 시간 기록
                let loadingDuration = Date().timeIntervalSince(navigationStartTime)
                siteProfile.recordLoadingTime(loadingDuration)
                siteProfile.recordRestoreAttempt(success: success)
                self?.updateSiteProfile(siteProfile)
                
                if success {
                    self?.dbg("✅ 적응형 BFCache 복원 성공: \(currentRecord.title) (소요: \(String(format: "%.2f", loadingDuration))초)")
                } else {
                    self?.dbg("⚠️ 적응형 BFCache 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 기본 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            let loadingDuration = Date().timeIntervalSince(navigationStartTime)
            siteProfile.recordLoadingTime(loadingDuration)
            siteProfile.recordRestoreAttempt(success: false)
            updateSiteProfile(siteProfile)
            
            // 기본 대기 시간 적용
            let waitTime = siteProfile.getAdaptiveWaitTime(step: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                completion(false)
            }
        }
    }

    private func cancelGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.25,
            animations: {
                currentView?.frame.origin.x = 0
                
                if context.direction == .back {
                    targetView?.frame.origin.x = -screenWidth
                } else {
                    targetView?.frame.origin.x = screenWidth
                }
                
                currentView?.layer.shadowOpacity = 0.3
            },
            completion: { _ in
                previewContainer.removeFromSuperview()
                self.activeTransitions.removeValue(forKey: tabID)
            }
        )
    }
    
    // MARK: - 버튼 네비게이션 (즉시 전환)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🆕 **개선된 떠나는 페이지 캡처 (최고 우선순위, 안정화 대기)**
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .leaving, tabID: tabID, waitForStabilization: true)
        }
        
        stateModel.goBack()
        tryAdaptiveBFCacheRestore(stateModel: stateModel, direction: .back, navigationStartTime: Date()) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🆕 **개선된 떠나는 페이지 캡처 (최고 우선순위, 안정화 대기)**
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .leaving, tabID: tabID, waitForStabilization: true)
        }
        
        stateModel.goForward()
        tryAdaptiveBFCacheRestore(stateModel: stateModel, direction: .forward, navigationStartTime: Date()) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    // MARK: - 스와이프 제스처 감지 처리 (DataModel에서 이관)
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        // 복원 중이면 무시
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        // 절대 원칙: 히스토리에서 찾더라도 무조건 새 페이지로 추가
        // 세션 점프 완전 방지
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가 (과거 점프 방지): \(url.absoluteString)")
    }
    
    // MARK: - 🌐 JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔄 BFCache 페이지 복원');
                
                // 동적 콘텐츠 새로고침 (필요시)
                if (window.location.pathname.includes('/feed') ||
                    window.location.pathname.includes('/timeline') ||
                    window.location.hostname.includes('twitter') ||
                    window.location.hostname.includes('facebook')) {
                    if (window.refreshDynamicContent) {
                        window.refreshDynamicContent();
                    }
                }
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 BFCache 페이지 저장');
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[BFCache] \(msg)")
    }
}

// MARK: - UIGestureRecognizerDelegate
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - CustomWebView 통합 인터페이스
extension BFCacheTransitionSystem {
    
    // CustomWebView의 makeUIView에서 호출
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        // BFCache 스크립트 설치
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        
        // 제스처 설치
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ 강화된 BFCache 시스템 설치 완료")
    }
    
    // CustomWebView의 dismantleUIView에서 호출
    static func uninstall(from webView: WKWebView) {
        // 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        TabPersistenceManager.debugMessages.append("🧹 BFCache 시스템 제거 완료")
    }
    
    // 버튼 네비게이션 래퍼
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
}

// MARK: - 🆕 **대폭 개선된 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출**
extension BFCacheTransitionSystem {

    /// 🆕 **사용자가 링크/폼으로 떠나기 직전 현재 페이지를 저장 (안정화 대기)**
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 🆕 **안정화 대기 후 캡처 (최고 우선순위)**
        captureSnapshot(pageRecord: rec, webView: webView, type: .leaving, tabID: tabID, waitForStabilization: true)
        dbg("📸 떠나기 스냅샷 캡처 시작 (안정화 대기): \(rec.title)")
    }

    /// 🆕 **페이지 로드 완료 후 자동 캐시 강화 (렌더링 완료 대기)**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 🆕 **도착 후 안정화 대기 캡처 (백그라운드 우선순위, 안정화 대기)**
        captureSnapshot(pageRecord: rec, webView: webView, type: .arrival, tabID: tabID, waitForStabilization: true)
        dbg("📸 도착 스냅샷 캡처 시작 (안정화 대기): \(rec.title)")
        
        // 이전 페이지들도 순차적으로 캐시 확인 및 캡처 (기존 로직 유지)
        if stateModel.dataModel.currentPageIndex > 0 {
            // 최근 3개 페이지만 체크 (성능 고려)
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                // 캐시가 없는 경우만 메타데이터 저장
                if !hasCache(for: previousRecord.id) {
                    // 메타데이터만 저장 (이미지는 없음)
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollPosition: .zero,
                        timestamp: Date(),
                        captureStatus: .failed,
                        version: 1
                    )
                    
                    // 디스크에 메타데이터만 저장
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
    
    /// 🆕 **SPA 완료 후 안정화된 캡처**
    func storeSPACompletedSnapshot(webView: WKWebView, stateModel: WebViewStateModel, record: PageRecord) {
        guard let tabID = stateModel.tabID else { return }
        
        // SPA 완료 후에는 반드시 안정화 대기
        captureSnapshot(pageRecord: record, webView: webView, type: .arrival, tabID: tabID, waitForStabilization: true)
        dbg("📸 SPA 완료 후 안정화된 스냅샷 캡처: \(record.title)")
    }
}
