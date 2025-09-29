//
//  BFCacheSnapshotManager.swift
//  🎯 **통합 단일 복원 시스템**
//  📌 **영속적 앵커 조합**: ID + CSS 셀렉터 + 콘텐츠 해시
//  👀 **동적 대기**: MutationObserver + ResizeObserver 활용
//  🔄 **앵커 재시도**: 로딩 트리거 후 재탐색
//  📍 **절대좌표 풀백**: 모든 앵커 실패시 최후 수단
//  📏 **스크롤러 탐지**: 가장 긴 스크롤러 자동 선택

import UIKit
import WebKit
import SwiftUI

// MARK: - 📸 **통합 앵커 기반 BFCache 페이지 스냅샷**
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
    
    // 🎯 통합 앵커 데이터
    let unifiedAnchors: UnifiedAnchors?
    
    struct UnifiedAnchors: Codable {
        let primaryScrollerSelector: String?
        let scrollerHeight: CGFloat
        let anchors: [UnifiedAnchor]
        let captureStats: [String: Int]
    }
    
    struct UnifiedAnchor: Codable {
        let persistentId: String?
        let cssSelector: String
        let contentHash: String?
        let textPreview: String?
        let relativePosition: CGPoint
        let absolutePosition: CGPoint
        let confidence: Int
        let elementInfo: [String: String]
    }
    
    enum CaptureStatus: String, Codable {
        case complete
        case partial
        case visualOnly
        case failed
    }
    
    // 일반 초기화자
    init(pageRecord: PageRecord,
         domSnapshot: String? = nil,
         scrollPosition: CGPoint,
         scrollPositionPercent: CGPoint,
         contentSize: CGSize,
         viewportSize: CGSize,
         actualScrollableSize: CGSize,
         jsState: [String: Any]? = nil,
         timestamp: Date,
         webViewSnapshotPath: String? = nil,
         captureStatus: CaptureStatus,
         version: Int,
         unifiedAnchors: UnifiedAnchors? = nil) {
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
        self.unifiedAnchors = unifiedAnchors
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, scrollPositionPercent
        case contentSize, viewportSize, actualScrollableSize
        case jsState, timestamp, webViewSnapshotPath
        case captureStatus, version, unifiedAnchors
    }
    
    // Custom decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        scrollPositionPercent = try container.decodeIfPresent(CGPoint.self, forKey: .scrollPositionPercent) ?? CGPoint.zero
        contentSize = try container.decodeIfPresent(CGSize.self, forKey: .contentSize) ?? CGSize.zero
        viewportSize = try container.decodeIfPresent(CGSize.self, forKey: .viewportSize) ?? CGSize.zero
        actualScrollableSize = try container.decodeIfPresent(CGSize.self, forKey: .actualScrollableSize) ?? CGSize.zero
        unifiedAnchors = try container.decodeIfPresent(UnifiedAnchors.self, forKey: .unifiedAnchors)
        
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
    }
    
    // Custom encoding
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        try container.encode(scrollPositionPercent, forKey: .scrollPositionPercent)
        try container.encode(contentSize, forKey: .contentSize)
        try container.encode(viewportSize, forKey: .viewportSize)
        try container.encode(actualScrollableSize, forKey: .actualScrollableSize)
        try container.encodeIfPresent(unifiedAnchors, forKey: .unifiedAnchors)
        
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // MARK: - 🎯 **핵심: 통합 단일 복원 시스템**
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 통합 앵커 복원 시작: \(pageRecord.url.host ?? "unknown")")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: Y=\(String(format: "%.1f", scrollPosition.y))px (\(String(format: "%.1f", scrollPositionPercent.y))%)")
        
        guard let anchors = unifiedAnchors else {
            TabPersistenceManager.debugMessages.append("❌ 앵커 데이터 없음 - 절대좌표 풀백")
            restoreWithAbsolutePosition(webView: webView, completion: completion)
            return
        }
        
        TabPersistenceManager.debugMessages.append("📌 앵커 수: \(anchors.anchors.count)개, 스크롤러: \(anchors.primaryScrollerSelector ?? "document")")
        
        // 통합 복원 스크립트 실행
        let js = generateUnifiedRestorationScript(anchors: anchors)
        
        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("❌ 복원 스크립트 오류: \(error.localizedDescription)")
                self.restoreWithAbsolutePosition(webView: webView, completion: completion)
                return
            }
            
            guard let resultDict = result as? [String: Any] else {
                TabPersistenceManager.debugMessages.append("❌ 결과 파싱 실패")
                self.restoreWithAbsolutePosition(webView: webView, completion: completion)
                return
            }
            
            // 결과 분석
            let success = (resultDict["success"] as? Bool) ?? false
            
            if let phase = resultDict["phase"] as? String {
                TabPersistenceManager.debugMessages.append("🔄 복원 단계: \(phase)")
            }
            
            if let matchedAnchor = resultDict["matchedAnchor"] as? [String: Any] {
                if let selector = matchedAnchor["selector"] as? String {
                    TabPersistenceManager.debugMessages.append("✅ 매칭된 앵커: \(selector)")
                }
                if let confidence = matchedAnchor["confidence"] as? Int {
                    TabPersistenceManager.debugMessages.append("📊 신뢰도: \(confidence)%")
                }
            }
            
            if let finalPosition = resultDict["finalPosition"] as? [String: Double] {
                TabPersistenceManager.debugMessages.append("📍 최종 위치: Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
            }
            
            if let difference = resultDict["difference"] as? [String: Double] {
                TabPersistenceManager.debugMessages.append("📏 목표 차이: Y=\(String(format: "%.1f", difference["y"] ?? 0))px")
            }
            
            if let logs = resultDict["logs"] as? [String] {
                for log in logs.prefix(20) {
                    TabPersistenceManager.debugMessages.append("  JS: \(log)")
                }
            }
            
            TabPersistenceManager.debugMessages.append("🎯 복원 \(success ? "성공" : "실패")")
            completion(success)
        }
    }
    
    // 절대좌표 풀백
    private func restoreWithAbsolutePosition(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("📍 절대좌표 풀백 사용")
        
        let js = """
        (function() {
            const scroller = document.scrollingElement || document.documentElement;
            const targetX = \(scrollPosition.x);
            const targetY = \(scrollPosition.y);
            
            scroller.scrollLeft = targetX;
            scroller.scrollTop = targetY;
            
            return {
                success: true,
                phase: 'absolute_fallback',
                finalPosition: { x: scroller.scrollLeft, y: scroller.scrollTop },
                difference: {
                    x: Math.abs(scroller.scrollLeft - targetX),
                    y: Math.abs(scroller.scrollTop - targetY)
                }
            };
        })()
        """
        
        webView.evaluateJavaScript(js) { _, _ in
            completion(false) // 풀백이므로 부분 성공
        }
    }
    
    // MARK: - 🎯 통합 복원 JavaScript 생성
    
    private func generateUnifiedRestorationScript(anchors: UnifiedAnchors) -> String {
        // 앵커 데이터를 JSON으로 변환
        let anchorsJSON: String
        if let data = try? JSONEncoder().encode(anchors.anchors),
           let jsonString = String(data: data, encoding: .utf8) {
            anchorsJSON = jsonString
        } else {
            anchorsJSON = "[]"
        }
        
        let targetY = scrollPosition.y
        let percentY = scrollPositionPercent.y
        let primaryScroller = anchors.primaryScrollerSelector ?? "document.scrollingElement || document.documentElement"
        
        return """
        (function() {
            const logs = [];
            const startTime = Date.now();
            
            try {
                logs.push('🎯 통합 앵커 복원 시작');
                
                // 스크롤러 탐지
                function findBestScroller() {
                    const selector = '\(primaryScroller)';
                    if (selector === 'document.scrollingElement || document.documentElement') {
                        return document.scrollingElement || document.documentElement;
                    }
                    
                    const element = document.querySelector(selector);
                    if (element && element.scrollHeight > element.clientHeight) {
                        logs.push('커스텀 스크롤러 사용: ' + selector);
                        return element;
                    }
                    
                    // 폴백: 가장 긴 스크롤러 찾기
                    const scrollables = Array.from(document.querySelectorAll('*')).filter(el => {
                        const style = getComputedStyle(el);
                        return (style.overflow === 'auto' || style.overflow === 'scroll' ||
                                style.overflowY === 'auto' || style.overflowY === 'scroll') &&
                               el.scrollHeight > el.clientHeight;
                    });
                    
                    if (scrollables.length > 0) {
                        scrollables.sort((a, b) => b.scrollHeight - a.scrollHeight);
                        logs.push('가장 긴 스크롤러 자동 선택: ' + scrollables[0].tagName);
                        return scrollables[0];
                    }
                    
                    return document.scrollingElement || document.documentElement;
                }
                
                const scroller = findBestScroller();
                const targetY = \(targetY);
                const percentY = \(percentY);
                const anchors = \(anchorsJSON);
                
                logs.push('목표: Y=' + targetY.toFixed(1) + 'px (' + percentY.toFixed(1) + '%)');
                logs.push('앵커 수: ' + anchors.length);
                
                // DOM 렌더링 완료 대기
                function waitForDOM() {
                    return new Promise((resolve) => {
                        if (document.readyState === 'complete') {
                            logs.push('DOM 이미 완료');
                            resolve();
                            return;
                        }
                        
                        let observer = null;
                        let resizeObserver = null;
                        let timeoutId = null;
                        let changeCount = 0;
                        let lastHeight = scroller.scrollHeight;
                        
                        function checkStability() {
                            const currentHeight = scroller.scrollHeight;
                            if (Math.abs(currentHeight - lastHeight) < 10) {
                                changeCount++;
                                if (changeCount >= 3) {
                                    logs.push('DOM 안정화 확인 (높이: ' + currentHeight + 'px)');
                                    cleanup();
                                    resolve();
                                }
                            } else {
                                changeCount = 0;
                                lastHeight = currentHeight;
                            }
                        }
                        
                        function cleanup() {
                            if (observer) observer.disconnect();
                            if (resizeObserver) resizeObserver.disconnect();
                            if (timeoutId) clearTimeout(timeoutId);
                        }
                        
                        // MutationObserver 설정
                        observer = new MutationObserver(() => {
                            checkStability();
                        });
                        
                        observer.observe(document.body, {
                            childList: true,
                            subtree: true,
                            attributes: false,
                            characterData: false
                        });
                        
                        // ResizeObserver 설정
                        if (window.ResizeObserver) {
                            resizeObserver = new ResizeObserver(() => {
                                checkStability();
                            });
                            resizeObserver.observe(scroller === document.documentElement ? document.body : scroller);
                        }
                        
                        // 타임아웃 설정 (최대 3초)
                        timeoutId = setTimeout(() => {
                            logs.push('DOM 대기 타임아웃');
                            cleanup();
                            resolve();
                        }, 3000);
                    });
                }
                
                // 앵커 찾기 함수
                function findAnchor(anchor) {
                    // 1. 영속적 ID로 찾기
                    if (anchor.persistentId) {
                        const elements = document.querySelectorAll(
                            '[data-id="' + anchor.persistentId + '"], ' +
                            '[data-key="' + anchor.persistentId + '"], ' +
                            '[id="' + anchor.persistentId + '"]'
                        );
                        if (elements.length > 0) {
                            return { element: elements[0], method: 'persistent_id', confidence: 95 };
                        }
                    }
                    
                    // 2. CSS 셀렉터로 찾기
                    if (anchor.cssSelector) {
                        try {
                            const elements = document.querySelectorAll(anchor.cssSelector);
                            if (elements.length === 1) {
                                return { element: elements[0], method: 'css_selector', confidence: 85 };
                            }
                            
                            // 여러 개면 콘텐츠 해시로 필터링
                            if (elements.length > 1 && anchor.contentHash) {
                                for (let el of elements) {
                                    const hash = simpleHash(el.textContent || '');
                                    if (hash === anchor.contentHash) {
                                        return { element: el, method: 'css_with_hash', confidence: 90 };
                                    }
                                }
                            }
                        } catch(e) {
                            // 셀렉터 오류 무시
                        }
                    }
                    
                    // 3. 콘텐츠 해시로 찾기
                    if (anchor.contentHash && anchor.textPreview) {
                        const searchText = anchor.textPreview.substring(0, 50);
                        const candidates = Array.from(document.querySelectorAll('*')).filter(el => {
                            const text = el.textContent || '';
                            return text.length > 20 && text.includes(searchText);
                        });
                        
                        for (let el of candidates) {
                            const hash = simpleHash(el.textContent || '');
                            if (hash === anchor.contentHash) {
                                return { element: el, method: 'content_hash', confidence: 75 };
                            }
                        }
                    }
                    
                    return null;
                }
                
                // 간단한 해시 함수
                function simpleHash(str) {
                    let hash = 0;
                    if (!str || str.length === 0) return '';
                    for (let i = 0; i < str.length; i++) {
                        const char = str.charCodeAt(i);
                        hash = ((hash << 5) - hash) + char;
                        hash = hash & hash;
                    }
                    return Math.abs(hash).toString(36);
                }
                
                // 로딩 트리거 함수
                function triggerLoading() {
                    logs.push('로딩 트리거 시도');
                    
                    // 스크롤 이벤트 발생
                    scroller.scrollTop = scroller.scrollHeight;
                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                    
                    // IntersectionObserver 트리거
                    const bottomElement = document.elementFromPoint(
                        window.innerWidth / 2,
                        window.innerHeight - 10
                    );
                    if (bottomElement) {
                        bottomElement.scrollIntoView({ block: 'end' });
                    }
                    
                    // 더보기 버튼 클릭
                    const loadMoreButtons = document.querySelectorAll(
                        'button[class*="more"], [class*="load"], .load-more'
                    );
                    loadMoreButtons.forEach(btn => {
                        if (btn && typeof btn.click === 'function') {
                            btn.click();
                        }
                    });
                    
                    return new Promise(resolve => {
                        setTimeout(resolve, 500); // 로딩 대기
                    });
                }
                
                // 복원 실행
                async function performRestoration() {
                    await waitForDOM();
                    
                    let matchedAnchor = null;
                    let bestMatch = null;
                    let phase = 'initial';
                    
                    // 첫 번째 시도: 모든 앵커 탐색
                    for (let anchor of anchors) {
                        const result = findAnchor(anchor);
                        if (result && (!bestMatch || result.confidence > bestMatch.confidence)) {
                            bestMatch = result;
                            matchedAnchor = anchor;
                            if (result.confidence >= 90) break; // 충분히 신뢰할 수 있으면 중단
                        }
                    }
                    
                    // 앵커를 못 찾았으면 로딩 트리거 후 재시도
                    if (!bestMatch || bestMatch.confidence < 75) {
                        logs.push('앵커 신뢰도 낮음 - 로딩 트리거');
                        await triggerLoading();
                        await waitForDOM();
                        
                        phase = 'after_loading';
                        
                        // 재시도
                        for (let anchor of anchors) {
                            const result = findAnchor(anchor);
                            if (result && (!bestMatch || result.confidence > bestMatch.confidence)) {
                                bestMatch = result;
                                matchedAnchor = anchor;
                                if (result.confidence >= 90) break;
                            }
                        }
                    }
                    
                    // 앵커 기반 스크롤
                    if (bestMatch && matchedAnchor) {
                        logs.push('앵커 매칭: ' + bestMatch.method + ' (신뢰도: ' + bestMatch.confidence + '%)');
                        
                        const rect = bestMatch.element.getBoundingClientRect();
                        const elementTop = scroller.scrollTop + rect.top;
                        const targetScrollTop = elementTop - matchedAnchor.relativePosition.y;
                        
                        scroller.scrollTop = targetScrollTop;
                        
                        logs.push('앵커 기반 스크롤: ' + targetScrollTop.toFixed(1) + 'px');
                        phase = 'anchor_restored';
                    } else {
                        // 절대좌표 풀백
                        logs.push('앵커 없음 - 절대좌표 풀백');
                        
                        // 백분율 우선 시도
                        if (percentY > 0) {
                            const maxScroll = scroller.scrollHeight - scroller.clientHeight;
                            scroller.scrollTop = (percentY / 100) * maxScroll;
                        } else {
                            scroller.scrollTop = targetY;
                        }
                        
                        phase = 'absolute_fallback';
                    }
                    
                    // 최종 위치
                    const finalY = scroller.scrollTop;
                    const difference = Math.abs(finalY - targetY);
                    const success = difference < 100; // 100px 이내면 성공
                    
                    return {
                        success: success,
                        phase: phase,
                        matchedAnchor: bestMatch ? {
                            method: bestMatch.method,
                            confidence: bestMatch.confidence,
                            selector: matchedAnchor?.cssSelector
                        } : null,
                        finalPosition: { x: scroller.scrollLeft, y: finalY },
                        targetPosition: { x: 0, y: targetY },
                        difference: { x: 0, y: difference },
                        logs: logs,
                        duration: Date.now() - startTime
                    };
                }
                
                // 실행
                return performRestoration();
                
            } catch(e) {
                return {
                    success: false,
                    phase: 'error',
                    error: e.message,
                    logs: logs
                };
            }
        })()
        """
    }
}

