//
//  BFCacheSnapshotManager.swift
//  📱 **localStorage 기반 스크롤 복원 시스템**
//  💾 **핵심**: scrollTop + 페이지 인덱스 + 로드된 데이터 구간을 localStorage에 저장
//  🚀 **단순화**: 복원 시 데이터 로드 → scrollTo 한 번에 처리
//  ⚡ **성능**: 렌더링 대기 없이 즉시 복원
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용
//  🎯 **브라우저 자동 스크롤 차단**: history.scrollRestoration = 'manual' 적용
//  ⏱️ **렌더링 대기 강화**: 동적 콘텐츠 로딩을 위한 충분한 대기 시간 확보

import UIKit
import WebKit
import SwiftUI

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 📸 **localStorage 기반 BFCache 스냅샷**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    let localStorageKey: String  // 💾 localStorage 키
    var scrollState: ScrollState  // 📍 스크롤 상태
    var dataState: DataState?  // 📊 데이터 상태
    var webViewSnapshotPath: String?  // 🖼️ 비주얼 스냅샷
    let timestamp: Date
    let version: Int
    
    // 📍 스크롤 상태
    struct ScrollState: Codable {
        let scrollTop: CGFloat
        let scrollLeft: CGFloat
        let contentHeight: CGFloat
        let contentWidth: CGFloat
        let viewportHeight: CGFloat
        let viewportWidth: CGFloat
        let scrollPercent: CGPoint  // 백분율
    }
    
    // 📊 데이터 상태
    struct DataState: Codable {
        let pageIndex: Int  // 현재 페이지 인덱스
        let loadedDataRange: DataRange  // 로드된 데이터 구간
        let totalItems: Int  // 전체 아이템 수
        let visibleItemIndices: [Int]  // 현재 보이는 아이템 인덱스들
        let anchorItemId: String?  // 앵커 아이템 ID
        let customData: [String: String]?  // 커스텀 데이터
    }
    
    // 📊 데이터 구간
    struct DataRange: Codable {
        let start: Int
        let end: Int
        let hasMore: Bool
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // MARK: - 🎯 **핵심: localStorage 기반 복원 (브라우저 자동 스크롤 차단)**
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("💾 localStorage 기반 복원 시작 (브라우저 자동 스크롤 차단)")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📍 목표 스크롤: Y=\(String(format: "%.1f", scrollState.scrollTop))px")
        
        if let dataState = dataState {
            TabPersistenceManager.debugMessages.append("📊 데이터 상태: 페이지=\(dataState.pageIndex), 범위=\(dataState.loadedDataRange.start)-\(dataState.loadedDataRange.end)")
        }
        
        // localStorage 키 생성
        let storageKey = localStorageKey
        
        // JavaScript로 복원 실행
        let js = generateLocalStorageRestoreScript(storageKey: storageKey)
        
        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("❌ localStorage 복원 실패: \(error.localizedDescription)")
                completion(false)
            } else if let resultDict = result as? [String: Any] {
                let success = (resultDict["success"] as? Bool) ?? false
                
                if let restoredData = resultDict["restoredData"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("✅ 복원된 데이터: \(restoredData.keys)")
                }
                
                if let finalScroll = resultDict["finalScroll"] as? [String: Any] {
                    let scrollTop = (finalScroll["scrollTop"] as? Double) ?? 0
                    TabPersistenceManager.debugMessages.append("📍 최종 스크롤 위치: Y=\(String(format: "%.1f", scrollTop))px")
                }
                
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
                
                TabPersistenceManager.debugMessages.append("💾 localStorage 복원 완료: \(success ? "성공" : "실패")")
                completion(success)
            } else {
                completion(false)
            }
        }
    }
    
    // MARK: - JavaScript 생성 메서드
    
    private func generateLocalStorageRestoreScript(storageKey: String) -> String {
        // 스크롤 상태 JSON
        let scrollStateJSON = """
        {
            "scrollTop": \(scrollState.scrollTop),
            "scrollLeft": \(scrollState.scrollLeft),
            "contentHeight": \(scrollState.contentHeight),
            "contentWidth": \(scrollState.contentWidth),
            "viewportHeight": \(scrollState.viewportHeight),
            "viewportWidth": \(scrollState.viewportWidth)
        }
        """
        
        // 데이터 상태 JSON
        var dataStateJSON = "null"
        if let dataState = dataState {
            dataStateJSON = """
            {
                "pageIndex": \(dataState.pageIndex),
                "loadedDataRange": {
                    "start": \(dataState.loadedDataRange.start),
                    "end": \(dataState.loadedDataRange.end),
                    "hasMore": \(dataState.loadedDataRange.hasMore ? "true" : "false")
                },
                "totalItems": \(dataState.totalItems),
                "visibleItemIndices": \(dataState.visibleItemIndices),
                "anchorItemId": \(dataState.anchorItemId != nil ? "\"\(dataState.anchorItemId!)\"" : "null")
            }
            """
        }
        
        return """
        (function() {
            try {
                const logs = [];
                const storageKey = '\(storageKey)';
                
                logs.push('💾 localStorage 복원 시작: ' + storageKey);
                
                // 🎯 **브라우저 자동 스크롤 비활성화**
                if ('scrollRestoration' in history) {
                    history.scrollRestoration = 'manual';
                    logs.push('🎯 브라우저 자동 스크롤 비활성화됨');
                }
                
                // 1. localStorage에서 데이터 읽기
                const storedDataStr = localStorage.getItem(storageKey);
                let storedData = null;
                
                if (storedDataStr) {
                    try {
                        storedData = JSON.parse(storedDataStr);
                        logs.push('✅ localStorage 데이터 로드 성공');
                    } catch(e) {
                        logs.push('❌ localStorage 파싱 실패: ' + e.message);
                    }
                }
                
                // 2. 저장된 데이터가 없으면 새로 저장
                if (!storedData) {
                    const scrollState = \(scrollStateJSON);
                    const dataState = \(dataStateJSON);
                    
                    storedData = {
                        scrollState: scrollState,
                        dataState: dataState,
                        timestamp: Date.now(),
                        url: window.location.href
                    };
                    
                    localStorage.setItem(storageKey, JSON.stringify(storedData));
                    logs.push('💾 새 데이터 저장 완료');
                }
                
                // 3. ⏱️ **초기 렌더링 대기 (200ms) - 동적 콘텐츠 로딩 대기**
                logs.push('⏱️ 초기 렌더링 대기 시작 (200ms)');
                
                setTimeout(function() {
                    logs.push('⏱️ 초기 대기 완료 - 스크롤 복원 시작');
                    
                    if (storedData.scrollState) {
                        const scrollState = storedData.scrollState;
                        
                        // 모든 스크롤 가능 요소에 즉시 적용
                        window.scrollTo({
                            top: scrollState.scrollTop,
                            left: scrollState.scrollLeft,
                            behavior: 'instant'  // 애니메이션 없이 즉시 이동
                        });
                        
                        // 여러 경로로 확실하게 스크롤 적용
                        document.documentElement.scrollTop = scrollState.scrollTop;
                        document.documentElement.scrollLeft = scrollState.scrollLeft;
                        document.body.scrollTop = scrollState.scrollTop;
                        document.body.scrollLeft = scrollState.scrollLeft;
                        
                        // scrollTo 다시 한번 호출 (브라우저 호환성)
                        window.scrollTo(scrollState.scrollLeft, scrollState.scrollTop);
                        
                        logs.push('📍 스크롤 복원 적용: X=' + scrollState.scrollLeft + ', Y=' + scrollState.scrollTop);
                        
                        // 스크롤 이벤트 강제 발생
                        window.dispatchEvent(new Event('scroll', { bubbles: true, cancelable: false }));
                        
                        // 🎯 **다단계 requestAnimationFrame 체인 (렌더링 사이클 5번 대기)**
                        let frameCount = 0;
                        const maxFrames = 5;
                        
                        function applyScrollInFrame() {
                            frameCount++;
                            
                            window.scrollTo(scrollState.scrollLeft, scrollState.scrollTop);
                            document.documentElement.scrollTop = scrollState.scrollTop;
                            document.body.scrollTop = scrollState.scrollTop;
                            
                            logs.push('🎯 렌더링 프레임 ' + frameCount + '/' + maxFrames + ' 적용');
                            
                            if (frameCount < maxFrames) {
                                window.requestAnimationFrame(applyScrollInFrame);
                            } else {
                                logs.push('✅ 모든 렌더링 프레임 적용 완료');
                                
                                // ⏱️ **추가 안정화 대기 (300ms)**
                                setTimeout(function() {
                                    // 최종 검증 및 보정
                                    if (window.scrollY !== scrollState.scrollTop) {
                                        window.scrollTo(0, scrollState.scrollTop);
                                        document.documentElement.scrollTop = scrollState.scrollTop;
                                        document.body.scrollTop = scrollState.scrollTop;
                                        logs.push('🔧 최종 보정 적용');
                                    }
                                    logs.push('✅ 안정화 완료');
                                }, 300);
                            }
                        }
                        
                        // 첫 번째 프레임 시작
                        window.requestAnimationFrame(applyScrollInFrame);
                    }
                    
                    // 4. 데이터 상태 복원 (있는 경우) - 스크롤 복원 후 실행
                    if (storedData.dataState) {
                        const dataState = storedData.dataState;
                        logs.push('📊 데이터 상태 복원: 페이지=' + dataState.pageIndex + ', 범위=' + dataState.loadedDataRange.start + '-' + dataState.loadedDataRange.end);
                        
                        // ⏱️ **데이터 로드 대기 (500ms 후 시작)**
                        setTimeout(function() {
                            // 애플리케이션별 데이터 로드 트리거
                            // React/Vue 앱의 경우 상태 복원
                            if (window.__REACT_APP_STATE__) {
                                window.__REACT_APP_STATE__.loadDataRange(dataState.loadedDataRange);
                                logs.push('React 앱 데이터 로드 트리거');
                            } else if (window.__VUE_APP__) {
                                window.__VUE_APP__.$store.dispatch('loadDataRange', dataState.loadedDataRange);
                                logs.push('Vue 앱 데이터 로드 트리거');
                            } else {
                                // 일반적인 무한 스크롤 복원
                                const loadMoreButtons = document.querySelectorAll('[data-load-more], .load-more, button[class*="more"]');
                                const targetClicks = Math.min(dataState.pageIndex, loadMoreButtons.length);
                                
                                for (let i = 0; i < targetClicks; i++) {
                                    if (loadMoreButtons[i]) {
                                        // 각 버튼 클릭을 100ms 간격으로 지연
                                        setTimeout(function(index) {
                                            if (loadMoreButtons[index]) {
                                                loadMoreButtons[index].click();
                                                logs.push('더보기 버튼 클릭: ' + (index + 1));
                                            }
                                        }.bind(null, i), i * 100);
                                    }
                                }
                            }
                            
                            // 커스텀 이벤트 발생
                            window.dispatchEvent(new CustomEvent('bfcache-restore-data', {
                                detail: dataState
                            }));
                            
                            // 앵커 아이템으로 추가 보정 (데이터 로드 후 1초 대기)
                            if (dataState.anchorItemId) {
                                setTimeout(function() {
                                    const anchorElement = document.getElementById(dataState.anchorItemId) ||
                                                        document.querySelector('[data-item-id="' + dataState.anchorItemId + '"]');
                                    
                                    if (anchorElement) {
                                        anchorElement.scrollIntoView({ behavior: 'instant', block: 'center' });
                                        logs.push('⚓ 앵커 아이템으로 보정: ' + dataState.anchorItemId);
                                    }
                                }, 1000);
                            }
                        }, 500);
                    }
                }, 200);  // 초기 200ms 대기
                
                // 5. 🎯 **최종 확인 (2초 후) - 모든 동적 콘텐츠 로딩 완료 대기**
                setTimeout(function() {
                    const finalScrollTop = window.scrollY || window.pageYOffset || 0;
                    const finalScrollLeft = window.scrollX || window.pageXOffset || 0;
                    
                    // 목표 위치와 다르면 강제 재적용
                    if (storedData.scrollState && Math.abs(finalScrollTop - storedData.scrollState.scrollTop) > 1) {
                        window.scrollTo(storedData.scrollState.scrollLeft, storedData.scrollState.scrollTop);
                        document.documentElement.scrollTop = storedData.scrollState.scrollTop;
                        document.body.scrollTop = storedData.scrollState.scrollTop;
                        logs.push('🔧 2초 후 최종 보정: ' + storedData.scrollState.scrollTop);
                    }
                    
                    logs.push('✅ 모든 복원 완료 - 최종 위치: X=' + finalScrollLeft + ', Y=' + finalScrollTop);
                }, 2000);  // 2초 후 최종 확인
                
                // 6. 즉시 반환용 스크롤 위치 (초기 대기 전)
                const immediateScrollTop = window.scrollY || window.pageYOffset || 0;
                const immediateScrollLeft = window.scrollX || window.pageXOffset || 0;
                
                return {
                    success: true,
                    restoredData: storedData,
                    finalScroll: {
                        scrollTop: immediateScrollTop,
                        scrollLeft: immediateScrollLeft
                    },
                    logs: logs
                };
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message,
                    logs: ['localStorage 복원 실패: ' + e.message]
                };
            }
        })()
        """
    }
}

