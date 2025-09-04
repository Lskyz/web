//
//  BFCacheSwipeTransition.swift
//  🎯 **경량화된 동적 사이트 스크롤 복원 - React/SPA + 무한스크롤 핵심 지원**
//  ✅ 1. React/SPA 기본 감지 및 복원
//  ✅ 2. iframe 스크롤 상태 보존 (2단계까지)
//  ✅ 3. React key 기반 아이템 정확 추적
//  ✅ 4. 무한 스크롤 상태 관리
//  ✅ 5. 동적 사이트 렌더링 완료 대기 시스템
//  ✅ 6. 제스처 충돌 방지 (단순화)
//  🚫 제거: Vue/Angular, react-window, 복잡한 상태관리, 3단계+ iframe
//  ⚡ 목표: 현대 웹앱 핵심 기능만으로 안정적 복원
//

import UIKit
import WebKit
import SwiftUI
import Darwin

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

// MARK: - 📸 **경량화된 스냅샷 구조** - 핵심 기능만
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    let scrollPosition: CGPoint
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 🎯 **핵심 스크롤 상태** - React/SPA + 무한스크롤
    let scrollState: ScrollState
    
    // 🎯 **경량화된 스크롤 상태**
    struct ScrollState: Codable {
        let scrollY: CGFloat
        let viewportHeight: CGFloat
        let contentHeight: CGFloat
        
        // React/SPA 기본 정보
        let isReactApp: Bool
        let appContainerSelector: String
        
        // iframe 스크롤 상태 (2단계까지)
        let iframeStates: [IframeState]
        
        // 앵커 아이템 (정확한 위치 복원용)
        let anchorItem: AnchorItem
        
        // 무한 스크롤 상태
        let infiniteScrollInfo: InfiniteScrollInfo?
        
        // Redux 상태 (간단히)
        let reduxState: String?
        
        struct IframeState: Codable {
            let selector: String
            let scrollX: CGFloat
            let scrollY: CGFloat
            let nestedFrames: [IframeState] // 1단계 중첩만
        }
        
        struct AnchorItem: Codable {
            let selector: String
            let offsetFromTop: CGFloat
            let reactKey: String? // React 리스트 아이템 식별
        }
        
        struct InfiniteScrollInfo: Codable {
            let hasInfiniteScroll: Bool
            let currentPage: Int
            let triggerSelector: String?
            let loadedItemsCount: Int
        }
    }
    
    enum CaptureStatus: String, Codable {
        case complete, partial, visualOnly, failed
    }
    
    // MARK: - 이미지 로드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🎯 **경량화된 복원** - 핵심 기능만
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard captureStatus != .failed else {
            completion(false)
            return
        }
        
        TabPersistenceManager.debugMessages.append("🎯 경량화된 복원 시작: React=\(scrollState.isReactApp)")
        
        // iOS 웹뷰: history.scrollRestoration 강제 manual
        webView.evaluateJavaScript("if (history.scrollRestoration) { history.scrollRestoration = 'manual'; }") { _, _ in }
        
        performLightweightRestore(to: webView, completion: completion)
    }
    
    // 🎯 **경량화된 복원 로직**
    private func performLightweightRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let restoreJS = """
        (function() {
            try {
                console.log('🔄 경량화된 복원 시작');
                
                const targetY = \(scrollState.scrollY);
                const isReactApp = \(scrollState.isReactApp);
                const appContainer = '\(scrollState.appContainerSelector)';
                
                // 스크롤 위치 즉시 설정
                document.documentElement.style.scrollBehavior = 'auto';
                window.scrollTo({ top: targetY, behavior: 'auto' });
                
                // React 앱이면 앵커 기준 정밀 조정
                if (isReactApp && '\(scrollState.anchorItem.selector)' !== '') {
                    const anchorElement = document.querySelector('\(scrollState.anchorItem.selector)');
                    if (anchorElement) {
                        const reactKey = '\(scrollState.anchorItem.reactKey ?? "")';
                        
                        // React key로 정확한 아이템 찾기
                        if (reactKey && anchorElement.dataset && anchorElement.dataset.key !== reactKey) {
                            const correctAnchor = document.querySelector(`[data-key="\\${reactKey}"]`);
                            if (correctAnchor) {
                                anchorElement = correctAnchor;
                            }
                        }
                        
                        const currentTop = anchorElement.getBoundingClientRect().top;
                        const expectedTop = \(scrollState.anchorItem.offsetFromTop);
                        const adjustment = expectedTop - currentTop;
                        
                        if (Math.abs(adjustment) > 5) {
                            window.scrollTo({ top: targetY + adjustment, behavior: 'auto' });
                        }
                    }
                }
                
                // iframe 스크롤 복원 (2단계까지)
                const iframes = \(try! JSONSerialization.data(withJSONObject: scrollState.iframeStates.map { [
                    "selector": $0.selector,
                    "scrollX": $0.scrollX,
                    "scrollY": $0.scrollY,
                    "nestedFrames": $0.nestedFrames.map { nested in
                        ["selector": nested.selector, "scrollX": nested.scrollX, "scrollY": nested.scrollY]
                    }
                ] }).base64EncodedString());
                
                JSON.parse(atob('\(try! JSONSerialization.data(withJSONObject: scrollState.iframeStates.map { [
                    "selector": $0.selector,
                    "scrollX": $0.scrollX,
                    "scrollY": $0.scrollY,
                    "nestedFrames": $0.nestedFrames.map { nested in
                        ["selector": nested.selector, "scrollX": nested.scrollX, "scrollY": nested.scrollY]
                    }
                ] }).base64EncodedString())')).forEach(iframe => {
                    try {
                        const iframeEl = document.querySelector(iframe.selector);
                        if (iframeEl && iframeEl.contentWindow) {
                            iframeEl.contentWindow.scrollTo(iframe.scrollX, iframe.scrollY);
                            
                            // 중첩 iframe 처리 (1단계만)
                            iframe.nestedFrames.forEach(nested => {
                                const nestedEl = iframeEl.contentDocument.querySelector(nested.selector);
                                if (nestedEl && nestedEl.contentWindow) {
                                    nestedEl.contentWindow.scrollTo(nested.scrollX, nested.scrollY);
                                }
                            });
                        }
                    } catch (e) {
                        console.warn('iframe 복원 실패:', iframe.selector, e);
                    }
                });
                
                // Redux 상태 복원
                if (isReactApp && '\(scrollState.reduxState ?? "")' && window.__REDUX_STORE__) {
                    try {
                        const state = JSON.parse('\(scrollState.reduxState ?? "")');
                        window.__REDUX_STORE__.dispatch({ type: 'BFCACHE_RESTORE', payload: state });
                    } catch (e) {
                        console.warn('Redux 복원 실패:', e);
                    }
                }
                
                // 무한 스크롤 상태 복원
                if (\(scrollState.infiniteScrollInfo?.hasInfiniteScroll ?? false)) {
                    const triggerSelector = '\(scrollState.infiniteScrollInfo?.triggerSelector ?? "")';
                    if (triggerSelector) {
                        const trigger = document.querySelector(triggerSelector);
                        if (trigger) {
                            // Intersection Observer 비활성화 (복원 중)
                            trigger.dataset.bfcacheRestoring = 'true';
                            setTimeout(() => {
                                delete trigger.dataset.bfcacheRestoring;
                            }, 1000);
                        }
                    }
                }
                
                // 스크롤 위치 고정
                window.__BFCACHE_LOCKED__ = true;
                window.__BFCACHE_TARGET_Y__ = window.scrollY;
                
                const lockHandler = () => {
                    if (window.__BFCACHE_LOCKED__ && Math.abs(window.scrollY - window.__BFCACHE_TARGET_Y__) > 5) {
                        window.scrollTo({ top: window.__BFCACHE_TARGET_Y__, behavior: 'auto' });
                    }
                };
                window.addEventListener('scroll', lockHandler, { passive: false });
                
                // 1초 후 고정 해제
                setTimeout(() => {
                    window.__BFCACHE_LOCKED__ = false;
                    window.removeEventListener('scroll', lockHandler);
                    delete window.__BFCACHE_TARGET_Y__;
                }, 1000);
                
                return Math.abs(window.scrollY - targetY) < 10;
            } catch (e) {
                console.error('경량화된 복원 실패:', e);
                return false;
            }
        })()
        """
        
        DispatchQueue.main.async {
            // 네이티브 스크롤뷰 먼저 설정
            webView.scrollView.setContentOffset(CGPoint(x: 0, y: scrollState.scrollY), animated: false)
            
            // JavaScript 실행
            webView.evaluateJavaScript(restoreJS) { result, error in
                let success = (result as? Bool) ?? false
                if success {
                    TabPersistenceManager.debugMessages.append("✅ 경량화된 복원 성공: Y=\(self.scrollState.scrollY)")
                } else {
                    TabPersistenceManager.debugMessages.append("❌ 경량화된 복원 실패: \(error?.localizedDescription ?? "unknown")")
                }
                completion(success)
            }
        }
    }
}

