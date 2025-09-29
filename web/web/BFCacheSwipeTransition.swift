//
//  BFCacheSnapshotManager.swift
//  🎯 **통합 앵커 기반 BFCache 복원 시스템**
//  📦 **영속적 ID + CSS 셀렉터 + 콘텐츠 해시 조합**
//  🔄 **MutationObserver + ResizeObserver 기반 렌더링 감지**
//  ♾️ **앵커 미발견 시 로딩 트리거 및 재시도**
//  📍 **최종 풀백: 절대 좌표 복원**

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
    
    enum CaptureStatus: String, Codable {
        case complete
        case partial
        case visualOnly
        case failed
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
        
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
    }
    
    // 직접 초기화용 init
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
         version: Int = 1) {
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
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // MARK: - 🎯 **통합 복원 시스템**
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 통합 앵커 기반 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: Y=\(String(format: "%.1f", scrollPosition.y))px (\(String(format: "%.2f", scrollPositionPercent.y))%)")
        
        let js = generateIntegratedRestorationScript()
        
        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("❌ 복원 스크립트 오류: \(error.localizedDescription)")
                completion(false)
            } else if let resultDict = result as? [String: Any] {
                let success = (resultDict["success"] as? Bool) ?? false
                
                // 로그 출력
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
                
                // 통계 출력
                if let stats = resultDict["stats"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 복원 통계: \(stats)")
                }
                
                TabPersistenceManager.debugMessages.append("🎯 통합 복원 완료: \(success ? "성공" : "실패")")
                completion(success)
            } else {
                TabPersistenceManager.debugMessages.append("❌ 복원 결과 파싱 오류")
                completion(false)
            }
        }
    }
    
    // MARK: - 🎯 통합 복원 JavaScript 생성
    
    private func generateIntegratedRestorationScript() -> String {
        let targetY = scrollPosition.y
        let targetX = scrollPosition.x
        let targetPercentY = scrollPositionPercent.y
        let savedContentHeight = actualScrollableSize.height
        
        // 앵커 데이터 JSON 변환
        var anchorDataJSON = "null"
        if let jsState = self.jsState,
           let anchorData = jsState["unifiedAnchors"] as? [[String: Any]] {
            if let dataJSON = try? JSONSerialization.data(withJSONObject: anchorData),
               let jsonString = String(data: dataJSON, encoding: .utf8) {
                anchorDataJSON = jsonString
            }
        }
        
        return """
        (function() {
            'use strict';
            
            const logs = [];
            const stats = {
                renderingWaitTime: 0,
                anchorMatches: 0,
                loadingTriggered: false,
                finalMethod: 'none',
                finalDifference: 0
            };
            
            // 🎯 타겟 정보
            const targetY = \(targetY);
            const targetX = \(targetX);
            const targetPercentY = \(targetPercentY);
            const savedContentHeight = \(savedContentHeight);
            const anchorData = \(anchorDataJSON);
            
            logs.push('🎯 통합 복원 시작: Y=' + targetY.toFixed(1) + 'px (' + targetPercentY.toFixed(2) + '%)');
            
            // 🔧 유틸리티 함수들
            function getROOT() {
                return document.scrollingElement || document.documentElement;
            }
            
            function getCurrentScroll() {
                const root = getROOT();
                return {
                    x: root.scrollLeft || 0,
                    y: root.scrollTop || 0
                };
            }
            
            function getMaxScroll() {
                const root = getROOT();
                return {
                    x: Math.max(0, root.scrollWidth - window.innerWidth),
                    y: Math.max(0, root.scrollHeight - window.innerHeight)
                };
            }
            
            function scrollToPosition(x, y) {
                const root = getROOT();
                root.scrollLeft = x;
                root.scrollTop = y;
                return getCurrentScroll();
            }
            
            // 🔍 앵커 매칭 함수들
            function findElementByPersistentId(anchorInfo) {
                if (!anchorInfo || !anchorInfo.persistentId) return null;
                
                const { id, dataTestId, dataId, ariaLabel } = anchorInfo.persistentId;
                
                if (id) {
                    const element = document.getElementById(id);
                    if (element) return element;
                }
                
                if (dataTestId) {
                    const element = document.querySelector('[data-testid="' + dataTestId + '"]');
                    if (element) return element;
                }
                
                if (dataId) {
                    const element = document.querySelector('[data-id="' + dataId + '"]');
                    if (element) return element;
                }
                
                if (ariaLabel) {
                    const element = document.querySelector('[aria-label="' + ariaLabel + '"]');
                    if (element) return element;
                }
                
                return null;
            }
            
            function findElementByCssSelector(anchorInfo) {
                if (!anchorInfo || !anchorInfo.cssSelector) return null;
                
                try {
                    const element = document.querySelector(anchorInfo.cssSelector);
                    return element;
                } catch(e) {
                    return null;
                }
            }
            
            function findElementByContentHash(anchorInfo) {
                if (!anchorInfo || !anchorInfo.contentHash) return null;
                
                const searchText = anchorInfo.contentHash.text;
                if (!searchText || searchText.length < 10) return null;
                
                const allElements = document.querySelectorAll('*');
                for (let i = 0; i < allElements.length; i++) {
                    const element = allElements[i];
                    const elementText = (element.textContent || '').trim();
                    if (elementText.includes(searchText)) {
                        return element;
                    }
                }
                
                return null;
            }
            
            // 🔄 로딩 트리거 함수
            function triggerContentLoading() {
                logs.push('🔄 콘텐츠 로딩 트리거 시작');
                stats.loadingTriggered = true;
                
                const root = getROOT();
                const beforeHeight = root.scrollHeight;
                
                // 더보기 버튼 클릭
                const loadMoreButtons = document.querySelectorAll(
                    '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                    'button[class*="more"], .load-more, .show-more'
                );
                
                let clicked = 0;
                for (let i = 0; i < Math.min(3, loadMoreButtons.length); i++) {
                    const btn = loadMoreButtons[i];
                    if (btn && typeof btn.click === 'function') {
                        btn.click();
                        clicked++;
                    }
                }
                
                if (clicked > 0) {
                    logs.push('더보기 버튼 ' + clicked + '개 클릭');
                }
                
                // 무한 스크롤 트리거
                root.scrollTop = root.scrollHeight;
                window.dispatchEvent(new Event('scroll', { bubbles: true }));
                root.scrollTop = 0; // 다시 위로
                
                const afterHeight = root.scrollHeight;
                const loaded = afterHeight - beforeHeight;
                
                if (loaded > 0) {
                    logs.push('로딩됨: ' + loaded.toFixed(0) + 'px');
                    return true;
                }
                
                return false;
            }
            
            // 🎯 통합 앵커 복원 함수
            function restoreWithAnchors(anchors) {
                if (!anchors || anchors.length === 0) {
                    logs.push('앵커 데이터 없음');
                    return false;
                }
                
                logs.push('앵커 복원 시도: ' + anchors.length + '개');
                
                for (let i = 0; i < anchors.length; i++) {
                    const anchor = anchors[i];
                    let element = null;
                    let matchMethod = '';
                    
                    // 1. 영속적 ID로 찾기
                    element = findElementByPersistentId(anchor);
                    if (element) {
                        matchMethod = 'persistentId';
                    }
                    
                    // 2. CSS 셀렉터로 찾기
                    if (!element) {
                        element = findElementByCssSelector(anchor);
                        if (element) {
                            matchMethod = 'cssSelector';
                        }
                    }
                    
                    // 3. 콘텐츠 해시로 찾기
                    if (!element) {
                        element = findElementByContentHash(anchor);
                        if (element) {
                            matchMethod = 'contentHash';
                        }
                    }
                    
                    if (element) {
                        stats.anchorMatches++;
                        const rect = element.getBoundingClientRect();
                        const root = getROOT();
                        const elementY = root.scrollTop + rect.top;
                        
                        // 저장된 오프셋 적용
                        const offsetY = anchor.offsetFromViewport || 0;
                        const targetScrollY = Math.max(0, elementY - offsetY);
                        
                        scrollToPosition(targetX, targetScrollY);
                        
                        const current = getCurrentScroll();
                        const diff = Math.abs(current.y - targetY);
                        
                        logs.push('앵커 매치 [' + matchMethod + ']: 차이=' + diff.toFixed(1) + 'px');
                        
                        if (diff < 100) {
                            stats.finalMethod = 'anchor_' + matchMethod;
                            stats.finalDifference = diff;
                            return true;
                        }
                    }
                }
                
                return false;
            }
            
            // 🔄 DOM 렌더링 대기 함수
            function waitForRendering(callback) {
                const startTime = Date.now();
                let renderingComplete = false;
                let observerTimeout = null;
                
                // MutationObserver 설정
                const mutationObserver = new MutationObserver(function(mutations) {
                    // DOM 변경 감지됨
                });
                
                // ResizeObserver 설정
                const resizeObserver = new ResizeObserver(function(entries) {
                    // 크기 변경 감지됨
                });
                
                // 안정화 체크
                function checkStability() {
                    const root = getROOT();
                    const currentHeight = root.scrollHeight;
                    
                    if (observerTimeout) {
                        clearTimeout(observerTimeout);
                    }
                    
                    observerTimeout = setTimeout(function() {
                        // 200ms 동안 변화 없으면 안정화로 판단
                        renderingComplete = true;
                        cleanup();
                        const waitTime = Date.now() - startTime;
                        stats.renderingWaitTime = waitTime;
                        logs.push('렌더링 완료 감지: ' + waitTime + 'ms');
                        callback();
                    }, 200);
                }
                
                function cleanup() {
                    mutationObserver.disconnect();
                    resizeObserver.disconnect();
                    if (observerTimeout) {
                        clearTimeout(observerTimeout);
                    }
                }
                
                // 관찰 시작
                mutationObserver.observe(document.body, {
                    childList: true,
                    subtree: true,
                    attributes: false,
                    characterData: false
                });
                
                const root = getROOT();
                resizeObserver.observe(root);
                resizeObserver.observe(document.body);
                
                // 변경 감지 시작
                mutationObserver.callback = checkStability;
                resizeObserver.callback = checkStability;
                
                checkStability();
                
                // 최대 대기 시간 (2초)
                setTimeout(function() {
                    if (!renderingComplete) {
                        cleanup();
                        logs.push('렌더링 대기 타임아웃');
                        callback();
                    }
                }, 2000);
            }
            
            // 🎯 메인 복원 로직
            function performRestoration() {
                const root = getROOT();
                const currentHeight = root.scrollHeight;
                
                logs.push('현재 콘텐츠 높이: ' + currentHeight.toFixed(0) + 'px');
                logs.push('저장된 콘텐츠 높이: ' + savedContentHeight.toFixed(0) + 'px');
                
                // 1. 앵커 기반 복원 시도
                if (anchorData && anchorData.length > 0) {
                    if (restoreWithAnchors(anchorData)) {
                        logs.push('✅ 앵커 복원 성공');
                        return finishRestoration(true);
                    }
                    
                    // 2. 앵커 못 찾으면 로딩 트리거 후 재시도
                    logs.push('앵커 못 찾음 - 콘텐츠 로딩 시도');
                    if (triggerContentLoading()) {
                        // 로딩 후 렌더링 대기
                        waitForRendering(function() {
                            if (restoreWithAnchors(anchorData)) {
                                logs.push('✅ 로딩 후 앵커 복원 성공');
                                return finishRestoration(true);
                            } else {
                                logs.push('로딩 후에도 앵커 못 찾음');
                                fallbackToAbsolutePosition();
                            }
                        });
                        return; // 비동기 처리 중
                    }
                }
                
                // 3. 최종 풀백: 절대 좌표 복원
                fallbackToAbsolutePosition();
            }
            
            // 📍 절대 좌표 풀백
            function fallbackToAbsolutePosition() {
                logs.push('📍 절대 좌표 풀백 시작');
                
                const max = getMaxScroll();
                
                // 퍼센트 기반 복원 시도
                if (targetPercentY > 0) {
                    const calculatedY = (targetPercentY / 100) * max.y;
                    scrollToPosition(targetX, calculatedY);
                    
                    const current = getCurrentScroll();
                    const diff = Math.abs(current.y - targetY);
                    
                    logs.push('퍼센트 복원: Y=' + calculatedY.toFixed(1) + 'px, 차이=' + diff.toFixed(1) + 'px');
                    
                    if (diff < 50) {
                        stats.finalMethod = 'percent';
                        stats.finalDifference = diff;
                        return finishRestoration(true);
                    }
                }
                
                // 절대 좌표 복원
                scrollToPosition(targetX, targetY);
                const current = getCurrentScroll();
                const diff = Math.abs(current.y - targetY);
                
                logs.push('절대 좌표 복원: Y=' + targetY.toFixed(1) + 'px, 차이=' + diff.toFixed(1) + 'px');
                
                stats.finalMethod = 'absolute';
                stats.finalDifference = diff;
                finishRestoration(diff < 100);
            }
            
            // 완료 처리
            function finishRestoration(success) {
                const current = getCurrentScroll();
                const max = getMaxScroll();
                
                logs.push('=== 복원 완료 ===');
                logs.push('최종 위치: Y=' + current.y.toFixed(1) + 'px');
                logs.push('목표 위치: Y=' + targetY.toFixed(1) + 'px');
                logs.push('최종 차이: ' + Math.abs(current.y - targetY).toFixed(1) + 'px');
                logs.push('복원 방법: ' + stats.finalMethod);
                logs.push('성공 여부: ' + (success ? '성공' : '실패'));
                
                return {
                    success: success,
                    finalPosition: current,
                    targetPosition: { x: targetX, y: targetY },
                    difference: Math.abs(current.y - targetY),
                    method: stats.finalMethod,
                    stats: stats,
                    logs: logs
                };
            }
            
            // 실행 시작
            try {
                // DOM 렌더링 대기 후 복원 시작
                waitForRendering(function() {
                    performRestoration();
                });
                
                // 동기적 반환 (비동기 처리는 콜백으로)
                return {
                    success: false,
                    message: 'Processing...',
                    logs: logs,
                    stats: stats
                };
                
            } catch(e) {
                logs.push('❌ 오류: ' + e.message);
                return {
                    success: false,
                    error: e.message,
                    logs: logs,
                    stats: stats
                };
            }
        })()
        """
    }
}

