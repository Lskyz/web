//
//  BFCacheSwipeTransition.swift
//  🎯 **범용 SPA 최적화 BFCache 시스템**
//  ✅ 모든 웹사이트에서 작동하는 동적 콘텐츠 추적
//  🔄 실시간 DOM 변화 감지 및 스마트 캡처
//  📸 콘텐츠 해시 기반 중복 제거
//  🌐 프레임워크 무관 범용 시스템
//  ⚡ 스크롤 복원 최적화
//  💾 증분 캡처로 효율성 극대화
//

import UIKit
import WebKit
import SwiftUI
import CryptoKit

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

// MARK: - 📊 범용 콘텐츠 변화 추적
struct ContentChangeInfo {
    let timestamp: Date
    let changeType: ChangeType
    let contentHash: String
    let scrollHash: String  // 스크롤 위치도 해시에 포함
    let elementCount: Int
    let scrollableElements: Int
    
    enum ChangeType {
        case initial
        case domMutation
        case scroll
        case resize
        case frameChange
        case mediaLoad
        case visibility
    }
}

// MARK: - 🔍 범용 사이트 프로파일
struct SiteProfile: Codable {
    let hostname: String
    var domPatterns: [DOMPattern] = []
    var scrollContainers: [String] = []  // 자주 사용되는 스크롤 컨테이너 셀렉터
    var averageLoadTime: TimeInterval = 0.5
    var iframePaths: [String] = []  // iframe 구조 경로
    var lastUpdated: Date = Date()
    
    struct DOMPattern: Codable {
        let selector: String
        let isScrollable: Bool
        let frequency: Int  // 얼마나 자주 변경되는지
    }
    
    mutating func learnScrollContainer(_ selector: String) {
        if !scrollContainers.contains(selector) {
            scrollContainers.append(selector)
        }
    }
    
    mutating func recordLoadTime(_ duration: TimeInterval) {
        averageLoadTime = (averageLoadTime + duration) / 2
        lastUpdated = Date()
    }
}

// MARK: - 📸 범용 BFCache 스냅샷 (SPA 최적화)
struct SPAOptimizedSnapshot: Codable {
    let pageRecord: PageRecord
    let contentHash: String  // 전체 콘텐츠 해시
    let scrollStates: [ScrollState]  // 모든 스크롤 상태
    let domSnapshot: String?
    let visualSnapshot: VisualSnapshot?
    let frameSnapshots: [FrameSnapshot]  // iframe별 스냅샷
    let timestamp: Date
    let captureContext: CaptureContext
    
    struct ScrollState: Codable {
        let selector: String
        let xpath: String?
        let scrollTop: CGFloat
        let scrollLeft: CGFloat
        let scrollHeight: CGFloat
        let scrollWidth: CGFloat
        let clientHeight: CGFloat
        let clientWidth: CGFloat
        let isMainDocument: Bool
        let frameIndex: Int?  // iframe인 경우 인덱스
    }
    
    struct VisualSnapshot: Codable {
        let imagePath: String?
        let thumbnailPath: String?
        let viewport: CGRect
    }
    
    struct FrameSnapshot: Codable {
        let src: String
        let selector: String
        let scrollStates: [ScrollState]
        let contentHash: String
    }
    
    struct CaptureContext: Codable {
        let url: String
        let title: String
        let isFullCapture: Bool
        let changesSinceLastCapture: Int
        let captureReason: String  // "mutation", "scroll", "timer" 등
    }
}

