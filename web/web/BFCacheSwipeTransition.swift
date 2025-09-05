//
//  BFCacheSwipeTransition.swift
//  🎯 **강화된 BFCache 전환 시스템**
//  ✅ 직렬화 큐로 레이스 컨디션 완전 제거
//  🔄 원자적 연산으로 데이터 일관성 보장
//  📸 실패 복구 메커니즘 추가
//  ♾️ 무제한 영구 캐싱 (탭별 관리)
//  💾 스마트 메모리 관리 
//  🔧 **StateModel과 완벽 동기화**
//  🔧 **스냅샷 미스 수정 - 자동 캐시 강화**
//  🎬 **미리보기 컨테이너 타이밍 개선** - 복원 완료 후 제거
//  ⚡ **균형 잡힌 전환 속도 최적화 - 깜빡임 방지**
//  🛡️ **빠른 연속 제스처 먹통 방지** - 전환 중 차단 + 강제 정리
//  🚫 **폼데이터/눌린상태 저장 제거** - 부작용 해결
//  🔍 **범용 스크롤 감지 강화** - iframe, 커스텀 컨테이너 지원
//  🔄 **다단계 복원 시스템** - 적응형 타이밍 학습
//  📢 **광고 보정 시스템** - 동적 광고 변화 감안한 스크롤 위치 보정
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

// MARK: - 📢 **광고 보정 시스템**
struct AdCompensationData: Codable {
    let adElements: [AdElementInfo]
    let contentMarkers: [ContentMarker]
    let pageHeight: CGFloat
    let viewportHeight: CGFloat
    let captureTime: Date
    
    struct AdElementInfo: Codable {
        let selector: String
        let rect: CGRect
        let isVisible: Bool
        let adType: String // "banner", "inline", "sticky", "popup"
    }
    
    struct ContentMarker: Codable {
        let selector: String
        let offsetFromTop: CGFloat
        let text: String // 텍스트 일부로 식별
        let elementType: String
    }
}