// MARK: - 🎯 **경량화된 동적 사이트 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 캐시 시스템 (단순화)
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // 스레드 안전 캐시
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    
    // 🔧 **단순화된 제스처 상태** - Set 기반으로 간단하게
    private let gestureQueue = DispatchQueue(label: "bfcache.gesture")
    private var activeGestures: Set<UUID> = []
    private var gestureBlocks: [UUID: Date] = [:]
    
    // 지연 캡처 시스템
    private let delayedCaptureQueue = DispatchQueue(label: "bfcache.delayed", qos: .background)
    private var pendingCaptures: [UUID: DelayedCaptureTask] = [:]
    
    private struct DelayedCaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        weak var webView: WKWebView?
        let maxRetries: Int
        let currentRetry: Int
        let startedAt: Date
        let delaySeconds: Double
        
        func nextRetry() -> DelayedCaptureTask {
            return DelayedCaptureTask(
                pageRecord: pageRecord,
                tabID: tabID,
                webView: webView,
                maxRetries: maxRetries,
                currentRetry: currentRetry + 1,
                startedAt: startedAt,
                delaySeconds: delaySeconds * 1.5
            )
        }
    }
    
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
    
    // 🔧 **단순화된 제스처 관리**
    private func isGestureActive(for tabID: UUID) -> Bool {
        return gestureQueue.sync { activeGestures.contains(tabID) }
    }
    
    private func setGestureActive(_ active: Bool, for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            if active {
                self.activeGestures.insert(tabID)
            } else {
                self.activeGestures.remove(tabID)
            }
        }
    }
    
    private func isGestureBlocked(for tabID: UUID) -> Bool {
        return gestureQueue.sync {
            if let blockUntil = gestureBlocks[tabID] {
                return Date() < blockUntil
            }
            return false
        }
    }
    
    private func blockGestures(for tabID: UUID, duration: TimeInterval) {
        gestureQueue.async(flags: .barrier) {
            self.gestureBlocks[tabID] = Date().addingTimeInterval(duration)
        }
    }
    
    private func clearGestureBlock(for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self.gestureBlocks.removeValue(forKey: tabID)
        }
    }
    
    // MARK: - 📁 파일 시스템
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
    
    private struct TransitionContext {
        let tabID: UUID
        weak var webView: WKWebView?
        weak var stateModel: WebViewStateModel?
        var direction: NavigationDirection
        var previewContainer: UIView?
        var currentSnapshot: UIImage?
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    enum CaptureType {
        case immediate, delayed
    }
    
    // MARK: - 🎯 **경량화된 캡처 시스템**
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        if type == .delayed {
            scheduleDelayedCapture(pageRecord: pageRecord, webView: webView, tabID: tabID)
            return
        }
        
        serialQueue.async { [weak self] in
            self?.performLightweightCapture(pageRecord: pageRecord, webView: webView, tabID: tabID)
        }
    }
    
    // 🔧 **지연 캡처 스케줄링**
    private func scheduleDelayedCapture(pageRecord: PageRecord, webView: WKWebView, tabID: UUID?) {
        guard let tabID = tabID else { return }
        
        let task = DelayedCaptureTask(
            pageRecord: pageRecord,
            tabID: tabID,
            webView: webView,
            maxRetries: 3,
            currentRetry: 0,
            startedAt: Date(),
            delaySeconds: 2.0
        )
        
        pendingCaptures[pageRecord.id] = task
        
        delayedCaptureQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.executeDelayedCapture(for: pageRecord.id)
        }
        
        dbg("📅 지연 캡처 스케줄: \(pageRecord.title)")
    }
    
    // 🔧 **지연 캡처 실행**
    private func executeDelayedCapture(for pageID: UUID) {
        guard let task = pendingCaptures[pageID] else { return }
        
        // 타임아웃 체크 (30초)
        if Date().timeIntervalSince(task.startedAt) > 30 {
            pendingCaptures.removeValue(forKey: pageID)
            dbg("⏰ 지연 캡처 타임아웃: \(task.pageRecord.title)")
            return
        }
        
        guard let webView = task.webView else {
            pendingCaptures.removeValue(forKey: pageID)
            dbg("❌ 지연 캡처 실패: 웹뷰 해제")
            return
        }
        
        // 🔧 **경량화된 준비도 체크**
        checkLightweightReadiness(webView: webView) { [weak self] isReady in
            if isReady || task.currentRetry >= task.maxRetries {
                self?.pendingCaptures.removeValue(forKey: pageID)
                self?.performLightweightCapture(pageRecord: task.pageRecord, webView: webView, tabID: task.tabID)
                self?.dbg("✅ 지연 캡처 실행: \(task.pageRecord.title)")
            } else {
                // 재시도
                let nextTask = task.nextRetry()
                self?.pendingCaptures[pageID] = nextTask
                self?.delayedCaptureQueue.asyncAfter(deadline: .now() + nextTask.delaySeconds) {
                    self?.executeDelayedCapture(for: pageID)
                }
                self?.dbg("🔄 지연 캡처 재시도: \(task.pageRecord.title) [\(nextTask.currentRetry)/\(nextTask.maxRetries)]")
            }
        }
    }
    
    // 🔧 **경량화된 준비도 체크** - 핵심만
    private func checkLightweightReadiness(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let readinessJS = """
        (function() {
            try {
                // 1. 기본 DOM 준비
                if (document.readyState !== 'complete') {
                    return { ready: false, reason: 'document_loading' };
                }
                
                // 2. 최소 콘텐츠 높이
                if (document.documentElement.scrollHeight < 300) {
                    return { ready: false, reason: 'insufficient_content' };
                }
                
                // 3. 로딩 인디케이터
                if (document.querySelector('.loading, .spinner, [aria-busy="true"]')) {
                    return { ready: false, reason: 'loading_visible' };
                }
                
                // 4. React 앱 마운트 체크
                if (window.React || document.querySelector('[data-reactroot]')) {
                    const reactContainer = document.querySelector('#root, #app, [data-reactroot]');
                    if (reactContainer && reactContainer.children.length === 0) {
                        return { ready: false, reason: 'react_not_mounted' };
                    }
                }
                
                return { ready: true };
            } catch (e) {
                return { ready: false, reason: 'check_error' };
            }
        })()
        """
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(readinessJS) { result, _ in
                if let resultDict = result as? [String: Any],
                   let isReady = resultDict["ready"] as? Bool {
                    completion(isReady)
                } else {
                    completion(true) // 기본값
                }
            }
        }
    }
    
    // 🎯 **경량화된 캡처 로직**
    private func performLightweightCapture(pageRecord: PageRecord, webView: WKWebView, tabID: UUID?) {
        let pageID = pageRecord.id
        
        guard let captureData = DispatchQueue.main.sync(execute: { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else { return nil }
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                url: pageRecord.url
            )
        }) else {
            dbg("❌ 웹뷰 준비 안됨")
            return
        }
        
        // 비주얼 스냅샷
        let visualSnapshot = captureVisualSnapshot(webView: webView, bounds: captureData.bounds)
        
        // 🎯 **경량화된 상태 수집**
        let scrollState = createLightweightScrollState(webView: webView, scrollY: captureData.scrollPosition.y)
        
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && scrollState != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = .visualOnly
        } else {
            captureStatus = .failed
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            scrollPosition: captureData.scrollPosition,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: 1,
            scrollState: scrollState ?? createDefaultScrollState(scrollY: captureData.scrollPosition.y)
        )
        
        // 저장
        if let tabID = tabID {
            saveToDisk(snapshot: snapshot, image: visualSnapshot, tabID: tabID)
        } else {
            setMemoryCache(snapshot, for: pageID)
        }
        
        dbg("✅ 경량화된 캡처 완료: \(pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let url: URL
    }
    
    // 🎯 **경량화된 상태 수집 JavaScript**
    private func createLightweightScrollState(webView: WKWebView, scrollY: CGFloat) -> BFCacheSnapshot.ScrollState? {
        let stateJS = """
        (function() {
            try {
                // 기본 스크롤 정보
                const scrollInfo = {
                    scrollY: window.scrollY,
                    viewportHeight: window.innerHeight,
                    contentHeight: document.documentElement.scrollHeight
                };
                
                // React 앱 감지
                const isReactApp = !!(window.React || document.querySelector('[data-reactroot]') || window.__REACT_DEVTOOLS_GLOBAL_HOOK__);
                let appContainer = 'body';
                if (isReactApp) {
                    if (document.querySelector('#root')) appContainer = '#root';
                    else if (document.querySelector('#app')) appContainer = '#app';
                    else if (document.querySelector('[data-reactroot]')) appContainer = '[data-reactroot]';
                }
                
                // iframe 상태 (2단계까지)
                const iframes = [];
                document.querySelectorAll('iframe').forEach((iframe, idx) => {
                    try {
                        if (iframe.contentWindow && iframe.contentDocument) {
                            const state = {
                                selector: iframe.id ? '#' + iframe.id : `iframe:nth-child(\\${idx + 1})`,
                                scrollX: iframe.contentWindow.scrollX,
                                scrollY: iframe.contentWindow.scrollY,
                                nestedFrames: []
                            };
                            
                            // 1단계 중첩 iframe
                            iframe.contentDocument.querySelectorAll('iframe').forEach((nested, nestedIdx) => {
                                try {
                                    if (nested.contentWindow) {
                                        state.nestedFrames.push({
                                            selector: nested.id ? '#' + nested.id : `iframe:nth-child(\\${nestedIdx + 1})`,
                                            scrollX: nested.contentWindow.scrollX,
                                            scrollY: nested.contentWindow.scrollY
                                        });
                                    }
                                } catch (e) {}
                            });
                            
                            iframes.push(state);
                        }
                    } catch (e) {}
                });
                
                // 앵커 아이템 찾기 (가장 위쪽 가시 요소)
                let anchorItem = { selector: 'body', offsetFromTop: 0, reactKey: null };
                const visibleElements = Array.from(document.querySelectorAll('article, .item, .post, [data-key], li')).filter(el => {
                    const rect = el.getBoundingClientRect();
                    return rect.top >= 0 && rect.top <= window.innerHeight / 3 && rect.height > 20;
                });
                
                if (visibleElements.length > 0) {
                    const anchor = visibleElements[0];
                    anchorItem = {
                        selector: anchor.id ? '#' + anchor.id : anchor.tagName.toLowerCase() + ':nth-child(' + (Array.from(anchor.parentNode.children).indexOf(anchor) + 1) + ')',
                        offsetFromTop: anchor.getBoundingClientRect().top,
                        reactKey: anchor.dataset.key || anchor.getAttribute('data-reactkey') || null
                    };
                }
                
                // 무한 스크롤 감지
                let infiniteScroll = null;
                const triggers = ['.infinite-scroll', '.load-more', '[data-infinite]'].map(s => document.querySelector(s)).filter(Boolean);
                if (triggers.length > 0) {
                    const loadedItems = document.querySelectorAll('.item, .post, article, li').length;
                    infiniteScroll = {
                        hasInfiniteScroll: true,
                        currentPage: 1, // 기본값
                        triggerSelector: triggers[0].className ? '.' + triggers[0].className.split(' ')[0] : triggers[0].tagName.toLowerCase(),
                        loadedItemsCount: loadedItems
                    };
                }
                
                // Redux 상태 (간단히)
                let reduxState = null;
                if (isReactApp && window.__REDUX_STORE__) {
                    try {
                        const state = window.__REDUX_STORE__.getState();
                        reduxState = JSON.stringify(state).slice(0, 1000); // 크기 제한
                    } catch (e) {}
                }
                
                return {
                    ...scrollInfo,
                    isReactApp,
                    appContainer,
                    iframes,
                    anchorItem,
                    infiniteScroll,
                    reduxState
                };
            } catch (e) {
                console.error('상태 수집 실패:', e);
                return null;
            }
        })()
        """
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(stateJS) { jsResult, _ in
                result = jsResult as? [String: Any]
                semaphore.signal()
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 2.0)
        
        guard let data = result else { return nil }
        
        return createScrollStateFromJS(data: data, scrollY: scrollY)
    }
    
    private func createScrollStateFromJS(data: [String: Any], scrollY: CGFloat) -> BFCacheSnapshot.ScrollState {
        let isReactApp = data["isReactApp"] as? Bool ?? false
        let appContainer = data["appContainer"] as? String ?? "body"
        
        // iframe 상태 변환
        let iframeStates = (data["iframes"] as? [[String: Any]] ?? []).map { iframeData in
            let nestedFrames = (iframeData["nestedFrames"] as? [[String: Any]] ?? []).map { nested in
                BFCacheSnapshot.ScrollState.IframeState(
                    selector: nested["selector"] as? String ?? "",
                    scrollX: nested["scrollX"] as? CGFloat ?? 0,
                    scrollY: nested["scrollY"] as? CGFloat ?? 0,
                    nestedFrames: []
                )
            }
            
            return BFCacheSnapshot.ScrollState.IframeState(
                selector: iframeData["selector"] as? String ?? "",
                scrollX: iframeData["scrollX"] as? CGFloat ?? 0,
                scrollY: iframeData["scrollY"] as? CGFloat ?? 0,
                nestedFrames: nestedFrames
            )
        }
        
        // 앵커 아이템 변환
        let anchorData = data["anchorItem"] as? [String: Any] ?? [:]
        let anchorItem = BFCacheSnapshot.ScrollState.AnchorItem(
            selector: anchorData["selector"] as? String ?? "body",
            offsetFromTop: anchorData["offsetFromTop"] as? CGFloat ?? 0,
            reactKey: anchorData["reactKey"] as? String
        )
        
        // 무한 스크롤 정보 변환
        var infiniteScrollInfo: BFCacheSnapshot.ScrollState.InfiniteScrollInfo?
        if let infiniteData = data["infiniteScroll"] as? [String: Any] {
            infiniteScrollInfo = BFCacheSnapshot.ScrollState.InfiniteScrollInfo(
                hasInfiniteScroll: infiniteData["hasInfiniteScroll"] as? Bool ?? false,
                currentPage: infiniteData["currentPage"] as? Int ?? 1,
                triggerSelector: infiniteData["triggerSelector"] as? String,
                loadedItemsCount: infiniteData["loadedItemsCount"] as? Int ?? 0
            )
        }
        
        return BFCacheSnapshot.ScrollState(
            scrollY: scrollY,
            viewportHeight: data["viewportHeight"] as? CGFloat ?? 800,
            contentHeight: data["contentHeight"] as? CGFloat ?? 1000,
            isReactApp: isReactApp,
            appContainerSelector: appContainer,
            iframeStates: iframeStates,
            anchorItem: anchorItem,
            infiniteScrollInfo: infiniteScrollInfo,
            reduxState: data["reduxState"] as? String
        )
    }
    
    private func createDefaultScrollState(scrollY: CGFloat) -> BFCacheSnapshot.ScrollState {
        return BFCacheSnapshot.ScrollState(
            scrollY: scrollY,
            viewportHeight: 800,
            contentHeight: 1000,
            isReactApp: false,
            appContainerSelector: "body",
            iframeStates: [],
            anchorItem: BFCacheSnapshot.ScrollState.AnchorItem(
                selector: "body",
                offsetFromTop: 0,
                reactKey: nil
            ),
            infiniteScrollInfo: nil,
            reduxState: nil
        )
    }
    
    // 비주얼 스냅샷 캡처
    private func captureVisualSnapshot(webView: WKWebView, bounds: CGRect) -> UIImage? {
        let semaphore = DispatchSemaphore(value: 0)
        var image: UIImage?
        
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { result, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패: \(error.localizedDescription)")
                    image = self.renderWebViewToImage(webView)
                } else {
                    image = result
                }
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 1.5)
        if result == .timedOut {
            image = renderWebViewToImage(webView)
        }
        
        return image
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 디스크 저장
    
    private func saveToDisk(snapshot: BFCacheSnapshot, image: UIImage?, tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.pageRecord.id
            let version = snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot
            
            // 이미지 저장
            if let image = image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    do {
                        try jpegData.write(to: imagePath)
                        finalSnapshot.webViewSnapshotPath = imagePath.path
                    } catch {
                        self.dbg("❌ 이미지 저장 실패: \(error)")
                    }
                }
            }
            
            // 상태 저장
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                do {
                    try stateData.write(to: statePath)
                } catch {
                    self.dbg("❌ 상태 저장 실패: \(error)")
                }
            }
            
            self.cacheAccessQueue.async(flags: .barrier) {
                self._diskCacheIndex[pageID] = pageDir.path
            }
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            self.dbg("💾 저장 완료: \(snapshot.pageRecord.title)")
        }
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    // MARK: - 디스크 캐시 로딩
    
    private func loadDiskCacheIndex() {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.createDirectoryIfNeeded(at: self.bfCacheDirectory)
            
            do {
                let tabDirs = try FileManager.default.contentsOfDirectory(at: self.bfCacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                
                var loadedCount = 0
                for tabDir in tabDirs {
                    if tabDir.lastPathComponent.hasPrefix("Tab_") {
                        let pageDirs = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        
                        for pageDir in pageDirs {
                            if pageDir.lastPathComponent.hasPrefix("Page_") {
                                // Page_UUID_v1 형식에서 UUID 추출
                                let fileName = pageDir.lastPathComponent
                                let parts = fileName.components(separatedBy: "_")
                                if parts.count >= 2, let pageUUID = UUID(uuidString: parts[1]) {
                                    self.cacheAccessQueue.async(flags: .barrier) {
                                        self._diskCacheIndex[pageUUID] = pageDir.path
                                    }
                                    loadedCount += 1
                                }
                            }
                        }
                    }
                }
                
                self.dbg("💾 디스크 캐시 로드: \(loadedCount)개")
            } catch {
                self.dbg("❌ 디스크 캐시 로드 실패: \(error)")
            }
        }
    }
    
    // MARK: - 스냅샷 조회
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                setMemoryCache(snapshot, for: pageID)
                dbg("💾 디스크 히트: \(snapshot.pageRecord.title)")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
    func hasCache(for pageID: UUID) -> Bool {
        return cacheAccessQueue.sync {
            _memoryCache[pageID] != nil || _diskCacheIndex[pageID] != nil
        }
    }
    
    // MARK: - 🎯 **단순화된 제스처 시스템**
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        webView.allowsBackForwardNavigationGestures = false
        
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        webView.addGestureRecognizer(leftEdge)
        
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        webView.addGestureRecognizer(rightEdge)
        
        if let tabID = stateModel.tabID {
            let ctx = WeakGestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
            objc_setAssociatedObject(leftEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(rightEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        dbg("경량화된 제스처 설정 완료")
    }
    
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let ctx = objc_getAssociatedObject(gesture, "bfcache_ctx") as? WeakGestureContext,
              let stateModel = ctx.stateModel else { return }
        let webView = ctx.webView ?? (gesture.view as? WKWebView)
        guard let webView else { return }
        
        let tabID = ctx.tabID
        
        // 🔧 **단순화된 제스처 체크**
        if isGestureBlocked(for: tabID) || isGestureActive(for: tabID) {
            gesture.state = .cancelled
            dbg("🚫 제스처 블록: \(tabID.uuidString)")
            return
        }
        
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        let width = gesture.view?.bounds.width ?? 1
        
        let absX = abs(translation.x), absY = abs(translation.y)
        let horizontalEnough = absX > 10 && absX > absY
        let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
        
        switch gesture.state {
        case .began:
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                setGestureActive(true, for: tabID)
                
                // 현재 페이지 스냅샷 먼저 캡처
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .delayed, tabID: tabID)
                }
                
                // 전환 시작
                captureCurrentSnapshot(webView: webView) { [weak self] snapshot in
                    DispatchQueue.main.async {
                        if self?.isGestureActive(for: tabID) == true {
                            self?.beginGestureTransition(
                                tabID: tabID,
                                webView: webView,
                                stateModel: stateModel,
                                direction: direction,
                                currentSnapshot: snapshot
                            )
                        }
                    }
                }
            } else {
                gesture.state = .cancelled
                blockGestures(for: tabID, duration: 0.5)
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
    
    // 현재 스냅샷 캡처
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = false
        
        webView.takeSnapshot(with: config) { image, error in
            if let error = error {
                self.dbg("📸 현재 스냅샷 실패: \(error.localizedDescription)")
                let fallback = self.renderWebViewToImage(webView)
                completion(fallback)
            } else {
                completion(image)
            }
        }
    }
    
    private func beginGestureTransition(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection, currentSnapshot: UIImage?) {
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
            direction: direction,
            previewContainer: previewContainer,
            currentSnapshot: currentSnapshot
        )
        activeTransitions[tabID] = context
        
        dbg("🎬 제스처 전환 시작: \(direction == .back ? "뒤로" : "앞으로")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetPreview = previewContainer.viewWithTag(1002)
        
        if isLeftEdge {
            let moveDistance = max(0, min(screenWidth, translation))
            currentView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = -screenWidth + moveDistance
        } else {
            let moveDistance = max(-screenWidth, min(0, translation))
            currentView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = screenWidth + moveDistance
        }
    }
    
    private func createPreviewContainer(webView: WKWebView, direction: NavigationDirection, stateModel: WebViewStateModel, currentSnapshot: UIImage? = nil) -> UIView {
        let container = UIView(frame: webView.bounds)
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        
        // 현재 페이지 뷰
        let currentView: UIView
        if let snapshot = currentSnapshot {
            let imageView = UIImageView(image: snapshot)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            currentView = imageView
        } else {
            currentView = UIView()
            currentView.backgroundColor = .systemBackground
        }
        
        currentView.frame = webView.bounds
        currentView.tag = 1001
        container.addSubview(currentView)
        
        // 타겟 페이지 뷰
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
                dbg("📸 타겟 BFCache 스냅샷 사용: \(targetRecord.title)")
            } else {
                targetView = createInfoCard(for: targetRecord, in: webView.bounds)
                dbg("ℹ️ 타겟 정보 카드 생성: \(targetRecord.title)")
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
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(280, bounds.width - 40)),
            contentView.heightAnchor.constraint(equalToConstant: 150),
            
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])
        
        return card
    }
    
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer else { 
            setGestureActive(false, for: tabID)
            return 
        }
        
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
            },
            completion: { [weak self] _ in
                self?.performNavigation(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    private func performNavigation(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            setGestureActive(false, for: context.tabID)
            return
        }
        
        // 네비게이션 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 앞으로가기 완료")
        }
        
        // 복원 시도
        tryBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.setGestureActive(false, for: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - 복원 \(success ? "성공" : "실패")")
            }
        }
        
        // 안전장치: 2초 후 강제 정리
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(for: context.tabID)
                self?.setGestureActive(false, for: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리")
            }
        }
    }
    
    private func tryBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ 경량화된 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ 경량화된 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                completion(false)
            }
        }
    }
    
    private func cancelGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer else { 
            setGestureActive(false, for: tabID)
            return 
        }
        
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
            },
            completion: { [weak self] _ in
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: tabID)
                self?.setGestureActive(false, for: tabID)
            }
        )
    }
    
    // MARK: - 버튼 네비게이션
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if isGestureActive(for: tabID) {
            dbg("🚫 버튼 네비게이션 블록: 제스처 활성화 중")
            return
        }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .delayed, tabID: tabID)
        }
        
        stateModel.goBack()
        blockGestures(for: tabID, duration: 1.0)
        
        tryBFCacheRestore(stateModel: stateModel, direction: .back) { [weak self] _ in
            self?.clearGestureBlock(for: tabID)
        }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if isGestureActive(for: tabID) {
            dbg("🚫 버튼 네비게이션 블록: 제스처 활성화 중")
            return
        }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .delayed, tabID: tabID)
        }
        
        stateModel.goForward()
        blockGestures(for: tabID, duration: 1.0)
        
        tryBFCacheRestore(stateModel: stateModel, direction: .forward) { [weak self] _ in
            self?.clearGestureBlock(for: tabID)
        }
    }
    
    // MARK: - 캐시 정리
    
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
            }
        }
        
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            let tabDir = self.tabDirectory(for: tabID)
            do {
                try FileManager.default.removeItem(at: tabDir)
                self.dbg("🗑️ 탭 캐시 삭제: \(tabID)")
            } catch {
                self.dbg("⚠️ 탭 캐시 삭제 실패: \(error)")
            }
        }
    }
    
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
            
            let sorted = self._memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            self.dbg("⚠️ 메모리 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🌐 **경량화된 JavaScript**
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        // 🎯 경량화된 BFCache 스크립트 - React/SPA + 무한스크롤 핵심
        (function() {
            'use strict';
            
            console.log('🚀 경량화된 BFCache 스크립트 초기화');
            
            // iOS 웹뷰: 강제 manual 스크롤 복원
            if (history.scrollRestoration) {
                history.scrollRestoration = 'manual';
            }
            
            // === React/SPA 감지 ===
            const isReactApp = !!(window.React || document.querySelector('[data-reactroot]') || window.__REACT_DEVTOOLS_GLOBAL_HOOK__);
            const isSPA = !!(window.history && window.history.pushState);
            
            if (isReactApp) {
                console.log('⚛️ React 앱 감지');
                
                // Redux 상태 저장 헬퍼
                window.saveReduxState = function() {
                    if (window.__REDUX_STORE__) {
                        const state = window.__REDUX_STORE__.getState();
                        window.__BFCACHE_REDUX_STATE__ = JSON.stringify(state);
                        return state;
                    }
                    return null;
                };
            }
            
            // === SPA 네비게이션 후킹 (기존 유지) ===
            if (isSPA) {
                const originalPushState = history.pushState;
                const originalReplaceState = history.replaceState;
                
                history.pushState = function(...args) {
                    const result = originalPushState.apply(this, args);
                    setTimeout(() => {
                        if (window.webkit?.messageHandlers?.spaNavigation) {
                            window.webkit.messageHandlers.spaNavigation.postMessage({
                                type: 'push',
                                url: window.location.href,
                                title: document.title,
                                timestamp: Date.now()
                            });
                        }
                    }, 50);
                    return result;
                };
                
                history.replaceState = function(...args) {
                    const result = originalReplaceState.apply(this, args);
                    setTimeout(() => {
                        if (window.webkit?.messageHandlers?.spaNavigation) {
                            window.webkit.messageHandlers.spaNavigation.postMessage({
                                type: 'replace',
                                url: window.location.href,
                                title: document.title,
                                timestamp: Date.now()
                            });
                        }
                    }, 50);
                    return result;
                };
                
                window.addEventListener('popstate', () => {
                    setTimeout(() => {
                        if (window.webkit?.messageHandlers?.spaNavigation) {
                            window.webkit.messageHandlers.spaNavigation.postMessage({
                                type: 'pop',
                                url: window.location.href,
                                title: document.title,
                                timestamp: Date.now()
                            });
                        }
                    }, 50);
                });
            }
            
            // === BFCache 이벤트 ===
            window.addEventListener('pageshow', function(event) {
                if (event.persisted) {
                    console.log('🔄 BFCache 복원');
                    
                    if (isReactApp && window.__BFCACHE_REDUX_STATE__) {
                        console.log('🗃️ Redux 상태 복원 준비');
                    }
                    
                    window.dispatchEvent(new CustomEvent('bfcacheRestoreReady', {
                        detail: { isReactApp, timestamp: Date.now() }
                    }));
                }
            });
            
            window.addEventListener('pagehide', function(event) {
                if (event.persisted) {
                    console.log('📸 BFCache 저장');
                    if (isReactApp && window.saveReduxState) {
                        window.saveReduxState();
                    }
                }
            });
            
            // === 스크롤 위치 고정 ===
            window.lockScrollPosition = function(lockY, options = {}) {
                window.__BFCACHE_LOCKED__ = true;
                window.__BFCACHE_TARGET_Y__ = lockY;
                
                const handler = (event) => {
                    if (!window.__BFCACHE_LOCKED__) return;
                    
                    const currentY = window.scrollY;
                    const targetY = window.__BFCACHE_TARGET_Y__;
                    
                    if (Math.abs(currentY - targetY) > 5) {
                        if (options.strict) {
                            event.preventDefault();
                        }
                        requestAnimationFrame(() => {
                            window.scrollTo({ top: targetY, behavior: 'auto' });
                        });
                    }
                };
                
                window.addEventListener('scroll', handler, { passive: !options.strict });
                window.addEventListener('wheel', handler, { passive: !options.strict });
                window.addEventListener('touchmove', handler, { passive: !options.strict });
                
                return () => {
                    window.__BFCACHE_LOCKED__ = false;
                    window.removeEventListener('scroll', handler);
                    window.removeEventListener('wheel', handler);
                    window.removeEventListener('touchmove', handler);
                    delete window.__BFCACHE_TARGET_Y__;
                };
            };
            
            // === 무한 스크롤 보호 ===
            if (window.IntersectionObserver) {
                const OriginalIO = window.IntersectionObserver;
                
                window.IntersectionObserver = function(callback, options) {
                    const wrappedCallback = (entries, observer) => {
                        // BFCache 복원 중에는 무한 스크롤 방지
                        if (window.__BFCACHE_LOCKED__) {
                            console.log('🤫 스크롤 고정 중 - Intersection Observer 지연');
                            return;
                        }
                        
                        // 복원 플래그 체크
                        const triggers = entries.filter(entry => 
                            entry.target.dataset && !entry.target.dataset.bfcacheRestoring
                        );
                        
                        if (triggers.length > 0) {
                            callback(triggers, observer);
                        }
                    };
                    
                    return new OriginalIO(wrappedCallback, options);
                };
                
                window.IntersectionObserver.prototype = OriginalIO.prototype;
            }
            
            console.log('✅ 경량화된 BFCache 스크립트 로드 완료:', { isReactApp, isSPA });
            
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 스와이프 제스처 감지 처리
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지 추가: \(url.absoluteString)")
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[경량화BFCache] \(msg)")
    }
}

// MARK: - UIGestureRecognizerDelegate
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - CustomWebView 통합
extension BFCacheTransitionSystem {
    
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        shared.setupGestures(for: webView, stateModel: stateModel)
        TabPersistenceManager.debugMessages.append("✅ 경량화된 BFCache 시스템 설치")
    }
    
    static func uninstall(from webView: WKWebView) {
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        TabPersistenceManager.debugMessages.append("🧹 경량화된 BFCache 시스템 제거")
    }
    
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
}

// MARK: - 퍼블릭 인터페이스
extension BFCacheTransitionSystem {

    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, type: .delayed, tabID: tabID)
        dbg("📸 떠나는 페이지 캡처: \(rec.title)")
    }

    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, type: .delayed, tabID: tabID)
        dbg("📸 도착한 페이지 캡처: \(rec.title)")
        
        // 이전 페이지들 기본 메타데이터 생성
        if stateModel.dataModel.currentPageIndex > 0 {
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                if !hasCache(for: previousRecord.id) {
                    let metaSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollPosition: .zero,
                        timestamp: Date(),
                        captureStatus: .failed,
                        version: 1,
                        scrollState: createDefaultScrollState(scrollY: 0)
                    )
                    
                    saveToDisk(snapshot: metaSnapshot, image: nil, tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터: '\(previousRecord.title)'")
                }
            }
        }
    }
}