// MARK: - 🎯 범용 BFCache 전환 시스템 (SPA 최적화)
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        loadDiskCacheIndex()
        loadSiteProfiles()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 직렬화 큐
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    private let analysisQueue = DispatchQueue(label: "bfcache.analysis", qos: .utility)
    
    // MARK: - 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [String: SPAOptimizedSnapshot] = [:]  // contentHash 기반
    private var _diskCacheIndex: [String: String] = [:]
    private var _siteProfiles: [String: SiteProfile] = [:]
    private var _lastContentHash: [UUID: String] = [:]  // 탭별 마지막 콘텐츠 해시
    
    // MARK: - DOM 변화 추적
    private var activeMutationObservers: [UUID: Bool] = [:]  // 탭별 Observer 활성 상태
    private var pendingCaptures: [UUID: DispatchWorkItem] = [:]  // 디바운싱된 캡처 작업
    private let captureDebounceInterval: TimeInterval = 0.8  // 800ms 디바운스
    
    // MARK: - 전환 상태
    private var activeTransitions: [UUID: TransitionContext] = [:]
    
    private struct TransitionContext {
        let tabID: UUID
        weak var webView: WKWebView?
        weak var stateModel: WebViewStateModel?
        var isGesture: Bool
        var direction: NavigationDirection
        var initialTransform: CGAffineTransform
        var previewContainer: UIView?
        var currentSnapshot: UIImage?
        let gestureStartIndex: Int
        let targetPageRecord: PageRecord?
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    // MARK: - 🌐 범용 DOM 변화 감지 시스템
    
    func installDOMObserver(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let tabID = stateModel.tabID else { return }
        
        // 기존 Observer가 있으면 제거
        if activeMutationObservers[tabID] == true {
            removeDOMObserver(tabID: tabID, webView: webView)
        }
        
        // 범용 DOM Observer 스크립트 주입
        let observerScript = generateUniversalDOMObserverScript()
        webView.evaluateJavaScript(observerScript) { [weak self] _, error in
            if error == nil {
                self?.activeMutationObservers[tabID] = true
                self?.dbg("🔍 범용 DOM Observer 설치 완료")
            } else {
                self?.dbg("❌ DOM Observer 설치 실패: \(error?.localizedDescription ?? "")")
            }
        }
        
        // 메시지 핸들러 설정 (DOM 변화 수신)
        webView.configuration.userContentController.add(self, name: "domChange")
        webView.configuration.userContentController.add(self, name: "scrollChange")
    }
    
    private func removeDOMObserver(tabID: UUID, webView: WKWebView) {
        let removeScript = """
        if (window.__bfCacheDOMObserver) {
            window.__bfCacheDOMObserver.disconnect();
            window.__bfCacheDOMObserver = null;
        }
        if (window.__bfCacheScrollTracking) {
            clearInterval(window.__bfCacheScrollTracking);
            window.__bfCacheScrollTracking = null;
        }
        """
        webView.evaluateJavaScript(removeScript) { _, _ in }
        activeMutationObservers[tabID] = false
    }
    
    // MARK: - 🔍 범용 DOM Observer 스크립트 생성
    
    private func generateUniversalDOMObserverScript() -> String {
        return """
        (function() {
            'use strict';
            
            console.log('🔍 BFCache 범용 DOM Observer 초기화');
            
            // 기존 Observer 정리
            if (window.__bfCacheDOMObserver) {
                window.__bfCacheDOMObserver.disconnect();
            }
            
            // 유틸리티 함수들
            const utils = {
                // 요소의 고유 식별자 생성
                getElementIdentifier(element) {
                    if (element.id) return '#' + element.id;
                    
                    let path = [];
                    let current = element;
                    
                    while (current && current !== document.body) {
                        let selector = current.tagName.toLowerCase();
                        if (current.className) {
                            const classes = Array.from(current.classList)
                                .filter(c => !c.includes('active') && !c.includes('hover'))
                                .slice(0, 2);
                            if (classes.length) {
                                selector += '.' + classes.join('.');
                            }
                        }
                        path.unshift(selector);
                        current = current.parentElement;
                    }
                    
                    return path.join(' > ');
                },
                
                // 스크롤 가능 요소 탐지
                isScrollable(element) {
                    const style = window.getComputedStyle(element);
                    const overflowY = style.overflowY;
                    const overflowX = style.overflowX;
                    
                    const scrollableY = (overflowY === 'auto' || overflowY === 'scroll') && 
                                       element.scrollHeight > element.clientHeight;
                    const scrollableX = (overflowX === 'auto' || overflowX === 'scroll') && 
                                       element.scrollWidth > element.clientWidth;
                    
                    return scrollableY || scrollableX;
                },
                
                // 모든 스크롤 가능 요소 수집
                getAllScrollableElements() {
                    const scrollables = [];
                    const elements = document.querySelectorAll('*');
                    
                    // 메인 문서
                    if (document.documentElement.scrollHeight > window.innerHeight ||
                        document.body.scrollHeight > window.innerHeight) {
                        scrollables.push({
                            element: document.documentElement,
                            selector: 'document',
                            isMainDocument: true
                        });
                    }
                    
                    // 모든 요소 검사
                    elements.forEach(el => {
                        if (this.isScrollable(el)) {
                            scrollables.push({
                                element: el,
                                selector: this.getElementIdentifier(el),
                                isMainDocument: false
                            });
                        }
                    });
                    
                    // iframe 검사
                    const iframes = document.querySelectorAll('iframe');
                    iframes.forEach((iframe, index) => {
                        try {
                            const iframeDoc = iframe.contentDocument || iframe.contentWindow?.document;
                            if (iframeDoc) {
                                scrollables.push({
                                    element: iframe,
                                    selector: `iframe:nth-of-type(${index + 1})`,
                                    isFrame: true,
                                    frameIndex: index
                                });
                            }
                        } catch (e) {
                            // Cross-origin iframe은 접근 불가
                        }
                    });
                    
                    return scrollables;
                },
                
                // 콘텐츠 해시 생성 (빠른 버전)
                generateContentHash() {
                    const texts = [];
                    const walker = document.createTreeWalker(
                        document.body,
                        NodeFilter.SHOW_TEXT,
                        {
                            acceptNode: function(node) {
                                const parent = node.parentElement;
                                if (parent && (parent.tagName === 'SCRIPT' || 
                                              parent.tagName === 'STYLE' ||
                                              parent.style.display === 'none')) {
                                    return NodeFilter.FILTER_REJECT;
                                }
                                return node.textContent.trim() ? 
                                    NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
                            }
                        }
                    );
                    
                    let node;
                    let count = 0;
                    while ((node = walker.nextNode()) && count < 100) {
                        texts.push(node.textContent.trim());
                        count++;
                    }
                    
                    // 간단한 해시 생성
                    const content = texts.join('|').slice(0, 1000);
                    return btoa(content).slice(0, 20);
                },
                
                // 스크롤 상태 수집
                collectScrollStates() {
                    const scrollables = this.getAllScrollableElements();
                    const states = [];
                    
                    scrollables.forEach(item => {
                        const el = item.element;
                        const rect = el.getBoundingClientRect();
                        
                        states.push({
                            selector: item.selector,
                            scrollTop: el.scrollTop || window.pageYOffset || 0,
                            scrollLeft: el.scrollLeft || window.pageXOffset || 0,
                            scrollHeight: el.scrollHeight || document.documentElement.scrollHeight,
                            scrollWidth: el.scrollWidth || document.documentElement.scrollWidth,
                            clientHeight: el.clientHeight || window.innerHeight,
                            clientWidth: el.clientWidth || window.innerWidth,
                            isMainDocument: item.isMainDocument || false,
                            isFrame: item.isFrame || false,
                            frameIndex: item.frameIndex
                        });
                    });
                    
                    return states;
                }
            };
            
            // 변화 감지 디바운싱
            let changeTimer = null;
            let lastContentHash = '';
            let mutationCount = 0;
            
            function notifyChange(type, details = {}) {
                clearTimeout(changeTimer);
                changeTimer = setTimeout(() => {
                    const currentHash = utils.generateContentHash();
                    const scrollStates = utils.collectScrollStates();
                    
                    // 콘텐츠가 실제로 변경된 경우만 알림
                    if (type === 'mutation' && currentHash === lastContentHash && mutationCount < 5) {
                        mutationCount++;
                        return;
                    }
                    
                    if (currentHash !== lastContentHash) {
                        mutationCount = 0;
                        lastContentHash = currentHash;
                    }
                    
                    window.webkit?.messageHandlers?.domChange?.postMessage({
                        type: type,
                        contentHash: currentHash,
                        scrollStates: scrollStates,
                        elementCount: document.querySelectorAll('*').length,
                        timestamp: Date.now(),
                        url: window.location.href,
                        title: document.title,
                        ...details
                    });
                    
                }, 300); // 300ms 디바운스
            }
            
            // MutationObserver 설정
            const observerConfig = {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['style', 'class', 'src', 'href'],
                characterData: true
            };
            
            const observer = new MutationObserver((mutations) => {
                // 의미있는 변화인지 필터링
                const significantChange = mutations.some(mutation => {
                    if (mutation.type === 'childList' && mutation.addedNodes.length > 0) {
                        return Array.from(mutation.addedNodes).some(node => 
                            node.nodeType === 1 && // Element node
                            !['SCRIPT', 'STYLE', 'META', 'LINK'].includes(node.tagName)
                        );
                    }
                    return mutation.type === 'characterData';
                });
                
                if (significantChange) {
                    notifyChange('mutation', { 
                        mutationType: mutations[0].type,
                        targetTag: mutations[0].target.tagName
                    });
                }
            });
            
            // Observer 시작
            observer.observe(document.body, observerConfig);
            window.__bfCacheDOMObserver = observer;
            
            // 스크롤 추적 (최적화된 버전)
            let scrollTimer = null;
            let lastScrollData = null;
            
            function trackScroll(event) {
                clearTimeout(scrollTimer);
                scrollTimer = setTimeout(() => {
                    const scrollStates = utils.collectScrollStates();
                    const scrollData = JSON.stringify(scrollStates);
                    
                    // 스크롤이 실제로 변경된 경우만
                    if (scrollData !== lastScrollData) {
                        lastScrollData = scrollData;
                        window.webkit?.messageHandlers?.scrollChange?.postMessage({
                            scrollStates: scrollStates,
                            timestamp: Date.now()
                        });
                    }
                }, 100); // 100ms 디바운스
            }
            
            // 스크롤 이벤트 리스너 (캡처 페이즈 사용)
            window.addEventListener('scroll', trackScroll, true);
            document.addEventListener('scroll', trackScroll, true);
            
            // iframe 로드 감지
            document.querySelectorAll('iframe').forEach(iframe => {
                iframe.addEventListener('load', () => {
                    notifyChange('frameLoad', { frameSrc: iframe.src });
                });
            });
            
            // 리사이즈 감지
            let resizeTimer = null;
            window.addEventListener('resize', () => {
                clearTimeout(resizeTimer);
                resizeTimer = setTimeout(() => {
                    notifyChange('resize', { 
                        width: window.innerWidth, 
                        height: window.innerHeight 
                    });
                }, 500);
            });
            
            // 초기 상태 전송
            setTimeout(() => {
                lastContentHash = utils.generateContentHash();
                notifyChange('initial');
            }, 100);
            
            console.log('✅ BFCache DOM Observer 활성화 완료');
        })();
        """
    }
    
    // MARK: - 콘텐츠 변화 처리
    
    private func handleContentChange(tabID: UUID, changeInfo: [String: Any]) {
        // 기존 캡처 작업 취소
        pendingCaptures[tabID]?.cancel()
        
        // 새로운 디바운싱된 캡처 작업 생성
        let captureWork = DispatchWorkItem { [weak self] in
            self?.performSmartCapture(tabID: tabID, changeInfo: changeInfo)
        }
        
        pendingCaptures[tabID] = captureWork
        
        // 디바운싱 적용
        serialQueue.asyncAfter(deadline: .now() + captureDebounceInterval, execute: captureWork)
    }
    
    private func performSmartCapture(tabID: UUID, changeInfo: [String: Any]) {
        guard let contentHash = changeInfo["contentHash"] as? String else { return }
        
        // 중복 체크 (콘텐츠 해시 기반)
        if let lastHash = _lastContentHash[tabID], lastHash == contentHash {
            dbg("🔄 콘텐츠 변화 없음 - 캡처 스킵")
            return
        }
        
        _lastContentHash[tabID] = contentHash
        
        // StateModel과 WebView 조회
        guard let stateModel = findStateModel(for: tabID),
              let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            return
        }
        
        dbg("📸 콘텐츠 변화 감지 - 스마트 캡처 시작")
        dbg("   변화 타입: \(changeInfo["type"] ?? "unknown")")
        dbg("   콘텐츠 해시: \(contentHash)")
        dbg("   요소 수: \(changeInfo["elementCount"] ?? 0)")
        
        // 스크롤 상태 파싱
        let scrollStates = parseScrollStates(from: changeInfo)
        
        // 스냅샷 생성 및 저장
        captureOptimizedSnapshot(
            webView: webView,
            stateModel: stateModel,
            contentHash: contentHash,
            scrollStates: scrollStates,
            changeInfo: changeInfo
        )
    }
    
    private func parseScrollStates(from changeInfo: [String: Any]) -> [SPAOptimizedSnapshot.ScrollState] {
        guard let scrollData = changeInfo["scrollStates"] as? [[String: Any]] else { return [] }
        
        return scrollData.compactMap { data in
            guard let selector = data["selector"] as? String else { return nil }
            
            return SPAOptimizedSnapshot.ScrollState(
                selector: selector,
                xpath: data["xpath"] as? String,
                scrollTop: CGFloat(data["scrollTop"] as? Double ?? 0),
                scrollLeft: CGFloat(data["scrollLeft"] as? Double ?? 0),
                scrollHeight: CGFloat(data["scrollHeight"] as? Double ?? 0),
                scrollWidth: CGFloat(data["scrollWidth"] as? Double ?? 0),
                clientHeight: CGFloat(data["clientHeight"] as? Double ?? 0),
                clientWidth: CGFloat(data["clientWidth"] as? Double ?? 0),
                isMainDocument: data["isMainDocument"] as? Bool ?? false,
                frameIndex: data["frameIndex"] as? Int
            )
        }
    }
    
    // MARK: - 🎯 최적화된 스냅샷 캡처
    
    private func captureOptimizedSnapshot(
        webView: WKWebView,
        stateModel: WebViewStateModel,
        contentHash: String,
        scrollStates: [SPAOptimizedSnapshot.ScrollState],
        changeInfo: [String: Any]
    ) {
        // 비주얼 스냅샷은 선택적으로 (스크롤 변화만 있으면 스킵)
        let needsVisualSnapshot = changeInfo["type"] as? String != "scroll"
        
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            
            var visualSnapshot: SPAOptimizedSnapshot.VisualSnapshot? = nil
            
            if needsVisualSnapshot {
                // 비주얼 캡처 (메인 스레드)
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    self.captureVisual(webView: webView) { image in
                        if let image = image {
                            // 이미지 저장은 백그라운드에서
                            visualSnapshot = SPAOptimizedSnapshot.VisualSnapshot(
                                imagePath: nil, // 나중에 설정
                                thumbnailPath: nil,
                                viewport: webView.bounds
                            )
                        }
                        semaphore.signal()
                    }
                }
                _ = semaphore.wait(timeout: .now() + 2)
            }
            
            // iframe 스냅샷 수집
            let frameSnapshots = self.captureFrameSnapshots(webView: webView)
            
            // 캡처 컨텍스트 생성
            let captureContext = SPAOptimizedSnapshot.CaptureContext(
                url: changeInfo["url"] as? String ?? webView.url?.absoluteString ?? "",
                title: changeInfo["title"] as? String ?? stateModel.currentPageRecord?.title ?? "",
                isFullCapture: needsVisualSnapshot,
                changesSinceLastCapture: 1,
                captureReason: changeInfo["type"] as? String ?? "unknown"
            )
            
            // 스냅샷 생성
            let snapshot = SPAOptimizedSnapshot(
                pageRecord: stateModel.currentPageRecord!,
                contentHash: contentHash,
                scrollStates: scrollStates,
                domSnapshot: nil, // 필요시 추가
                visualSnapshot: visualSnapshot,
                frameSnapshots: frameSnapshots,
                timestamp: Date(),
                captureContext: captureContext
            )
            
            // 메모리에 저장 (콘텐츠 해시 기반)
            self.storeSnapshot(snapshot, contentHash: contentHash)
            
            // 사이트 프로파일 업데이트
            self.updateSiteProfile(for: webView.url, with: scrollStates)
            
            self.dbg("✅ 스마트 스냅샷 저장 완료: \(contentHash)")
        }
    }
    
    private func captureVisual(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = false
        
        webView.takeSnapshot(with: config) { image, error in
            completion(image)
        }
    }
    
    private func captureFrameSnapshots(webView: WKWebView) -> [SPAOptimizedSnapshot.FrameSnapshot] {
        var frameSnapshots: [SPAOptimizedSnapshot.FrameSnapshot] = []
        
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let script = """
            (function() {
                const frames = [];
                document.querySelectorAll('iframe').forEach((iframe, index) => {
                    try {
                        const doc = iframe.contentDocument || iframe.contentWindow?.document;
                        if (doc) {
                            frames.push({
                                src: iframe.src,
                                selector: 'iframe:nth-of-type(' + (index + 1) + ')',
                                hasAccess: true
                            });
                        }
                    } catch (e) {
                        frames.push({
                            src: iframe.src,
                            selector: 'iframe:nth-of-type(' + (index + 1) + ')',
                            hasAccess: false
                        });
                    }
                });
                return frames;
            })()
            """
            
            webView.evaluateJavaScript(script) { result, _ in
                if let frames = result as? [[String: Any]] {
                    frames.forEach { frame in
                        if let src = frame["src"] as? String,
                           let selector = frame["selector"] as? String {
                            frameSnapshots.append(SPAOptimizedSnapshot.FrameSnapshot(
                                src: src,
                                selector: selector,
                                scrollStates: [],
                                contentHash: ""
                            ))
                        }
                    }
                }
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 1)
        
        return frameSnapshots
    }
    
    // MARK: - 🔄 범용 스크롤 복원
    
    func restoreScrollStates(_ scrollStates: [SPAOptimizedSnapshot.ScrollState], to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let restoreScript = generateScrollRestoreScript(scrollStates)
        
        webView.evaluateJavaScript(restoreScript) { result, error in
            if let error = error {
                self.dbg("❌ 스크롤 복원 실패: \(error.localizedDescription)")
                completion(false)
            } else {
                let success = (result as? Bool) ?? false
                self.dbg("✅ 스크롤 복원 \(success ? "성공" : "부분 성공")")
                completion(success)
            }
        }
    }
    
    private func generateScrollRestoreScript(_ scrollStates: [SPAOptimizedSnapshot.ScrollState]) -> String {
        let statesJSON = scrollStates.map { state -> String in
            """
            {
                selector: "\(state.selector)",
                scrollTop: \(state.scrollTop),
                scrollLeft: \(state.scrollLeft),
                isMainDocument: \(state.isMainDocument),
                frameIndex: \(state.frameIndex ?? -1)
            }
            """
        }.joined(separator: ",")
        
        return """
        (function() {
            const states = [\(statesJSON)];
            let restored = 0;
            
            states.forEach(state => {
                try {
                    if (state.isMainDocument) {
                        window.scrollTo(state.scrollLeft, state.scrollTop);
                        document.documentElement.scrollTop = state.scrollTop;
                        document.body.scrollTop = state.scrollTop;
                        restored++;
                    } else if (state.frameIndex >= 0) {
                        const iframe = document.querySelectorAll('iframe')[state.frameIndex];
                        if (iframe && iframe.contentWindow) {
                            iframe.contentWindow.scrollTo(state.scrollLeft, state.scrollTop);
                            restored++;
                        }
                    } else {
                        // 일반 요소
                        const elements = document.querySelectorAll(state.selector);
                        if (elements.length > 0) {
                            elements.forEach(el => {
                                el.scrollTop = state.scrollTop;
                                el.scrollLeft = state.scrollLeft;
                            });
                            restored++;
                        }
                    }
                } catch (e) {
                    console.error('스크롤 복원 실패:', state.selector, e);
                }
            });
            
            console.log(`스크롤 복원: ${restored}/${states.length} 성공`);
            return restored === states.length;
        })()
        """
    }
    
    // MARK: - 사이트 프로파일 학습
    
    private func updateSiteProfile(for url: URL?, with scrollStates: [SPAOptimizedSnapshot.ScrollState]) {
        guard let url = url, let hostname = url.host else { return }
        
        analysisQueue.async { [weak self] in
            guard let self = self else { return }
            
            var profile = self.getSiteProfile(for: hostname) ?? SiteProfile(hostname: hostname)
            
            // 스크롤 컨테이너 학습
            scrollStates.forEach { state in
                if !state.isMainDocument && state.frameIndex == nil {
                    profile.learnScrollContainer(state.selector)
                }
            }
            
            self.cacheAccessQueue.async(flags: .barrier) {
                self._siteProfiles[hostname] = profile
            }
        }
    }
    
    private func getSiteProfile(for hostname: String) -> SiteProfile? {
        return cacheAccessQueue.sync { _siteProfiles[hostname] }
    }
    
    // MARK: - 스냅샷 저장/조회
    
    private func storeSnapshot(_ snapshot: SPAOptimizedSnapshot, contentHash: String) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache[contentHash] = snapshot
            
            // 메모리 제한 (최대 50개)
            if self._memoryCache.count > 50 {
                // 가장 오래된 것 제거
                if let oldest = self._memoryCache.min(by: { $0.value.timestamp < $1.value.timestamp }) {
                    self._memoryCache.removeValue(forKey: oldest.key)
                }
            }
        }
    }
    
    func findSnapshot(for pageRecord: PageRecord, near contentHash: String? = nil) -> SPAOptimizedSnapshot? {
        // 1. 정확한 콘텐츠 해시로 검색
        if let hash = contentHash,
           let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[hash] }) {
            return snapshot
        }
        
        // 2. PageRecord URL로 가장 최근 스냅샷 검색
        let snapshots = cacheAccessQueue.sync { _memoryCache.values }
        return snapshots
            .filter { $0.pageRecord.url == pageRecord.url }
            .sorted { $0.timestamp > $1.timestamp }
            .first
    }
    
    // MARK: - Helper 메서드들
    
    private func findStateModel(for tabID: UUID) -> WebViewStateModel? {
        // 실제 구현에서는 TabManager 등을 통해 조회
        return nil // placeholder
    }
    
    // MARK: - 기존 제스처 시스템 (유지)
    
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
        
        dbg("✅ BFCache 제스처 설정 완료")
    }
    
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let ctx = objc_getAssociatedObject(gesture, "bfcache_ctx") as? WeakGestureContext,
              let stateModel = ctx.stateModel else { return }
        let webView = ctx.webView ?? (gesture.view as? WKWebView)
        guard let webView else { return }
        
        let tabID = ctx.tabID
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        let width = gesture.view?.bounds.width ?? 1
        
        let absX = abs(translation.x), absY = abs(translation.y)
        let horizontalEnough = absX > 8 && absX > absY
        let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
        
        switch gesture.state {
        case .began:
            guard activeTransitions[tabID] == nil else {
                gesture.state = .cancelled
                return
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                handleGestureBegan(tabID: tabID, webView: webView, stateModel: stateModel, direction: direction)
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
    
    private func handleGestureBegan(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection) {
        let currentIndex = stateModel.dataModel.currentPageIndex
        let pageHistory = stateModel.dataModel.pageHistory
        
        guard currentIndex >= 0 && currentIndex < pageHistory.count else { return }
        
        let targetIndex = direction == .back ? currentIndex - 1 : currentIndex + 1
        guard targetIndex >= 0 && targetIndex < pageHistory.count else { return }
        
        let targetRecord = pageHistory[targetIndex]
        
        // 현재 페이지 캡처 트리거 (DOM Observer가 처리)
        
        captureCurrentSnapshot(webView: webView) { [weak self] currentImage in
            self?.beginGestureTransition(
                tabID: tabID,
                webView: webView,
                stateModel: stateModel,
                direction: direction,
                currentSnapshot: currentImage,
                gestureStartIndex: currentIndex,
                targetPageRecord: targetRecord
            )
        }
    }
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = false
        
        webView.takeSnapshot(with: config) { image, error in
            completion(image)
        }
    }
    
    private func beginGestureTransition(
        tabID: UUID,
        webView: WKWebView,
        stateModel: WebViewStateModel,
        direction: NavigationDirection,
        currentSnapshot: UIImage?,
        gestureStartIndex: Int,
        targetPageRecord: PageRecord?
    ) {
        let previewContainer = createPreviewContainer(
            webView: webView,
            direction: direction,
            currentSnapshot: currentSnapshot,
            targetPageRecord: targetPageRecord,
            stateModel: stateModel
        )
        
        let context = TransitionContext(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            isGesture: true,
            direction: direction,
            initialTransform: webView.transform,
            previewContainer: previewContainer,
            currentSnapshot: currentSnapshot,
            gestureStartIndex: gestureStartIndex,
            targetPageRecord: targetPageRecord
        )
        
        activeTransitions[tabID] = context
    }
    
    private func createPreviewContainer(
        webView: WKWebView,
        direction: NavigationDirection,
        currentSnapshot: UIImage? = nil,
        targetPageRecord: PageRecord?,
        stateModel: WebViewStateModel
    ) -> UIView {
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
            currentView = UIView(frame: webView.bounds)
            currentView.backgroundColor = .systemBackground
        }
        
        currentView.frame = webView.bounds
        currentView.tag = 1001
        currentView.layer.shadowColor = UIColor.black.cgColor
        currentView.layer.shadowOpacity = 0.3
        currentView.layer.shadowOffset = CGSize(width: direction == .back ? -5 : 5, height: 0)
        currentView.layer.shadowRadius = 10
        
        container.addSubview(currentView)
        
        // 타겟 페이지 뷰
        var targetView: UIView
        
        if let record = targetPageRecord {
            // 스냅샷 찾기
            if let snapshot = findSnapshot(for: record),
               let visualSnapshot = snapshot.visualSnapshot,
               let imagePath = visualSnapshot.imagePath,
               let image = UIImage(contentsOfFile: imagePath) {
                let imageView = UIImageView(image: image)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
            } else {
                targetView = createInfoCard(for: record, in: webView.bounds)
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
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 180),
            
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
        
        return card
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
    
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer,
              let stateModel = context.stateModel else { return }
        
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
                // 네비게이션 수행
                switch context.direction {
                case .back:
                    stateModel.goBack()
                case .forward:
                    stateModel.goForward()
                }
                
                // 스크롤 복원 시도
                if let targetRecord = context.targetPageRecord,
                   let snapshot = self?.findSnapshot(for: targetRecord) {
                    self?.restoreScrollStates(snapshot.scrollStates, to: webView) { success in
                        self?.dbg("스크롤 복원 \(success ? "성공" : "실패")")
                    }
                }
                
                // 정리
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: tabID)
            }
        )
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
    
    // MARK: - 메모리 관리
    
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
            
            // 오래된 메모리 캐시 정리
            let beforeCount = self._memoryCache.count
            let sorted = self._memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 3  // 1/3만 제거
            
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            self.dbg("⚠️ 메모리 경고 - 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 디스크 저장 (placeholder)
    
    private func loadDiskCacheIndex() {
        // 실제 구현 필요
    }
    
    private func loadSiteProfiles() {
        if let data = UserDefaults.standard.data(forKey: "BFCache.SiteProfiles"),
           let profiles = try? JSONDecoder().decode([String: SiteProfile].self, from: data) {
            cacheAccessQueue.async(flags: .barrier) {
                self._siteProfiles = profiles
            }
        }
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[\(ts())][BFCache] \(msg)")
    }
}