// MARK: - 📸 BFCache 페이지 스냅샷 (광고 보정 데이터 추가)
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 📢 **광고 보정 데이터 추가**
    var adCompensation: AdCompensationData?
    
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
        case jsState
        case timestamp
        case webViewSnapshotPath
        case captureStatus
        case version
        case adCompensation
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
        adCompensation = try container.decodeIfPresent(AdCompensationData.self, forKey: .adCompensation)
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
        try container.encodeIfPresent(adCompensation, forKey: .adCompensation)
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1, adCompensation: AdCompensationData? = nil) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.adCompensation = adCompensation
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // ⚡ **다단계 복원 메서드 - 광고 보정 적용**
    func restore(to webView: WKWebView, siteProfile: SiteTimingProfile?, completion: @escaping (Bool) -> Void) {
        // 캡처 상태에 따른 복원 전략
        switch captureStatus {
        case .failed:
            completion(false)
            return
            
        case .visualOnly:
            // 📢 **광고 보정된 스크롤 복원**
            DispatchQueue.main.async {
                let compensatedPosition = self.calculateCompensatedScrollPosition(webView: webView)
                webView.scrollView.setContentOffset(compensatedPosition, animated: false)
                TabPersistenceManager.debugMessages.append("📢 광고 보정된 스크롤 즉시 복원")
                completion(true)
            }
            return
            
        case .partial, .complete:
            break
        }
        
        TabPersistenceManager.debugMessages.append("📢 광고 보정 적용된 다단계 복원 시작")
        
        // 적응형 타이밍으로 다단계 복원 실행
        DispatchQueue.main.async {
            self.performMultiStepRestoreWithAdCompensation(to: webView, siteProfile: siteProfile, completion: completion)
        }
    }
    
    // 📢 **광고 보정된 스크롤 위치 계산**
    private func calculateCompensatedScrollPosition(webView: WKWebView) -> CGPoint {
        // 기본 위치에서 시작
        var compensatedY = scrollPosition.y
        
        // 광고 보정 데이터가 있으면 보정 적용
        if let adData = adCompensation {
            let currentPageHeight = webView.scrollView.contentSize.height
            let originalPageHeight = adData.pageHeight
            
            // 페이지 높이 변화 비율 계산
            let heightRatio = currentPageHeight / originalPageHeight
            
            if abs(heightRatio - 1.0) > 0.1 { // 10% 이상 변화시 보정
                TabPersistenceManager.debugMessages.append("📢 페이지 높이 변화 감지: \(String(format: "%.1f", originalPageHeight)) → \(String(format: "%.1f", currentPageHeight)) (비율: \(String(format: "%.2f", heightRatio)))")
                
                // 콘텐츠 마커 기반 보정
                compensatedY = calculateContentBasedPosition(
                    webView: webView,
                    originalY: scrollPosition.y,
                    adData: adData,
                    heightRatio: heightRatio
                )
            }
            
            // 광고 영역 높이 변화 보정
            compensatedY = compensateForAdHeightChanges(
                webView: webView,
                originalY: compensatedY,
                adData: adData
            )
        }
        
        // 경계값 검증
        let maxY = max(0, webView.scrollView.contentSize.height - webView.scrollView.bounds.height)
        compensatedY = max(0, min(compensatedY, maxY))
        
        return CGPoint(x: scrollPosition.x, y: compensatedY)
    }
    
    // 📢 **콘텐츠 마커 기반 위치 계산**
    private func calculateContentBasedPosition(webView: WKWebView, originalY: CGFloat, adData: AdCompensationData, heightRatio: CGFloat) -> CGFloat {
        // JavaScript로 콘텐츠 마커 위치 확인
        let semaphore = DispatchSemaphore(value: 0)
        var compensatedY = originalY
        
        let markerCheckScript = generateContentMarkerScript(adData.contentMarkers)
        
        webView.evaluateJavaScript(markerCheckScript) { result, error in
            defer { semaphore.signal() }
            
            if let markerPositions = result as? [[String: Any]] {
                // 원래 스크롤 위치 주변의 마커 찾기
                compensatedY = self.findBestMarkerMatch(
                    originalY: originalY,
                    originalMarkers: adData.contentMarkers,
                    currentMarkers: markerPositions
                )
                TabPersistenceManager.debugMessages.append("📢 콘텐츠 마커 기반 보정: \(String(format: "%.1f", originalY)) → \(String(format: "%.1f", compensatedY))")
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 1.0)
        return compensatedY
    }
    
    // 📢 **광고 높이 변화 보정**
    private func compensateForAdHeightChanges(webView: WKWebView, originalY: CGFloat, adData: AdCompensationData) -> CGFloat {
        let semaphore = DispatchSemaphore(value: 0)
        var compensatedY = originalY
        
        let adCheckScript = generateAdCompensationScript(adData.adElements)
        
        webView.evaluateJavaScript(adCheckScript) { result, error in
            defer { semaphore.signal() }
            
            if let adChanges = result as? [String: Any],
               let heightDiff = adChanges["totalHeightDiff"] as? Double {
                
                // 광고 영역이 스크롤 위치보다 위에 있으면 보정 적용
                if let aboveScrollAds = adChanges["adsAboveScroll"] as? Double {
                    compensatedY += CGFloat(aboveScrollAds)
                    TabPersistenceManager.debugMessages.append("📢 광고 높이 변화 보정: +\(String(format: "%.1f", aboveScrollAds))px")
                }
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 0.8)
        return compensatedY
    }
    
    // 📢 **마커 매칭 로직**
    private func findBestMarkerMatch(originalY: CGFloat, originalMarkers: [AdCompensationData.ContentMarker], currentMarkers: [[String: Any]]) -> CGFloat {
        var bestMatch: CGFloat = originalY
        var bestScore: Double = 0
        
        for originalMarker in originalMarkers {
            for currentMarker in currentMarkers {
                if let selector = currentMarker["selector"] as? String,
                   let currentOffset = currentMarker["offsetFromTop"] as? Double,
                   let text = currentMarker["text"] as? String {
                    
                    // 선택자와 텍스트 매칭 점수 계산
                    let selectorMatch = selector == originalMarker.selector ? 1.0 : 0.0
                    let textMatch = text.contains(originalMarker.text) || originalMarker.text.contains(text) ? 0.8 : 0.0
                    let score = selectorMatch + textMatch
                    
                    if score > bestScore && score > 0.5 {
                        bestScore = score
                        // 마커의 위치 변화를 기반으로 스크롤 위치 조정
                        let markerDiff = CGFloat(currentOffset) - originalMarker.offsetFromTop
                        bestMatch = originalY + markerDiff
                    }
                }
            }
        }
        
        return bestMatch
    }
    
    // 🔄 **핵심: 광고 보정 적용된 다단계 복원 시스템**
    private func performMultiStepRestoreWithAdCompensation(to webView: WKWebView, siteProfile: SiteTimingProfile?, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        // 사이트별 적응형 타이밍 계산
        let profile = siteProfile ?? SiteTimingProfile(hostname: "default")
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        // **1단계: 광고 보정된 메인 스크롤 복원 (즉시)**
        restoreSteps.append((1, { stepCompletion in
            let compensatedPos = self.calculateCompensatedScrollPosition(webView: webView)
            TabPersistenceManager.debugMessages.append("📢 1단계: 광고 보정된 메인 스크롤 복원")
            
            // 네이티브 스크롤뷰 즉시 설정
            webView.scrollView.setContentOffset(compensatedPos, animated: false)
            
            // JavaScript 메인 스크롤 복원
            let mainScrollJS = """
            (function() {
                try {
                    window.scrollTo(\(compensatedPos.x), \(compensatedPos.y));
                    document.documentElement.scrollTop = \(compensatedPos.y);
                    document.body.scrollTop = \(compensatedPos.y);
                    return true;
                } catch(e) { return false; }
            })()
            """
            
            webView.evaluateJavaScript(mainScrollJS) { result, _ in
                let success = (result as? Bool) ?? false
                TabPersistenceManager.debugMessages.append("📢 1단계 완료: \(success ? "성공" : "실패")")
                stepCompletion(success)
            }
        }))
        
        // **2단계: 주요 컨테이너 스크롤 복원 (적응형 대기)**
        if let jsState = self.jsState,
           let scrollData = jsState["scroll"] as? [String: Any],
           let elements = scrollData["elements"] as? [[String: Any]], !elements.isEmpty {
            
            restoreSteps.append((2, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 1)
                TabPersistenceManager.debugMessages.append("📢 2단계: 컨테이너 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let containerScrollJS = self.generateContainerScrollScript(elements)
                    webView.evaluateJavaScript(containerScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("📢 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **3단계: iframe 스크롤 복원 (더 긴 대기)**
        if let jsState = self.jsState,
           let iframeData = jsState["iframes"] as? [[String: Any]], !iframeData.isEmpty {
            
            restoreSteps.append((3, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 2)
                TabPersistenceManager.debugMessages.append("📢 3단계: iframe 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let iframeScrollJS = self.generateIframeScrollScript(iframeData)
                    webView.evaluateJavaScript(iframeScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("📢 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **4단계: 광고 영역 안정화 대기 및 최종 보정**
        restoreSteps.append((4, { stepCompletion in
            let waitTime = profile.getAdaptiveWaitTime(step: 3) + 0.2 // 광고 로딩 추가 대기
            TabPersistenceManager.debugMessages.append("📢 4단계: 광고 안정화 및 최종 보정 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                // 최종 광고 보정 적용
                let finalCompensatedPos = self.calculateCompensatedScrollPosition(webView: webView)
                
                let finalVerifyJS = """
                (function() {
                    try {
                        // 광고 영역 안정화 확인
                        const adElements = document.querySelectorAll('[class*="ad"], [id*="ad"], [data-ad], .advertisement, .sponsored');
                        let stableAds = 0;
                        adElements.forEach(ad => {
                            if (ad.offsetHeight > 0 && ad.offsetWidth > 0) {
                                stableAds++;
                            }
                        });
                        
                        // 최종 보정된 위치로 스크롤
                        if (Math.abs(window.scrollY - \(finalCompensatedPos.y)) > 15) {
                            window.scrollTo(\(finalCompensatedPos.x), \(finalCompensatedPos.y));
                        }
                        
                        console.log('📢 광고 안정화:', stableAds, '개 광고 감지');
                        return window.scrollY >= \(finalCompensatedPos.y - 25);
                    } catch(e) { return false; }
                })()
                """
                
                webView.evaluateJavaScript(finalVerifyJS) { result, _ in
                    let success = (result as? Bool) ?? false
                    TabPersistenceManager.debugMessages.append("📢 4단계 완료: \(success ? "성공" : "실패")")
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
                
                TabPersistenceManager.debugMessages.append("📢 광고 보정 다단계 복원 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                completion(overallSuccess)
            }
        }
        
        executeNextStep()
    }
    
    // 📢 **콘텐츠 마커 확인 스크립트 생성**
    private func generateContentMarkerScript(_ markers: [AdCompensationData.ContentMarker]) -> String {
        let markersJSON = convertToJSONString(markers.map { [
            "selector": $0.selector,
            "text": $0.text,
            "elementType": $0.elementType
        ] }) ?? "[]"
        
        return """
        (function() {
            try {
                const markers = \(markersJSON);
                const results = [];
                
                for (const marker of markers) {
                    const elements = document.querySelectorAll(marker.selector);
                    for (const el of elements) {
                        if (el.textContent && el.textContent.includes(marker.text)) {
                            const rect = el.getBoundingClientRect();
                            results.push({
                                selector: marker.selector,
                                offsetFromTop: window.scrollY + rect.top,
                                text: el.textContent.substring(0, 100),
                                elementType: el.tagName.toLowerCase()
                            });
                            break; // 첫 번째 매칭만
                        }
                    }
                }
                
                return results;
            } catch(e) {
                console.error('콘텐츠 마커 확인 실패:', e);
                return [];
            }
        })()
        """
    }
    
    // 📢 **광고 보정 스크립트 생성**
    private func generateAdCompensationScript(_ adElements: [AdCompensationData.AdElementInfo]) -> String {
        let adElementsJSON = convertToJSONString(adElements.map { [
            "selector": $0.selector,
            "originalHeight": $0.rect.height,
            "originalTop": $0.rect.origin.y,
            "adType": $0.adType
        ] }) ?? "[]"
        
        return """
        (function() {
            try {
                const originalAds = \(adElementsJSON);
                let totalHeightDiff = 0;
                let adsAboveScroll = 0;
                const currentScrollY = window.scrollY;
                
                for (const adInfo of originalAds) {
                    const elements = document.querySelectorAll(adInfo.selector);
                    for (const ad of elements) {
                        const currentRect = ad.getBoundingClientRect();
                        const currentTop = window.scrollY + currentRect.top;
                        const heightDiff = currentRect.height - adInfo.originalHeight;
                        
                        totalHeightDiff += heightDiff;
                        
                        // 스크롤 위치보다 위에 있는 광고의 높이 변화만 누적
                        if (currentTop < currentScrollY) {
                            adsAboveScroll += heightDiff;
                        }
                        
                        console.log('📢 광고 변화:', adInfo.selector, 
                                   'Height:', adInfo.originalHeight, '→', currentRect.height,
                                   'Diff:', heightDiff);
                        break; // 첫 번째 매칭만
                    }
                }
                
                return {
                    totalHeightDiff: totalHeightDiff,
                    adsAboveScroll: adsAboveScroll
                };
            } catch(e) {
                console.error('광고 보정 확인 실패:', e);
                return { totalHeightDiff: 0, adsAboveScroll: 0 };
            }
        })()
        """
    }
    
    // 컨테이너 스크롤 복원 스크립트 생성
    private func generateContainerScrollScript(_ elements: [[String: Any]]) -> String {
        let elementsJSON = convertToJSONString(elements) ?? "[]"
        return """
        (function() {
            try {
                const elements = \(elementsJSON);
                let restored = 0;
                
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
                                if (el && typeof el.scrollTop === 'number') {
                                    el.scrollTop = item.top || 0;
                                    el.scrollLeft = item.left || 0;
                                    restored++;
                                }
                            });
                            break; // 성공하면 다음 selector 시도 안함
                        }
                    }
                }
                
                console.log('컨테이너 스크롤 복원:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('컨테이너 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // iframe 스크롤 복원 스크립트 생성
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
                
                console.log('iframe 스크롤 복원:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('iframe 스크롤 복원 실패:', e);
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

// MARK: - 🎯 **강화된 BFCache 전환 시스템**
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
    
    // MARK: - 💾 스레드 안전 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
    // 🔄 **사이트별 타이밍 프로파일**
    private var _siteTimingProfiles: [String: SiteTimingProfile] = [:]
    
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
    }
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (광고 보정 시스템 통합)**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    // 중복 방지를 위한 진행 중인 캡처 추적
    private var pendingCaptures: Set<UUID> = []
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCaptureWithAdCompensation(task)
        }
    }
    
    // 📢 **광고 보정 데이터를 포함한 원자적 캡처**
    private func performAtomicCaptureWithAdCompensation(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 중복 캡처 방지 (진행 중인 것만)
        guard !pendingCaptures.contains(pageID) else {
            dbg("⏸️ 중복 캡처 방지: \(task.pageRecord.title)")
            return
        }
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 진행 중 표시
        pendingCaptures.insert(pageID)
        dbg("📢 광고 보정 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                isLoading: webView.isLoading,
                contentSize: webView.scrollView.contentSize
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 📢 **광고 보정 데이터 수집 (지연 캡처 적용)**
        let adCompensationDelay: TimeInterval = task.type == .immediate ? 0.5 : 1.0 // 즉시 캡처는 0.5초, 백그라운드는 1초 대기
        
        DispatchQueue.main.asyncAfter(deadline: .now() + adCompensationDelay) { [weak self] in
            guard let self = self else {
                self?.pendingCaptures.remove(pageID)
                return
            }
            
            // 광고 안정화 후 캡처 수행
            let captureResult = self.performRobustCaptureWithAdData(
                pageRecord: task.pageRecord,
                webView: webView,
                captureData: data,
                retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
            )
            
            // 캡처 완료 후 저장
            if let tabID = task.tabID {
                self.saveToDisk(snapshot: captureResult, tabID: tabID)
            } else {
                self.storeInMemory(captureResult.snapshot, for: pageID)
            }
            
            // 진행 중 해제
            self.pendingCaptures.remove(pageID)
            self.dbg("📢 광고 보정 캡처 완료: \(task.pageRecord.title)")
        }
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
        let contentSize: CGSize
    }
    
    // 📢 **광고 보정 데이터를 포함한 실패 복구 캡처**
    private func performRobustCaptureWithAdData(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptCaptureWithAdCompensation(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 광고 보정 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기
            dbg("⏳ 광고 보정 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.1) // 광고 로딩 대기 시간 추가
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    // 📢 **광고 보정 데이터를 포함한 캡처 시도**
    private func attemptCaptureWithAdCompensation(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var adCompensationData: AdCompensationData? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    // Fallback: layer 렌더링
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                semaphore.signal()
            }
        }
        
        // ⚡ 적절한 타임아웃 (2초 → 2.5초로 약간 여유)
        let result = semaphore.wait(timeout: .now() + 2.5)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처 - 🚫 **눌린 상태 제거하는 스크립트 추가**
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
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
        }
        _ = domSemaphore.wait(timeout: .now() + 0.8)
        
        // 3. 📢 **광고 보정 데이터 수집**
        let adSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let adScript = generateAdCompensationCaptureScript()
            
            webView.evaluateJavaScript(adScript) { result, error in
                if let adData = result as? [String: Any] {
                    adCompensationData = self.parseAdCompensationData(adData, captureData: captureData)
                }
                adSemaphore.signal()
            }
        }
        _ = adSemaphore.wait(timeout: .now() + 1.0)
        
        // 4. 🔍 **강화된 JS 상태 캡처 - 범용 스크롤 감지**
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = generateEnhancedScrollCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 1.2)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil && adCompensationData != nil {
            captureStatus = .complete
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
            adCompensation: adCompensationData
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 📢 **광고 보정 데이터 수집 스크립트 생성**
    private func generateAdCompensationCaptureScript() -> String {
        return """
        (function() {
            try {
                const adElements = [];
                const contentMarkers = [];
                
                // 📢 **1. 광고 요소 감지 (포괄적 선택자)**
                const adSelectors = [
                    '[class*="ad"]:not([class*="add"]):not([class*="address"])',
                    '[id*="ad"]:not([id*="add"]):not([id*="address"])',
                    '[data-ad]', '[data-advertisement]', '[data-google-av-metadata]',
                    '.advertisement', '.sponsored', '.promoted', '.banner',
                    '.adsystem', '.adsbygoogle', '.ad-container', '.ad-wrapper',
                    'iframe[src*="googlesyndication"]', 'iframe[src*="doubleclick"]',
                    'ins.adsbygoogle', '[class*="dfp"]', '[id*="dfp"]'
                ];
                
                const foundAds = new Set();
                for (const selector of adSelectors) {
                    try {
                        const elements = document.querySelectorAll(selector);
                        elements.forEach(el => {
                            if (el.offsetWidth > 0 && el.offsetHeight > 0 && !foundAds.has(el)) {
                                foundAds.add(el);
                                const rect = el.getBoundingClientRect();
                                const offsetTop = window.scrollY + rect.top;
                                
                                // 광고 타입 분류
                                let adType = 'inline';
                                if (rect.width >= window.innerWidth * 0.8) adType = 'banner';
                                else if (el.style.position === 'fixed' || el.style.position === 'sticky') adType = 'sticky';
                                else if (rect.top < 0 || rect.bottom > window.innerHeight) adType = 'offscreen';
                                
                                adElements.push({
                                    selector: generateUniqueSelector(el),
                                    rect: {
                                        x: rect.left,
                                        y: offsetTop,
                                        width: rect.width,
                                        height: rect.height
                                    },
                                    isVisible: rect.top >= 0 && rect.bottom <= window.innerHeight,
                                    adType: adType
                                });
                            }
                        });
                    } catch(e) {
                        console.warn('광고 요소 감지 실패:', selector, e);
                    }
                }
                
                // 📢 **2. 콘텐츠 마커 수집 (스크롤 위치 기준점)**
                const markerSelectors = [
                    'h1', 'h2', 'h3', 'article', 'section', 'main',
                    '[role="main"]', '[role="article"]', '.content', '.post',
                    '.article-content', '.news-content', '.blog-content'
                ];
                
                for (const selector of markerSelectors) {
                    try {
                        const elements = document.querySelectorAll(selector);
                        Array.from(elements).slice(0, 10).forEach(el => { // 최대 10개만
                            if (el.textContent && el.textContent.trim().length > 20) {
                                const rect = el.getBoundingClientRect();
                                const offsetTop = window.scrollY + rect.top;
                                
                                contentMarkers.push({
                                    selector: generateUniqueSelector(el),
                                    offsetFromTop: offsetTop,
                                    text: el.textContent.trim().substring(0, 100),
                                    elementType: el.tagName.toLowerCase()
                                });
                            }
                        });
                    } catch(e) {
                        console.warn('콘텐츠 마커 수집 실패:', selector, e);
                    }
                }
                
                // 📢 **3. 고유 선택자 생성 함수**
                function generateUniqueSelector(element) {
                    if (element.id) return `#${element.id}`;
                    
                    if (element.className) {
                        const classes = element.className.trim().split(/\\s+/);
                        const uniqueClass = classes.find(cls => {
                            return document.querySelectorAll(`.${cls}`).length === 1;
                        });
                        if (uniqueClass) return `.${uniqueClass}`;
                    }
                    
                    // 부모 기준 nth-child
                    const parent = element.parentElement;
                    if (parent) {
                        const siblings = Array.from(parent.children);
                        const index = siblings.indexOf(element);
                        return `${element.tagName.toLowerCase()}:nth-child(${index + 1})`;
                    }
                    
                    return element.tagName.toLowerCase();
                }
                
                console.log(`📢 광고 보정 데이터 수집: 광고 ${adElements.length}개, 마커 ${contentMarkers.length}개`);
                
                return {
                    adElements: adElements,
                    contentMarkers: contentMarkers,
                    pageHeight: Math.max(
                        document.body.scrollHeight,
                        document.documentElement.scrollHeight
                    ),
                    viewportHeight: window.innerHeight,
                    captureTime: Date.now()
                };
            } catch(e) {
                console.error('광고 보정 데이터 수집 실패:', e);
                return null;
            }
        })()
        """
    }
    
    // 📢 **광고 보정 데이터 파싱**
    private func parseAdCompensationData(_ data: [String: Any], captureData: CaptureData) -> AdCompensationData? {
        guard let adElementsArray = data["adElements"] as? [[String: Any]],
              let contentMarkersArray = data["contentMarkers"] as? [[String: Any]],
              let pageHeight = data["pageHeight"] as? Double,
              let viewportHeight = data["viewportHeight"] as? Double else {
            return nil
        }
        
        let adElements = adElementsArray.compactMap { adData -> AdCompensationData.AdElementInfo? in
            guard let selector = adData["selector"] as? String,
                  let rectData = adData["rect"] as? [String: Any],
                  let x = rectData["x"] as? Double,
                  let y = rectData["y"] as? Double,
                  let width = rectData["width"] as? Double,
                  let height = rectData["height"] as? Double,
                  let isVisible = adData["isVisible"] as? Bool,
                  let adType = adData["adType"] as? String else {
                return nil
            }
            
            return AdCompensationData.AdElementInfo(
                selector: selector,
                rect: CGRect(x: x, y: y, width: width, height: height),
                isVisible: isVisible,
                adType: adType
            )
        }
        
        let contentMarkers = contentMarkersArray.compactMap { markerData -> AdCompensationData.ContentMarker? in
            guard let selector = markerData["selector"] as? String,
                  let offsetFromTop = markerData["offsetFromTop"] as? Double,
                  let text = markerData["text"] as? String,
                  let elementType = markerData["elementType"] as? String else {
                return nil
            }
            
            return AdCompensationData.ContentMarker(
                selector: selector,
                offsetFromTop: CGFloat(offsetFromTop),
                text: text,
                elementType: elementType
            )
        }
        
        return AdCompensationData(
            adElements: adElements,
            contentMarkers: contentMarkers,
            pageHeight: CGFloat(pageHeight),
            viewportHeight: CGFloat(viewportHeight),
            captureTime: Date()
        )
    }
    
    // 🔍 **핵심 개선: 범용 스크롤 감지 JavaScript 생성**
    private func generateEnhancedScrollCaptureScript() -> String {
        return """
        (function() {
            try {
                // 🔍 **1단계: 범용 스크롤 요소 스캔**
                function findAllScrollableElements() {
                    const scrollables = [];
                    const maxElements = 50; // 성능 고려 제한
                    
                    // 1) 명시적 overflow 스타일을 가진 요소들
                    const explicitScrollables = document.querySelectorAll('*');
                    let count = 0;
                    
                    for (const el of explicitScrollables) {
                        if (count >= maxElements) break;
                        
                        const style = window.getComputedStyle(el);
                        const overflowY = style.overflowY;
                        const overflowX = style.overflowX;
                        
                        // 스크롤 가능한 요소 판별
                        if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                            (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) {
                            
                            // 현재 스크롤 위치가 0이 아닌 경우만 저장
                            if (el.scrollTop > 0 || el.scrollLeft > 0) {
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
                                        tagName: el.tagName.toLowerCase()
                                    });
                                    count++;
                                }
                            }
                        }
                    }
                    
                    // 2) 일반적인 스크롤 컨테이너들
                    const commonScrollContainers = [
                        '.scroll-container', '.scrollable', '.content', '.main', '.body',
                        '[data-scroll]', '[data-scrollable]', '.overflow-auto', '.overflow-scroll'
                    ];
                    
                    for (const selector of commonScrollContainers) {
                        if (count >= maxElements) break;
                        
                        const elements = document.querySelectorAll(selector);
                        for (const el of elements) {
                            if (count >= maxElements) break;
                            
                            if ((el.scrollTop > 0 || el.scrollLeft > 0) && 
                                !scrollables.some(s => s.selector === generateBestSelector(el))) {
                                
                                scrollables.push({
                                    selector: generateBestSelector(el) || selector,
                                    top: el.scrollTop,
                                    left: el.scrollLeft,
                                    maxTop: el.scrollHeight - el.clientHeight,
                                    maxLeft: el.scrollWidth - el.clientWidth,
                                    id: el.id || '',
                                    className: el.className || '',
                                    tagName: el.tagName.toLowerCase()
                                });
                                count++;
                            }
                        }
                    }
                    
                    return scrollables;
                }
                
                // 🖼️ **2단계: iframe 스크롤 감지 (Same-Origin만)**
                function detectIframeScrolls() {
                    const iframes = [];
                    const iframeElements = document.querySelectorAll('iframe');
                    
                    for (const iframe of iframeElements) {
                        try {
                            // Same-origin 체크
                            const contentWindow = iframe.contentWindow;
                            if (contentWindow && contentWindow.location) {
                                const scrollX = contentWindow.scrollX || 0;
                                const scrollY = contentWindow.scrollY || 0;
                                
                                if (scrollX > 0 || scrollY > 0) {
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
                            console.log('Cross-origin iframe 스킵:', iframe.src);
                        }
                    }
                    
                    return iframes;
                }
                
                // 📏 **3단계: 동적 높이 요소 감지**
                function detectDynamicElements() {
                    const dynamics = [];
                    
                    // 일반적인 동적 콘텐츠 컨테이너들
                    const dynamicSelectors = [
                        '[data-infinite]', '[data-lazy]', '.infinite-scroll',
                        '.lazy-load', '.dynamic-content', '.feed', '.timeline',
                        '[data-scroll-container]', '.virtualized'
                    ];
                    
                    for (const selector of dynamicSelectors) {
                        const elements = document.querySelectorAll(selector);
                        for (const el of elements) {
                            if (el.scrollTop > 0 || el.scrollLeft > 0) {
                                dynamics.push({
                                    selector: generateBestSelector(el) || selector,
                                    top: el.scrollTop,
                                    left: el.scrollLeft,
                                    type: 'dynamic'
                                });
                            }
                        }
                    }
                    
                    return dynamics;
                }
                
                // 최적의 selector 생성
                function generateBestSelector(element) {
                    if (!element || element.nodeType !== 1) return null;
                    
                    // 1순위: ID가 있으면 ID 사용
                    if (element.id) {
                        return `#${element.id}`;
                    }
                    
                    // 2순위: 고유한 클래스 조합
                    if (element.className) {
                        const classes = element.className.trim().split(/\\s+/);
                        const uniqueClasses = classes.filter(cls => {
                            const elements = document.querySelectorAll(`.${cls}`);
                            return elements.length === 1 && elements[0] === element;
                        });
                        
                        if (uniqueClasses.length > 0) {
                            return `.${uniqueClasses[0]}`;
                        }
                        
                        // 클래스 조합으로 고유성 확보
                        if (classes.length > 0) {
                            const classSelector = `.${classes.join('.')}`;
                            if (document.querySelectorAll(classSelector).length === 1) {
                                return classSelector;
                            }
                        }
                    }
                    
                    // 3순위: 태그명 + 속성
                    const tag = element.tagName.toLowerCase();
                    const attributes = [];
                    
                    // data 속성 우선
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
                    
                    // 4순위: nth-child 사용
                    let parent = element.parentElement;
                    if (parent) {
                        const siblings = Array.from(parent.children);
                        const index = siblings.indexOf(element);
                        if (index !== -1) {
                            return `${parent.tagName.toLowerCase()} > ${tag}:nth-child(${index + 1})`;
                        }
                    }
                    
                    // 최후: 태그명만
                    return tag;
                }
                
                // 🔍 **메인 실행**
                const scrollableElements = findAllScrollableElements();
                const iframeScrolls = detectIframeScrolls();
                const dynamicElements = detectDynamicElements();
                
                console.log(`🔍 스크롤 요소 감지: 일반 ${scrollableElements.length}개, iframe ${iframeScrolls.length}개, 동적 ${dynamicElements.length}개`);
                
                return {
                    scroll: { 
                        x: window.scrollX, 
                        y: window.scrollY,
                        elements: scrollableElements,
                        dynamics: dynamicElements
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
                console.error('스크롤 감지 실패:', e);
                return {
                    scroll: { x: window.scrollX, y: window.scrollY, elements: [] },
                    iframes: [],
                    href: window.location.href,
                    title: document.title
                };
            }
        })()
        """
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 **개선된 디스크 저장 시스템**
    
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
                        // 저장 실패해도 계속 진행
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
                    self.dbg("❌ 상태 저장 실패: \(error.localizedDescription)")
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
                    // 버전 번호 추출하여 정렬
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
    
    // MARK: - 💾 **개선된 디스크 캐시 로딩**
    
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
    
    // MARK: - 🔄 **사이트별 타이밍 프로파일 관리**
    
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
    
    // MARK: - 🔍 **개선된 스냅샷 조회 시스템**
    
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
    
    // MARK: - 🧹 **개선된 캐시 정리**
    
    // 탭 닫을 때만 호출 (무제한 캐시 정책)
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        // 메모리에서 제거 (스레드 안전)
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
                self._cacheVersion.removeValue(forKey: pageID)
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
            
            self.dbg("⚠️ 메모리 경고 - 메모리 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🎯 **제스처 시스템 (🛡️ 연속 제스처 먹통 방지 적용)**
    
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
        
        dbg("📢 광고 보정 BFCache 제스처 설정 완료")
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
                
                // 현재 페이지 즉시 캡처 (높은 우선순위)
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                }
                
                // 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
                captureCurrentSnapshot(webView: webView) { [weak self] snapshot in
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
    
    // MARK: - 🎯 **나머지 제스처/전환 로직 (기존 유지)**
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let captureConfig = WKSnapshotConfiguration()
        captureConfig.rect = webView.bounds
        captureConfig.afterScreenUpdates = false
        
        webView.takeSnapshot(with: captureConfig) { image, error in
            if let error = error {
                self.dbg("📸 현재 페이지 스냅샷 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let fallbackImage = self.renderWebViewToImage(webView)
                    completion(fallbackImage)
                }
            } else {
                completion(image)
            }
        }
    }
    
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
        
        // 📢 **광고 보정 적용된 적응형 BFCache 복원 + 타이밍 학습**
        tryAdaptiveBFCacheRestore(stateModel: stateModel, direction: context.direction, navigationStartTime: navigationStartTime) { [weak self] success in
            // BFCache 복원 완료 또는 실패 시 즉시 정리 (깜빡임 최소화)
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("📢 미리보기 정리 완료 - 광고 보정 BFCache \(success ? "성공" : "실패")")
            }
        }
        
        // 🛡️ **안전장치: 최대 1.2초 후 강제 정리** (광고 대기 시간 고려)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (1.2초 타임아웃)")
            }
        }
    }
    
    // 📢 **광고 보정 적용된 적응형 BFCache 복원 + 타이밍 학습** 
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
            // BFCache 히트 - 광고 보정 적용된 적응형 복원
            snapshot.restore(to: webView, siteProfile: siteProfile) { [weak self] success in
                // 로딩 시간 기록
                let loadingDuration = Date().timeIntervalSince(navigationStartTime)
                siteProfile.recordLoadingTime(loadingDuration)
                siteProfile.recordRestoreAttempt(success: success)
                self?.updateSiteProfile(siteProfile)
                
                if success {
                    self?.dbg("📢 광고 보정 적응형 BFCache 복원 성공: \(currentRecord.title) (소요: \(String(format: "%.2f", loadingDuration))초)")
                } else {
                    self?.dbg("⚠️ 광고 보정 적응형 BFCache 복원 실패: \(currentRecord.title)")
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
            
            // 기본 대기 시간 적용 (광고 로딩 고려하여 조금 더 길게)
            let waitTime = siteProfile.getAdaptiveWaitTime(step: 1) + 0.3
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
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
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
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
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
                
                // 📢 **광고 영역 안정화 확인**
                setTimeout(() => {
                    const adElements = document.querySelectorAll('[class*="ad"], [id*="ad"], [data-ad], .advertisement, .sponsored');
                    let loadedAds = 0;
                    adElements.forEach(ad => {
                        if (ad.offsetHeight > 0 && ad.offsetWidth > 0) {
                            loadedAds++;
                        }
                    });
                    console.log('📢 BFCache 복원 시 광고 상태:', loadedAds, '개 로드됨');
                }, 200);
                
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
        
        // 📢 **광고 로딩 감지 시스템**
        (function() {
            const adObserver = new MutationObserver((mutations) => {
                let hasAdChanges = false;
                mutations.forEach(mutation => {
                    if (mutation.type === 'childList') {
                        const addedNodes = Array.from(mutation.addedNodes);
                        hasAdChanges = addedNodes.some(node => {
                            if (node.nodeType === 1) { // Element node
                                const el = node;
                                return el.matches && (
                                    el.matches('[class*="ad"]') ||
                                    el.matches('[id*="ad"]') ||
                                    el.matches('.advertisement') ||
                                    el.matches('.sponsored') ||
                                    el.matches('ins.adsbygoogle')
                                );
                            }
                            return false;
                        });
                    }
                });
                
                if (hasAdChanges) {
                    console.log('📢 광고 요소 변화 감지');
                    // 스크롤 위치 재조정이 필요할 수 있음을 알림
                    window.dispatchEvent(new CustomEvent('adLayoutChange', {
                        detail: { timestamp: Date.now() }
                    }));
                }
            });
            
            // 주요 광고 컨테이너 관찰
            const adContainers = document.querySelectorAll('body, main, [role="main"], .content');
            adContainers.forEach(container => {
                adObserver.observe(container, {
                    childList: true,
                    subtree: true,
                    attributes: false
                });
            });
        })();
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
        
        TabPersistenceManager.debugMessages.append("📢 광고 보정 강화된 BFCache 시스템 설치 완료")
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

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출
extension BFCacheTransitionSystem {

    /// 사용자가 링크/폼으로 **떠나기 직전** 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 즉시 캡처 (최고 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📢 떠나기 스냅샷 캡처 시작 (광고 보정): \(rec.title)")
    }

    /// 📢 **페이지 로드 완료 후 광고 안정화 대기 후 캐시 강화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 📢 **광고 안정화를 위한 지연 시간 증가 (0.3초 → 0.8초)**
        // 현재 페이지 캡처 (백그라운드 우선순위, 광고 로딩 대기)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📢 도착 스냅샷 캡처 시작 (광고 안정화 대기): \(rec.title)")
        
        // 이전 페이지들도 순차적으로 캐시 확인 및 캡처
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
                    dbg("📢 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