// MARK: - BFCacheTransitionSystem 캐처/복원 확장
extension BFCacheTransitionSystem {
    
    // MARK: - 🔧 통합 캡처 작업
    
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
        
        TabPersistenceManager.debugMessages.append("📸 통합 앵커 캡처 시작: \(pageRecord.url.host ?? "unknown")")
        
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
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨")
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
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ 통합 앵커 캡처 완료: \(task.pageRecord.title)")
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
        
        // 모든 시도 실패
        return (BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: nil,
            scrollPosition: captureData.scrollPosition,
            scrollPositionPercent: CGPoint.zero,
            contentSize: captureData.contentSize,
            viewportSize: captureData.viewportSize,
            actualScrollableSize: captureData.actualScrollableSize,
            jsState: nil,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: .failed,
            version: 1,
            unifiedAnchors: nil
        ), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var unifiedAnchors: BFCacheSnapshot.UnifiedAnchors? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 실패: \(error.localizedDescription)")
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            TabPersistenceManager.debugMessages.append("⏰ 스냅샷 타임아웃")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처
        let domSemaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 활성 상태 제거
                    document.querySelectorAll('[class*="active"], [class*="pressed"]').forEach(el => {
                        const classes = Array.from(el.classList).filter(c => 
                            !c.includes('active') && !c.includes('pressed')
                        );
                        el.className = classes.join(' ');
                    });
                    