// MARK: - WKScriptMessageHandler
extension BFCacheTransitionSystem: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        
        // TabID 찾기 (실제 구현에서는 메시지나 웹뷰에서 추출)
        guard let webView = message.webView,
              let tabID = findTabID(for: webView) else { return }
        
        switch message.name {
        case "domChange":
            handleContentChange(tabID: tabID, changeInfo: body)
            
        case "scrollChange":
            // 스크롤만 변경된 경우 더 가벼운 처리
            if let scrollStates = body["scrollStates"] as? [[String: Any]] {
                updateScrollStatesOnly(tabID: tabID, scrollStates: scrollStates)
            }
            
        default:
            break
        }
    }
    
    private func findTabID(for webView: WKWebView) -> UUID? {
        // 실제 구현에서는 웹뷰와 연관된 TabID 조회
        return nil // placeholder
    }
    
    private func updateScrollStatesOnly(tabID: UUID, scrollStates: [[String: Any]]) {
        // 스크롤 상태만 업데이트 (비주얼 캡처 없이)
        let parsedStates = parseScrollStates(from: ["scrollStates": scrollStates])
        
        // 최신 스냅샷 업데이트
        if let lastHash = _lastContentHash[tabID],
           var snapshot = cacheAccessQueue.sync(execute: { _memoryCache[lastHash] }) {
            // 스크롤 상태만 업데이트
            var updatedSnapshot = snapshot
            updatedSnapshot.scrollStates = parsedStates
            storeSnapshot(updatedSnapshot, contentHash: lastHash)
        }
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
    
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        // DOM Observer 설치
        shared.installDOMObserver(webView: webView, stateModel: stateModel)
        
        // 제스처 설치
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ 범용 SPA 최적화 BFCache 시스템 설치 완료")
    }
    
    static func uninstall(from webView: WKWebView, tabID: UUID) {
        // DOM Observer 제거
        shared.removeDOMObserver(tabID: tabID, webView: webView)
        
        // 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        TabPersistenceManager.debugMessages.append("🧹 BFCache 시스템 제거 완료")
    }
    
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
    
    private func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let webView = stateModel.webView else { return }
        
        stateModel.goBack()
        
        // 스크롤 복원
        if let currentRecord = stateModel.currentPageRecord,
           let snapshot = findSnapshot(for: currentRecord) {
            restoreScrollStates(snapshot.scrollStates, to: webView) { _ in }
        }
    }
    
    private func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let webView = stateModel.webView else { return }
        
        stateModel.goForward()
        
        // 스크롤 복원
        if let currentRecord = stateModel.currentPageRecord,
           let snapshot = findSnapshot(for: currentRecord) {
            restoreScrollStates(snapshot.scrollStates, to: webView) { _ in }
        }
    }
}