// MARK: - BFCacheTransitionSystem 캐처/복원 확장
extension BFCacheTransitionSystem {
    
    // MARK: - 캡처 작업 구조체
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
        
        TabPersistenceManager.debugMessages.append("📸 통합 앵커 캡처 시작: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
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
        
        TabPersistenceManager.debugMessages.append("📸 원자적 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
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
        
        // 캡처된 앵커 데이터 로깅
        if let jsState = captureResult.snapshot.jsState {
            if let anchors = jsState["unifiedAnchors"] as? [[String: Any]] {
                TabPersistenceManager.debugMessages.append("📦 통합 앵커 캡처: \(anchors.count)개")
                
                var persistentCount = 0
                var cssCount = 0
                var hashCount = 0
                
                for anchor in anchors {
                    if anchor["persistentId"] != nil { persistentCount += 1 }
                    if anchor["cssSelector"] != nil { cssCount += 1 }
                    if anchor["contentHash"] != nil { hashCount += 1 }
                }
                
                TabPersistenceManager.debugMessages.append("📦 앵커 타입: ID=\(persistentCount), CSS=\(cssCount), Hash=\(hashCount)")
            }
        }
        
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ 캡처 완료: \(task.pageRecord.title)")
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
                    TabPersistenceManager.debugMessages.append("🔄 재시도 후 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            TabPersistenceManager.debugMessages.append("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1))")
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
        
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            TabPersistenceManager.debugMessages.append("⏰ 스냅샷 타임아웃")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처
        let domSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 시작")
        
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    document.querySelectorAll('[class*="active"], [class*="pressed"]').forEach(function(el) {
                        var classList = Array.from(el.classList);
                        for (var i = 0; i < classList.length; i++) {
                            if (classList[i].includes('active') || classList[i].includes('pressed')) {
                                el.classList.remove(classList[i]);
                            }
                        }
                    });
                    
                    document.querySelectorAll('input:focus, textarea:focus').forEach(function(el) {
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
        _ = domSemaphore.wait(timeout: .now() + 5.0)
        
        // 3. 통합 앵커 JS 상태 캡처
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("📦 통합 앵커 JS 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateUnifiedAnchorCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("❌ JS 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 캡처 성공")
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
        
        TabPersistenceManager.debugMessages.append("📊 캡처 완료: Y=\(String(format: "%.1f", captureData.scrollPosition.y))px (\(String(format: "%.2f", scrollPercent.y))%)")
        
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
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🎯 통합 앵커 캡처 JavaScript
    private func generateUnifiedAnchorCaptureScript() -> String {
        return """
        (function() {
            'use strict';
            
            try {
                console.log('📦 통합 앵커 캡처 시작');
                
                const ROOT = document.scrollingElement || document.documentElement;
                const scrollY = ROOT.scrollTop || 0;
                const scrollX = ROOT.scrollLeft || 0;
                const viewportHeight = window.innerHeight;
                const viewportWidth = window.innerWidth;
                
                // 앵커 수집 함수
                function collectUnifiedAnchors() {
                    const anchors = [];
                    const viewportCenterY = scrollY + (viewportHeight / 2);
                    
                    // 보이는 영역의 요소들 수집
                    const candidates = [];
                    const selectors = [
                        '[id]', '[data-testid]', '[data-id]', '[aria-label]',
                        'article', 'section', 'li', '.item', '.post', '.card',
                        'h1', 'h2', 'h3', 'h4', 'h5', 'h6'
                    ];
                    
                    for (let selector of selectors) {
                        try {
                            const elements = document.querySelectorAll(selector);
                            for (let element of elements) {
                                const rect = element.getBoundingClientRect();
                                if (rect.height > 0 && rect.width > 0) {
                                    // 뷰포트 내에 있는지 확인
                                    const inViewport = rect.bottom > 0 && rect.top < viewportHeight;
                                    if (inViewport) {
                                        candidates.push({
                                            element: element,
                                            rect: rect,
                                            distance: Math.abs((scrollY + rect.top + rect.height/2) - viewportCenterY)
                                        });
                                    }
                                }
                            }
                        } catch(e) {
                            // 선택자 오류 무시
                        }
                    }
                    
                    // 뷰포트 중심 기준으로 정렬
                    candidates.sort((a, b) => a.distance - b.distance);
                    
                    // 상위 30개만 선택
                    const selected = candidates.slice(0, 30);
                    
                    for (let item of selected) {
                        const element = item.element;
                        const rect = item.rect;
                        
                        const anchor = {
                            // 영속적 ID
                            persistentId: null,
                            // CSS 셀렉터
                            cssSelector: null,
                            // 콘텐츠 해시
                            contentHash: null,
                            // 위치 정보
                            offsetFromViewport: rect.top,
                            absoluteY: scrollY + rect.top,
                            relativePercent: ((scrollY + rect.top) / ROOT.scrollHeight) * 100
                        };
                        
                        // 영속적 ID 수집
                        if (element.id) {
                            anchor.persistentId = { id: element.id };
                        } else if (element.dataset.testid) {
                            anchor.persistentId = { dataTestId: element.dataset.testid };
                        } else if (element.dataset.id) {
                            anchor.persistentId = { dataId: element.dataset.id };
                        } else if (element.getAttribute('aria-label')) {
                            anchor.persistentId = { ariaLabel: element.getAttribute('aria-label') };
                        }
                        
                        // CSS 셀렉터 생성
                        try {
                            let selector = '';
                            let current = element;
                            let depth = 0;
                            
                            while (current && current !== document.body && depth < 3) {
                                let part = current.tagName.toLowerCase();
                                
                                if (current.id) {
                                    part = '#' + current.id;
                                    selector = part + (selector ? ' > ' + selector : '');
                                    break;
                                }
                                
                                if (current.className && typeof current.className === 'string') {
                                    const classes = current.className.trim().split(/\\s+/);
                                    if (classes.length > 0 && classes[0]) {
                                        part += '.' + classes[0];
                                    }
                                }
                                
                                // nth-child 추가
                                if (current.parentElement) {
                                    const siblings = Array.from(current.parentElement.children);
                                    const index = siblings.indexOf(current);
                                    if (index > 0) {
                                        part += ':nth-child(' + (index + 1) + ')';
                                    }
                                }
                                
                                selector = part + (selector ? ' > ' + selector : '');
                                current = current.parentElement;
                                depth++;
                            }
                            
                            if (selector) {
                                anchor.cssSelector = selector;
                            }
                        } catch(e) {
                            // 셀렉터 생성 실패 무시
                        }
                        
                        // 콘텐츠 해시
                        const text = (element.textContent || '').trim();
                        if (text.length >= 20) {
                            anchor.contentHash = {
                                text: text.substring(0, 100),
                                length: text.length
                            };
                        }
                        
                        // 유효한 앵커만 추가
                        if (anchor.persistentId || anchor.cssSelector || anchor.contentHash) {
                            anchors.push(anchor);
                        }
                    }
                    
                    return anchors;
                }
                
                const anchors = collectUnifiedAnchors();
                console.log('📦 통합 앵커 수집 완료:', anchors.length);
                
                return {
                    unifiedAnchors: anchors,
                    scroll: { x: scrollX, y: scrollY },
                    viewport: { width: viewportWidth, height: viewportHeight },
                    content: { 
                        width: ROOT.scrollWidth,
                        height: ROOT.scrollHeight
                    },
                    timestamp: Date.now(),
                    href: window.location.href,
                    title: document.title
                };
                
            } catch(e) {
                console.error('📦 앵커 캡처 실패:', e);
                return {
                    unifiedAnchors: [],
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
}