// MARK: - BFCacheTransitionSystem 캐처/복원 확장
extension BFCacheTransitionSystem {
    
    // MARK: - 📸 캡처 작업
    
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
        
        TabPersistenceManager.debugMessages.append("💾 localStorage 기반 캡처 시작: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 직렬화 큐로 캡처 작업 순서 보장
        serialQueue.async { [weak self] in
            self?.performLocalStorageCapture(task)
        }
    }
    
    private func performLocalStorageCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        guard let webView = task.webView else {
            TabPersistenceManager.debugMessages.append("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // localStorage 키 생성 (페이지별 고유 키)
        let storageKey = "bfcache_\(pageID.uuidString)"
        
        TabPersistenceManager.debugMessages.append("💾 localStorage 캡처: 키=\(storageKey)")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                contentSize: webView.scrollView.contentSize,
                viewportSize: webView.bounds.size,
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else { return }
        
        // localStorage 캡처 실행
        let captureResult = performLocalStorageDataCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            storageKey: storageKey
        )
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ localStorage 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize
        let viewportSize: CGSize
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 💾 localStorage 데이터 캡처
    private func performLocalStorageDataCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, storageKey: String) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        var visualSnapshot: UIImage? = nil
        var dataState: BFCacheSnapshot.DataState? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 캡처
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
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 성공")
                }
                semaphore.signal()
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 3.0)
        
        // 2. localStorage에 데이터 저장 및 상태 캡처
        let jsSemaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.sync {
            let jsScript = generateLocalStorageCaptureScript(storageKey: storageKey)
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("❌ localStorage 저장 실패: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    // 데이터 상태 파싱
                    if let capturedDataState = data["dataState"] as? [String: Any] {
                        let pageIndex = (capturedDataState["pageIndex"] as? Int) ?? 0
                        let totalItems = (capturedDataState["totalItems"] as? Int) ?? 0
                        let visibleIndices = (capturedDataState["visibleItemIndices"] as? [Int]) ?? []
                        let anchorId = capturedDataState["anchorItemId"] as? String
                        
                        var dataRange = BFCacheSnapshot.DataRange(start: 0, end: 0, hasMore: false)
                        if let range = capturedDataState["loadedDataRange"] as? [String: Any] {
                            dataRange = BFCacheSnapshot.DataRange(
                                start: (range["start"] as? Int) ?? 0,
                                end: (range["end"] as? Int) ?? 0,
                                hasMore: (range["hasMore"] as? Bool) ?? false
                            )
                        }
                        
                        dataState = BFCacheSnapshot.DataState(
                            pageIndex: pageIndex,
                            loadedDataRange: dataRange,
                            totalItems: totalItems,
                            visibleItemIndices: visibleIndices,
                            anchorItemId: anchorId,
                            customData: nil
                        )
                        
                        TabPersistenceManager.debugMessages.append("📊 데이터 상태 캡처: 페이지=\(pageIndex), 아이템=\(totalItems), 범위=\(dataRange.start)-\(dataRange.end)")
                    }
                    
                    if let success = data["success"] as? Bool, success {
                        TabPersistenceManager.debugMessages.append("✅ localStorage 저장 성공")
                    }
                }
                jsSemaphore.signal()
            }
        }
        
        _ = jsSemaphore.wait(timeout: .now() + 2.0)
        
        // 스크롤 백분율 계산
        let scrollPercent: CGPoint
        if captureData.contentSize.height > captureData.viewportSize.height || captureData.contentSize.width > captureData.viewportSize.width {
            let maxScrollX = max(0, captureData.contentSize.width - captureData.viewportSize.width)
            let maxScrollY = max(0, captureData.contentSize.height - captureData.viewportSize.height)
            
            scrollPercent = CGPoint(
                x: maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        // 스크롤 상태 생성
        let scrollState = BFCacheSnapshot.ScrollState(
            scrollTop: captureData.scrollPosition.y,
            scrollLeft: captureData.scrollPosition.x,
            contentHeight: captureData.contentSize.height,
            contentWidth: captureData.contentSize.width,
            viewportHeight: captureData.viewportSize.height,
            viewportWidth: captureData.viewportSize.width,
            scrollPercent: scrollPercent
        )
        
        // 버전 증가
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            localStorageKey: storageKey,
            scrollState: scrollState,
            dataState: dataState,
            webViewSnapshotPath: nil,
            timestamp: Date(),
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // localStorage 캡처 JavaScript
    private func generateLocalStorageCaptureScript(storageKey: String) -> String {
        return """
        (function() {
            try {
                const storageKey = '\(storageKey)';
                
                // 🎯 **브라우저 자동 스크롤 비활성화**
                if ('scrollRestoration' in history) {
                    history.scrollRestoration = 'manual';
                    console.log('🎯 캡처 시 브라우저 자동 스크롤 비활성화');
                }
                
                // 스크롤 상태 수집
                const scrollState = {
                    scrollTop: window.scrollY || window.pageYOffset || 0,
                    scrollLeft: window.scrollX || window.pageXOffset || 0,
                    contentHeight: document.documentElement.scrollHeight || 0,
                    contentWidth: document.documentElement.scrollWidth || 0,
                    viewportHeight: window.innerHeight || 0,
                    viewportWidth: window.innerWidth || 0
                };
                
                // 데이터 상태 수집
                const dataState = {};
                
                // 페이지 인덱스 계산 (무한 스크롤)
                const loadMoreButtons = document.querySelectorAll('[data-load-more], .load-more, button[class*="more"]');
                const loadedPages = document.querySelectorAll('[data-page], .page, [class*="page-"]');
                dataState.pageIndex = Math.max(loadMoreButtons.length, loadedPages.length, 1);
                
                // 로드된 데이터 범위 계산
                const items = document.querySelectorAll('li, .item, .list-item, [data-item-id]');
                dataState.totalItems = items.length;
                
                // 보이는 아이템 인덱스 수집
                const visibleIndices = [];
                const viewportTop = scrollState.scrollTop;
                const viewportBottom = viewportTop + scrollState.viewportHeight;
                
                items.forEach(function(item, index) {
                    const rect = item.getBoundingClientRect();
                    const itemTop = scrollState.scrollTop + rect.top;
                    const itemBottom = itemTop + rect.height;
                    
                    if (itemBottom > viewportTop && itemTop < viewportBottom) {
                        visibleIndices.push(index);
                    }
                });
                
                dataState.visibleItemIndices = visibleIndices;
                
                // 데이터 범위 설정
                dataState.loadedDataRange = {
                    start: visibleIndices.length > 0 ? Math.min(...visibleIndices) : 0,
                    end: visibleIndices.length > 0 ? Math.max(...visibleIndices) : items.length - 1,
                    hasMore: loadMoreButtons.length > 0
                };
                
                // 앵커 아이템 선택 (가장 중앙에 있는 아이템)
                if (visibleIndices.length > 0) {
                    const centerIndex = visibleIndices[Math.floor(visibleIndices.length / 2)];
                    const centerItem = items[centerIndex];
                    if (centerItem) {
                        dataState.anchorItemId = centerItem.id || centerItem.getAttribute('data-item-id') || 'item-' + centerIndex;
                    }
                }
                
                // localStorage에 저장
                const storeData = {
                    scrollState: scrollState,
                    dataState: dataState,
                    timestamp: Date.now(),
                    url: window.location.href,
                    title: document.title
                };
                
                localStorage.setItem(storageKey, JSON.stringify(storeData));
                
                console.log('💾 localStorage 저장:', storageKey, storeData);
                
                return {
                    success: true,
                    scrollState: scrollState,
                    dataState: dataState,
                    storageKey: storageKey
                };
                
            } catch(e) {
                console.error('localStorage 캡처 실패:', e);
                return {
                    success: false,
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
    
    // MARK: - 🌐 JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        // 🎯 **페이지 로드 시 즉시 브라우저 자동 스크롤 비활성화**
        (function() {
            if ('scrollRestoration' in history) {
                history.scrollRestoration = 'manual';
                console.log('🎯 페이지 로드 - 브라우저 자동 스크롤 비활성화');
            }
        })();
        
        // localStorage 기반 BFCache 이벤트 리스너
        window.addEventListener('pageshow', function(event) {
            // 🎯 **pageshow에서도 자동 스크롤 비활성화 재확인**
            if ('scrollRestoration' in history) {
                history.scrollRestoration = 'manual';
            }
            
            if (event.persisted) {
                console.log('💾 localStorage BFCache 페이지 복원');
                
                // 자동 복원 시도 (렌더링 대기 강화)
                const keys = Object.keys(localStorage).filter(key => key.startsWith('bfcache_'));
                if (keys.length > 0) {
                    const latestKey = keys.sort().pop();
                    const data = localStorage.getItem(latestKey);
                    if (data) {
                        try {
                            const parsed = JSON.parse(data);
                            if (parsed.scrollState) {
                                // ⏱️ 200ms 초기 대기 후 복원 시작
                                setTimeout(function() {
                                    // 먼저 리셋
                                    window.scrollTo(0, 0);
                                    
                                    // 스크롤 복원 (애니메이션 없이)
                                    window.scrollTo({
                                        top: parsed.scrollState.scrollTop,
                                        left: parsed.scrollState.scrollLeft,
                                        behavior: 'instant'
                                    });
                                    
                                    // 여러 경로로 확실하게 적용
                                    document.documentElement.scrollTop = parsed.scrollState.scrollTop;
                                    document.body.scrollTop = parsed.scrollState.scrollTop;
                                    
                                    console.log('💾 자동 복원 성공:', parsed.scrollState);
                                    
                                    // ⏱️ 다단계 requestAnimationFrame 적용
                                    let frameCount = 0;
                                    function applyFrame() {
                                        frameCount++;
                                        window.scrollTo(parsed.scrollState.scrollLeft, parsed.scrollState.scrollTop);
                                        document.documentElement.scrollTop = parsed.scrollState.scrollTop;
                                        document.body.scrollTop = parsed.scrollState.scrollTop;
                                        
                                        if (frameCount < 5) {
                                            window.requestAnimationFrame(applyFrame);
                                        } else {
                                            // ⏱️ 추가 300ms 대기 후 최종 보정
                                            setTimeout(function() {
                                                window.scrollTo(parsed.scrollState.scrollLeft, parsed.scrollState.scrollTop);
                                                console.log('✅ pageshow 자동 복원 완료');
                                            }, 300);
                                        }
                                    }
                                    window.requestAnimationFrame(applyFrame);
                                    
                                }, 200);  // 초기 200ms 대기
                            }
                        } catch(e) {
                            console.error('자동 복원 실패:', e);
                        }
                    }
                }
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('💾 localStorage BFCache 페이지 저장');
            }
        });
        
        // 🎯 **popstate 이벤트에서도 자동 스크롤 차단**
        window.addEventListener('popstate', function(event) {
            if ('scrollRestoration' in history) {
                history.scrollRestoration = 'manual';
            }
        });
        
        // 🎯 **DOMContentLoaded에서도 확실하게 설정**
        document.addEventListener('DOMContentLoaded', function() {
            if ('scrollRestoration' in history) {
                history.scrollRestoration = 'manual';
                console.log('🎯 DOM 로드 완료 - 자동 스크롤 비활성화 확인');
            }
        });
        
        // 커스텀 이벤트 리스너 (앱 통합용)
        window.addEventListener('bfcache-restore-data', function(event) {
            console.log('📊 BFCache 데이터 복원 요청:', event.detail);
            
            // React/Vue 앱 통합 예제
            if (window.__REACT_APP_STATE__) {
                window.__REACT_APP_STATE__.restoreFromBFCache(event.detail);
            } else if (window.__VUE_APP__) {
                window.__VUE_APP__.$store.commit('RESTORE_FROM_BFCACHE', event.detail);
            }
        });
        
        // localStorage 정리 (30일 이상 오래된 데이터)
        (function cleanOldBFCacheData() {
            const now = Date.now();
            const thirtyDays = 30 * 24 * 60 * 60 * 1000;
            
            Object.keys(localStorage).forEach(function(key) {
                if (key.startsWith('bfcache_')) {
                    try {
                        const data = JSON.parse(localStorage.getItem(key));
                        if (data.timestamp && (now - data.timestamp) > thirtyDays) {
                            localStorage.removeItem(key);
                            console.log('🗑️ 오래된 BFCache 데이터 삭제:', key);
                        }
                    } catch(e) {
                        // 파싱 실패한 항목도 삭제
                        localStorage.removeItem(key);
                    }
                }
            });
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