                    const html = document.documentElement.outerHTML;
                    return html.length > 500000 ? html.substring(0, 500000) : html;
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                if let dom = result as? String {
                    domSnapshot = dom
                    TabPersistenceManager.debugMessages.append("🌐 DOM 캡처: \(dom.count)문자")
                }
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 1.0)
        
        // 3. 통합 앵커 캡처
        let anchorSemaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.sync {
            let anchorScript = generateUnifiedAnchorCaptureScript()
            
            webView.evaluateJavaScript(anchorScript) { result, error in
                if let data = result as? [String: Any] {
                    unifiedAnchors = self.parseUnifiedAnchors(from: data)
                    TabPersistenceManager.debugMessages.append("📌 앵커 캡처: \(unifiedAnchors?.anchors.count ?? 0)개")
                }
                anchorSemaphore.signal()
            }
        }
        _ = anchorSemaphore.wait(timeout: .now() + 2.0)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && unifiedAnchors != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = unifiedAnchors != nil ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 버전 증가
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        // 백분율 계산
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.height > captureData.viewportSize.height {
            let maxScrollY = max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height)
            scrollPercent = CGPoint(
                x: 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            scrollPositionPercent: scrollPercent,
            contentSize: captureData.contentSize,
            viewportSize: captureData.viewportSize,
            actualScrollableSize: captureData.actualScrollableSize,
            jsState: nil,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version,
            unifiedAnchors: unifiedAnchors
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 통합 앵커 파싱
    private func parseUnifiedAnchors(from data: [String: Any]) -> BFCacheSnapshot.UnifiedAnchors? {
        guard let anchorsArray = data["anchors"] as? [[String: Any]] else {
            return nil
        }
        
        let anchors = anchorsArray.compactMap { dict -> BFCacheSnapshot.UnifiedAnchor? in
            guard let cssSelector = dict["cssSelector"] as? String,
                  let absolutePos = dict["absolutePosition"] as? [String: Double],
                  let relativePos = dict["relativePosition"] as? [String: Double] else {
                return nil
            }
            
            return BFCacheSnapshot.UnifiedAnchor(
                persistentId: dict["persistentId"] as? String,
                cssSelector: cssSelector,
                contentHash: dict["contentHash"] as? String,
                textPreview: dict["textPreview"] as? String,
                relativePosition: CGPoint(x: relativePos["x"] ?? 0, y: relativePos["y"] ?? 0),
                absolutePosition: CGPoint(x: absolutePos["x"] ?? 0, y: absolutePos["y"] ?? 0),
                confidence: (dict["confidence"] as? Int) ?? 0,
                elementInfo: (dict["elementInfo"] as? [String: String]) ?? [:]
            )
        }
        
        let stats = (data["stats"] as? [String: Int]) ?? [:]
        
        return BFCacheSnapshot.UnifiedAnchors(
            primaryScrollerSelector: data["primaryScroller"] as? String,
            scrollerHeight: (data["scrollerHeight"] as? Double).map { CGFloat($0) } ?? 0,
            anchors: anchors,
            captureStats: stats
        )
    }
    
    // MARK: - JavaScript 앵커 캡처 스크립트
    
    private func generateUnifiedAnchorCaptureScript() -> String {
        return """
        (function() {
            try {
                const logs = [];
                
                // 가장 긴 스크롤러 찾기
                function findLongestScroller() {
                    const candidates = [
                        document.documentElement,
                        document.body,
                        ...Array.from(document.querySelectorAll('*')).filter(el => {
                            const style = getComputedStyle(el);
                            return (style.overflow === 'auto' || style.overflow === 'scroll' ||
                                    style.overflowY === 'auto' || style.overflowY === 'scroll') &&
                                   el.scrollHeight > el.clientHeight;
                        })
                    ];
                    
                    candidates.sort((a, b) => b.scrollHeight - a.scrollHeight);
                    
                    const scroller = candidates[0] || document.documentElement;
                    const selector = scroller === document.documentElement ? null :
                                    scroller.id ? '#' + scroller.id :
                                    scroller.className ? '.' + scroller.className.split(' ')[0] :
                                    scroller.tagName.toLowerCase();
                    
                    return { element: scroller, selector: selector };
                }
                
                const scrollerInfo = findLongestScroller();
                const scroller = scrollerInfo.element;
                const scrollY = scroller.scrollTop || 0;
                const scrollHeight = scroller.scrollHeight || 0;
                const clientHeight = scroller.clientHeight || window.innerHeight;
                
                logs.push('스크롤러: ' + (scrollerInfo.selector || 'document'));
                logs.push('스크롤 위치: ' + scrollY + '/' + scrollHeight);
                
                // 보이는 영역
                const viewportTop = scrollY;
                const viewportBottom = scrollY + clientHeight;
                const viewportCenter = scrollY + (clientHeight / 2);
                
                // 요소 수집
                const visibleElements = [];
                const allElements = document.querySelectorAll(
                    'article, section, li, div[class], [data-id], [data-key], .item, .post, .card'
                );
                
                for (let element of allElements) {
                    const rect = element.getBoundingClientRect();
                    const absoluteTop = scrollY + rect.top;
                    const absoluteBottom = scrollY + rect.bottom;
                    
                    // 보이는 영역에 있는지 확인
                    if (absoluteBottom > viewportTop && absoluteTop < viewportBottom) {
                        const text = (element.textContent || '').trim();
                        if (text.length > 20) {
                            visibleElements.push({
                                element: element,
                                rect: rect,
                                absoluteTop: absoluteTop,
                                text: text,
                                distanceFromCenter: Math.abs(absoluteTop + rect.height/2 - viewportCenter)
                            });
                        }
                    }
                }
                
                // 중심에 가까운 순으로 정렬
                visibleElements.sort((a, b) => a.distanceFromCenter - b.distanceFromCenter);
                
                // 상위 30개 선택
                const selectedElements = visibleElements.slice(0, 30);
                logs.push('선택된 요소: ' + selectedElements.length);
                
                // 앵커 생성
                const anchors = [];
                const stats = {
                    total: selectedElements.length,
                    withId: 0,
                    withDataAttr: 0,
                    withHash: 0
                };
                
                function simpleHash(str) {
                    if (!str) return '';
                    let hash = 0;
                    for (let i = 0; i < Math.min(str.length, 100); i++) {
                        hash = ((hash << 5) - hash) + str.charCodeAt(i);
                        hash = hash & hash;
                    }
                    return Math.abs(hash).toString(36);
                }
                
                function getCSSPath(element) {
                    const path = [];
                    let current = element;
                    let depth = 0;
                    
                    while (current && current !== document.body && depth < 5) {
                        let selector = current.tagName.toLowerCase();
                        
                        if (current.id) {
                            selector = '#' + current.id;
                            path.unshift(selector);
                            break;
                        }
                        
                        if (current.className) {
                            const classes = current.className.trim().split(/\\s+/)
                                .filter(c => c && !c.includes('active') && !c.includes('hover'));
                            if (classes.length > 0) {
                                selector += '.' + classes[0];
                            }
                        }
                        
                        // nth-child 추가
                        if (current.parentElement) {
                            const siblings = Array.from(current.parentElement.children);
                            const sameTagSiblings = siblings.filter(s => s.tagName === current.tagName);
                            if (sameTagSiblings.length > 1) {
                                const index = sameTagSiblings.indexOf(current) + 1;
                                selector += ':nth-child(' + index + ')';
                            }
                        }
                        
                        path.unshift(selector);
                        current = current.parentElement;
                        depth++;
                    }
                    
                    return path.join(' > ');
                }
                
                for (let item of selectedElements) {
                    const element = item.element;
                    const rect = item.rect;
                    
                    // 영속적 ID 추출
                    let persistentId = null;
                    if (element.id) {
                        persistentId = element.id;
                        stats.withId++;
                    } else if (element.dataset.id) {
                        persistentId = element.dataset.id;
                        stats.withDataAttr++;
                    } else if (element.dataset.key) {
                        persistentId = element.dataset.key;
                        stats.withDataAttr++;
                    }
                    
                    // CSS 경로
                    const cssPath = getCSSPath(element);
                    
                    // 콘텐츠 해시
                    const hash = simpleHash(item.text);
                    if (hash) stats.withHash++;
                    
                    // 상대 위치 (앵커에서 스크롤 위치까지의 거리)
                    const relativeY = scrollY - item.absoluteTop;
                    
                    anchors.push({
                        persistentId: persistentId,
                        cssSelector: cssPath,
                        contentHash: hash,
                        textPreview: item.text.substring(0, 100),
                        relativePosition: { x: 0, y: relativeY },
                        absolutePosition: { x: rect.left, y: item.absoluteTop },
                        confidence: persistentId ? 95 : (hash ? 75 : 50),
                        elementInfo: {
                            tag: element.tagName,
                            classes: element.className || '',
                            width: rect.width.toString(),
                            height: rect.height.toString()
                        }
                    });
                }
                
                return {
                    anchors: anchors,
                    stats: stats,
                    primaryScroller: scrollerInfo.selector,
                    scrollerHeight: scrollHeight,
                    scrollPosition: { x: 0, y: scrollY },
                    logs: logs
                };
                
            } catch(e) {
                return {
                    error: e.message,
                    anchors: [],
                    stats: {}
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
    
    // MARK: - JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('📸 BFCache 페이지 복원');
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('💾 BFCache 페이지 저장');
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
