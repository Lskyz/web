//
//  BFCacheSwipeTransition.swift
//  🎯 **5가지 스크롤 복원 전략 적용 BFCache 전환 시스템**
//  ✅ 직렬화 큐로 레이스 컨디션 완전 제거
//  🔄 원자적 연산으로 데이터 일관성 보장
//  📸 실패 복구 메커니즘 추가
//  ♾️ 무제한 영구 캐싱 (탭별 관리)
//  💾 스마트 메모리 관리
//  🔧 **StateModel과 완벽 동기화**
//  🎬 **미리보기 컨테이너 타이밍 개선** - 복원 완료 후 제거
//  ⚡ **균형 잡힌 전환 속도 최적화 - 깜빡임 방지**
//  🛡️ **빠른 연속 제스처 먹통 방지** - 전환 중 차단 + 강제 정리
//  🚫 **폼데이터/눌린상태 저장 제거** - 부작용 해결
//  🔍 **5가지 스크롤 복원 전략 적용**
//  📊 **사이트 타입별 최적화된 복원**
//  🛡️ **안전한 캐시 시스템** - 크래시 방지 강화

import UIKit
import WebKit
import SwiftUI

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 🛡️ 안전한 CGPoint 래퍼 (Codable 확장 제거)
struct SafeCGPoint: Codable {
    let x: Double
    let y: Double
    
    init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }
    
    var cgPoint: CGPoint {
        return CGPoint(x: x, y: y)
    }
    
    static let zero = SafeCGPoint(CGPoint.zero)
}

// MARK: - 사이트 타입 정의
enum SiteType: String, Codable, CaseIterable {
    case staticSite = "static"          // 1) 정적 데이터 - 기본 스크롤 위치만
    case dynamicSite = "dynamic"        // 2) 동적 데이터 - 보이는 아이템 정보 필요
    case lazyLoading = "lazy"           // 3) 레이지 로딩 - 배치 로딩 + 스켈레톤
    case reactQuery = "query"           // 4) React Query - 캐싱 활용
    case virtualized = "virtual"        // 5) 가상화 - sequence 기반
}

// MARK: - 🛡️ 안전한 데이터 구조체들

struct SafeVisibleItemInfo: Codable {
    let id: String
    let offsetTop: Double
    let height: Double
    let selector: String
    let index: Int?
    
    init(id: String, offsetTop: Double, height: Double, selector: String, index: Int? = nil) {
        self.id = id
        self.offsetTop = offsetTop
        self.height = height
        self.selector = selector
        self.index = index
    }
}

struct SafeSkeletonInfo: Codable {
    let averageItemHeight: Double
    let totalEstimatedHeight: Double
    let loadedItemCount: Int
    let estimatedTotalItems: Int
    
    init(averageItemHeight: Double, totalEstimatedHeight: Double, loadedItemCount: Int, estimatedTotalItems: Int) {
        self.averageItemHeight = averageItemHeight
        self.totalEstimatedHeight = totalEstimatedHeight
        self.loadedItemCount = loadedItemCount
        self.estimatedTotalItems = estimatedTotalItems
    }
}

struct SafeVisibleRange: Codable {
    let start: Int
    let end: Int
    
    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

struct SafeVirtualizedInfo: Codable {
    let sequence: Int
    let pageNumber: Int
    let pageSize: Int
    let totalItems: Int?
    let visibleRange: SafeVisibleRange
    
    init(sequence: Int, pageNumber: Int, pageSize: Int, totalItems: Int? = nil, visibleRange: SafeVisibleRange) {
        self.sequence = sequence
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.totalItems = totalItems
        self.visibleRange = visibleRange
    }
}

// MARK: - 🛡️ 완전히 안전한 JS 상태 정보
struct SafeJSState: Codable {
    let stringValues: [String: String]
    let numberValues: [String: Double]
    let boolValues: [String: Bool]
    let timestamp: Date
    
    init() {
        self.stringValues = [:]
        self.numberValues = [:]
        self.boolValues = [:]
        self.timestamp = Date()
    }
    
    init(from unsafeState: [String: Any]?) {
        guard let unsafeState = unsafeState else {
            self.init()
            return
        }
        
        var strings: [String: String] = [:]
        var numbers: [String: Double] = [:]
        var bools: [String: Bool] = [:]
        
        for (key, value) in unsafeState {
            // 안전한 키 검증
            guard key.count < 100, key.allSatisfy({ $0.isASCII }) else { continue }
            
            switch value {
            case let stringValue as String where stringValue.count < 1000:
                strings[key] = stringValue
            case let numberValue as NSNumber:
                if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                    bools[key] = numberValue.boolValue
                } else {
                    let doubleValue = numberValue.doubleValue
                    if doubleValue.isFinite {
                        numbers[key] = doubleValue
                    }
                }
            case let doubleValue as Double where doubleValue.isFinite:
                numbers[key] = doubleValue
            case let intValue as Int:
                numbers[key] = Double(intValue)
            case let boolValue as Bool:
                bools[key] = boolValue
            default:
                continue
            }
        }
        
        self.stringValues = strings
        self.numberValues = numbers
        self.boolValues = bools
        self.timestamp = Date()
    }
    
    func toDictionary() -> [String: Any] {
        var result: [String: Any] = [:]
        result.merge(stringValues) { _, new in new }
        result.merge(numberValues) { _, new in new }
        result.merge(boolValues) { _, new in new }
        result["timestamp"] = timestamp
        return result
    }
}

// MARK: - 향상된 스크롤 상태 정보 (안전한 버전)
struct SafeScrollStateInfo: Codable {
    let scrollX: Double
    let scrollY: Double
    let visibleItems: [SafeVisibleItemInfo]
    let skeletonInfo: SafeSkeletonInfo?
    let virtualizedInfo: SafeVirtualizedInfo?
    let loadingStates: [String: Bool]
    let dataTimestamp: Date
    
    init(scrollX: Double = 0, scrollY: Double = 0, visibleItems: [SafeVisibleItemInfo] = [], 
         skeletonInfo: SafeSkeletonInfo? = nil, virtualizedInfo: SafeVirtualizedInfo? = nil, 
         loadingStates: [String: Bool] = [:]) {
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.visibleItems = visibleItems
        self.skeletonInfo = skeletonInfo
        self.virtualizedInfo = virtualizedInfo
        self.loadingStates = loadingStates
        self.dataTimestamp = Date()
    }
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

// MARK: - 📸 안전한 BFCache 페이지 스냅샷
struct SafeBFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: SafeCGPoint
    var safeJSState: SafeJSState?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    let siteType: SiteType
    let scrollStateInfo: SafeScrollStateInfo?
    
    enum CaptureStatus: String, Codable {
        case complete
        case partial
        case visualOnly
        case failed
    }
    
    init(
        pageRecord: PageRecord,
        domSnapshot: String? = nil,
        scrollPosition: CGPoint = .zero,
        jsState: [String: Any]? = nil,
        timestamp: Date = Date(),
        webViewSnapshotPath: String? = nil,
        captureStatus: CaptureStatus = .partial,
        version: Int = 1,
        siteType: SiteType = .staticSite,
        scrollStateInfo: SafeScrollStateInfo? = nil
    ) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = SafeCGPoint(scrollPosition)
        self.safeJSState = SafeJSState(from: jsState)
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.siteType = siteType
        self.scrollStateInfo = scrollStateInfo
    }
    
    var jsState: [String: Any]? {
        return safeJSState?.toDictionary()
    }
    
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath,
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return UIImage(contentsOfFile: path)
    }
    
    // MARK: - 🎯 **5가지 전략별 스크롤 복원 메서드**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.restore(to: webView, completion: completion)
            }
            return
        }
        
        TabPersistenceManager.debugMessages.append("🔄 \(siteType.rawValue) 전략으로 복원 시작: \(pageRecord.title)")
        
        switch siteType {
        case .staticSite:
            restoreStaticSite(to: webView, completion: completion)
        case .dynamicSite:
            restoreDynamicSite(to: webView, completion: completion)
        case .lazyLoading:
            restoreLazyLoading(to: webView, completion: completion)
        case .reactQuery:
            restoreReactQuery(to: webView, completion: completion)
        case .virtualized:
            restoreVirtualized(to: webView, completion: completion)
        }
    }
    
    // MARK: - 1️⃣ 정적 사이트 복원
    private func restoreStaticSite(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let targetPoint = scrollPosition.cgPoint
        
        webView.scrollView.setContentOffset(targetPoint, animated: false)
        
        let scrollJS = """
        (function() {
            try {
                if (window.scrollTo) {
                    window.scrollTo(\(targetPoint.x), \(targetPoint.y));
                }
                return true;
            } catch(e) { 
                console.error('정적 복원 오류:', e);
                return false; 
            }
        })()
        """
        
        webView.evaluateJavaScript(scrollJS) { result, error in
            let success = (result as? Bool) ?? false
            TabPersistenceManager.debugMessages.append("✅ 정적 사이트 복원: \(success ? "성공" : "실패")")
            completion(success)
        }
    }
    
    // MARK: - 2️⃣ 동적 사이트 복원
    private func restoreDynamicSite(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let scrollInfo = scrollStateInfo,
              !scrollInfo.visibleItems.isEmpty else {
            restoreStaticSite(to: webView, completion: completion)
            return
        }
        
        TabPersistenceManager.debugMessages.append("🔄 동적 사이트 복원: \(scrollInfo.visibleItems.count)개 아이템 기준")
        waitForDataLoadAndRestore(webView: webView, scrollInfo: scrollInfo, completion: completion)
    }
    
    private func waitForDataLoadAndRestore(webView: WKWebView, scrollInfo: SafeScrollStateInfo, completion: @escaping (Bool) -> Void) {
        let firstItems = Array(scrollInfo.visibleItems.prefix(3))
        guard let firstItem = firstItems.first else {
            restoreStaticSite(to: webView, completion: completion)
            return
        }
        
        let waitForDataScript = """
        (function() {
            return new Promise((resolve) => {
                const timeout = setTimeout(() => resolve({found: false}), 3000);
                
                const checkDataLoaded = () => {
                    try {
                        const loadingElements = document.querySelectorAll('.loading, .skeleton, [data-loading="true"]');
                        if (loadingElements.length > 0) {
                            setTimeout(checkDataLoaded, 100);
                            return;
                        }
                        
                        const element = document.querySelector('\(firstItem.selector.replacingOccurrences(of: "'", with: "\\'"))');
                        if (element) {
                            clearTimeout(timeout);
                            resolve({
                                found: true,
                                element: {
                                    offsetTop: element.offsetTop,
                                    selector: '\(firstItem.selector.replacingOccurrences(of: "'", with: "\\'"))'
                                }
                            });
                        } else {
                            setTimeout(checkDataLoaded, 100);
                        }
                    } catch(e) {
                        clearTimeout(timeout);
                        resolve({found: false, error: e.message});
                    }
                };
                
                checkDataLoaded();
            });
        })()
        """
        
        webView.evaluateJavaScript(waitForDataScript) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("⚠️ 동적 사이트 스크립트 오류: \(error.localizedDescription)")
                self.restoreStaticSite(to: webView, completion: completion)
                return
            }
            
            if let resultDict = result as? [String: Any],
               let found = resultDict["found"] as? Bool,
               found,
               let elementInfo = resultDict["element"] as? [String: Any] {
                self.restoreBasedOnItem(webView: webView, elementInfo: elementInfo, completion: completion)
            } else {
                TabPersistenceManager.debugMessages.append("⚠️ 동적 사이트 아이템 못찾음 - 기본 복원")
                self.restoreStaticSite(to: webView, completion: completion)
            }
        }
    }
    
    private func restoreBasedOnItem(webView: WKWebView, elementInfo: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let selector = elementInfo["selector"] as? String else {
            completion(false)
            return
        }
        
        let targetPoint = scrollPosition.cgPoint
        let restoreScript = """
        (function() {
            try {
                const element = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))');
                if (element && element.scrollIntoView) {
                    element.scrollIntoView({ block: 'start' });
                    setTimeout(() => {
                        if (window.scrollTo) {
                            window.scrollTo(\(targetPoint.x), \(targetPoint.y));
                        }
                    }, 50);
                    return true;
                }
                return false;
            } catch(e) { 
                console.error('아이템 복원 오류:', e);
                return false; 
            }
        })()
        """
        
        webView.evaluateJavaScript(restoreScript) { result, _ in
            let success = (result as? Bool) ?? false
            TabPersistenceManager.debugMessages.append("🎯 아이템 기준 복원: \(success ? "성공" : "실패")")
            completion(success)
        }
    }
    
    // MARK: - 3️⃣ 레이지 로딩 복원
    private func restoreLazyLoading(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let scrollInfo = scrollStateInfo,
              let skeletonInfo = scrollInfo.skeletonInfo else {
            restoreDynamicSite(to: webView, completion: completion)
            return
        }
        
        TabPersistenceManager.debugMessages.append("🔄 레이지 로딩 복원: 평균높이 \(skeletonInfo.averageItemHeight)")
        restoreWithPreloading(webView: webView, scrollInfo: scrollInfo, skeletonInfo: skeletonInfo, completion: completion)
    }
    
    private func restoreWithPreloading(webView: WKWebView, scrollInfo: SafeScrollStateInfo, skeletonInfo: SafeSkeletonInfo, completion: @escaping (Bool) -> Void) {
        let createSkeletonScript = """
        (function() {
            try {
                const container = document.querySelector('.content, main, #content, .list-container') || document.body;
                if (!container) return false;
                
                const existingContainer = document.querySelector('.bfcache-skeleton-container');
                if (existingContainer) existingContainer.remove();
                
                const skeletonContainer = document.createElement('div');
                skeletonContainer.className = 'bfcache-skeleton-container';
                skeletonContainer.style.cssText = 'height: \(skeletonInfo.totalEstimatedHeight)px; background: #f5f5f5;';
                
                const itemCount = Math.min(\(skeletonInfo.estimatedTotalItems), 100);
                for (let i = 0; i < itemCount; i++) {
                    const skeletonItem = document.createElement('div');
                    skeletonItem.className = 'bfcache-skeleton-item';
                    skeletonItem.style.cssText = 'height: \(skeletonInfo.averageItemHeight)px; margin-bottom: 10px; background-color: #e0e0e0; border-radius: 4px;';
                    skeletonContainer.appendChild(skeletonItem);
                }
                
                container.appendChild(skeletonContainer);
                return true;
            } catch(e) { 
                console.error('스켈레톤 생성 오류:', e);
                return false; 
            }
        })()
        """
        
        webView.evaluateJavaScript(createSkeletonScript) { result, _ in
            let skeletonCreated = (result as? Bool) ?? false
            
            if skeletonCreated {
                webView.scrollView.setContentOffset(self.scrollPosition.cgPoint, animated: false)
                self.waitForRealDataAndCleanup(webView: webView, completion: completion)
            } else {
                self.restoreDynamicSite(to: webView, completion: completion)
            }
        }
    }
    
    private func waitForRealDataAndCleanup(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let cleanupScript = """
        (function() {
            return new Promise((resolve) => {
                const startTime = Date.now();
                const timeout = 5000;
                
                const checkRealData = () => {
                    try {
                        const realContent = document.querySelectorAll('[data-item-id], .list-item, .content-item');
                        const skeletonContainer = document.querySelector('.bfcache-skeleton-container');
                        
                        if (realContent.length > 0 && skeletonContainer) {
                            skeletonContainer.remove();
                            resolve(true);
                        } else if (Date.now() - startTime > timeout) {
                            if (skeletonContainer) skeletonContainer.remove();
                            resolve(false);
                        } else {
                            setTimeout(checkRealData, 200);
                        }
                    } catch(e) {
                        const skeletonContainer = document.querySelector('.bfcache-skeleton-container');
                        if (skeletonContainer) skeletonContainer.remove();
                        resolve(false);
                    }
                };
                
                checkRealData();
            });
        })()
        """
        
        webView.evaluateJavaScript(cleanupScript) { result, _ in
            let success = (result as? Bool) ?? true
            TabPersistenceManager.debugMessages.append("🏗️ 레이지 로딩 복원 완료: \(success ? "성공" : "타임아웃")")
            completion(success)
        }
    }
    
    // MARK: - 4️⃣ React Query 복원
    private func restoreReactQuery(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let scrollInfo = scrollStateInfo else {
            restoreDynamicSite(to: webView, completion: completion)
            return
        }
        
        TabPersistenceManager.debugMessages.append("🔄 React Query 복원: 캐시 확인")
        restoreWithCacheCheck(webView: webView, scrollInfo: scrollInfo, completion: completion)
    }
    
    private func restoreWithCacheCheck(webView: WKWebView, scrollInfo: SafeScrollStateInfo, completion: @escaping (Bool) -> Void) {
        let cacheCheckScript = """
        (function() {
            try {
                const hasReactQueryCache = window.ReactQueryCache || 
                                         window.__reactQueryClient || 
                                         document.querySelector('[data-rq-cache]') ||
                                         window.queryClient;
                
                return { hasCachedData: !!hasReactQueryCache };
            } catch(e) {
                return { hasCachedData: false };
            }
        })()
        """
        
        webView.evaluateJavaScript(cacheCheckScript) { result, _ in
            if let resultDict = result as? [String: Any],
               let hasCachedData = resultDict["hasCachedData"] as? Bool {
                
                if hasCachedData {
                    TabPersistenceManager.debugMessages.append("⚡ React Query 캐시 히트 - 즉시 복원")
                    self.restoreStaticSite(to: webView, completion: completion)
                } else {
                    TabPersistenceManager.debugMessages.append("💿 React Query 캐시 미스 - 동적 복원")
                    self.restoreDynamicSite(to: webView, completion: completion)
                }
            } else {
                self.restoreDynamicSite(to: webView, completion: completion)
            }
        }
    }
    
    // MARK: - 5️⃣ 가상화 복원
    private func restoreVirtualized(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let scrollInfo = scrollStateInfo,
              let virtualInfo = scrollInfo.virtualizedInfo else {
            restoreDynamicSite(to: webView, completion: completion)
            return
        }
        
        TabPersistenceManager.debugMessages.append("🔄 가상화 복원: sequence \(virtualInfo.sequence)")
        restoreVirtualizedList(webView: webView, virtualInfo: virtualInfo, completion: completion)
    }
    
    private func restoreVirtualizedList(webView: WKWebView, virtualInfo: SafeVirtualizedInfo, completion: @escaping (Bool) -> Void) {
        let virtualRestoreScript = """
        (function() {
            try {
                const virtualList = window.virtualList || 
                                  window.reactVirtualized || 
                                  window.virtuoso ||
                                  document.querySelector('[data-virtualized]');
                
                if (virtualList) {
                    const sequence = \(virtualInfo.sequence);
                    
                    if (virtualList.scrollToItem) {
                        virtualList.scrollToItem(sequence);
                        return true;
                    } else if (virtualList.scrollTo) {
                        virtualList.scrollTo(sequence);
                        return true;
                    } else if (window.virtuosoRef && window.virtuosoRef.current && window.virtuosoRef.current.scrollToIndex) {
                        window.virtuosoRef.current.scrollToIndex(sequence);
                        return true;
                    }
                }
                
                return false;
            } catch(e) {
                console.error('가상화 복원 실패:', e);
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(virtualRestoreScript) { result, _ in
            let success = (result as? Bool) ?? false
            
            if success {
                TabPersistenceManager.debugMessages.append("🎯 가상화 복원 성공")
                completion(true)
            } else {
                TabPersistenceManager.debugMessages.append("⚠️ 가상화 API 실패 - 일반 복원")
                self.restoreStaticSite(to: webView, completion: completion)
            }
        }
    }
}

// MARK: - 🎯 **안전한 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        initializeSystem()
    }
    
    // MARK: - 🛡️ 안전한 초기화
    private func initializeSystem() {
        // 메인 큐에서 초기화 보장
        if Thread.isMainThread {
            performSafeInitialization()
        } else {
            DispatchQueue.main.sync {
                performSafeInitialization()
            }
        }
    }
    
    private func performSafeInitialization() {
        setupMemoryWarningObserver()
        
        // 디스크 캐시 로드는 백그라운드에서 안전하게
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadDiskCacheIndexSafely()
        }
    }
    
    // MARK: - 📸 **핵심 개선: 단일 직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .utility)
    
    // MARK: - 💾 스레드 안전 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: SafeBFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
    // 스레드 안전 액세서
    private var memoryCache: [UUID: SafeBFCacheSnapshot] {
        get { cacheAccessQueue.sync { _memoryCache } }
    }
    
    private func setMemoryCache(_ snapshot: SafeBFCacheSnapshot, for pageID: UUID) {
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
    
    // MARK: - 📁 안전한 파일 시스템 경로
    private var bfCacheDirectory: URL? {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsPath.appendingPathComponent("BFCache", isDirectory: true)
    }
    
    private func tabDirectory(for tabID: UUID) -> URL? {
        guard let baseDir = bfCacheDirectory else { return nil }
        return baseDir.appendingPathComponent("Tab_\(tabID.uuidString)", isDirectory: true)
    }
    
    private func pageDirectory(for pageID: UUID, tabID: UUID, version: Int) -> URL? {
        guard let tabDir = tabDirectory(for: tabID) else { return nil }
        return tabDir.appendingPathComponent("Page_\(pageID.uuidString)_v\(version)", isDirectory: true)
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
        case immediate
        case background
    }
    
    // MARK: - 🎯 **안전한 사이트 타입 감지**
    
    private func detectSiteType(webView: WKWebView, completion: @escaping (SiteType) -> Void) {
        let detectionScript = generateSiteTypeDetectionScript()
        
        webView.evaluateJavaScript(detectionScript) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("⚠️ 사이트 타입 감지 실패: \(error.localizedDescription)")
                completion(.dynamicSite)
                return
            }
            
            if let resultDict = result as? [String: Any],
               let siteTypeString = resultDict["siteType"] as? String,
               let siteType = SiteType(rawValue: siteTypeString) {
                completion(siteType)
            } else {
                completion(.dynamicSite)
            }
        }
    }
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (안전성 최우선)**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    private var pendingCaptures: Set<UUID> = []
    private let pendingCapturesQueue = DispatchQueue(label: "bfcache.pending", attributes: .concurrent)
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 중복 캡처 방지 (스레드 안전)
        let isAlreadyPending = pendingCapturesQueue.sync {
            return pendingCaptures.contains(pageID)
        }
        
        guard !isAlreadyPending else {
            dbg("⏸️ 중복 캡처 방지: \(task.pageRecord.title)")
            return
        }
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 진행 중 표시 (스레드 안전)
        pendingCapturesQueue.async(flags: .barrier) { [weak self] in
            self?.pendingCaptures.insert(pageID)
        }
        
        dbg("🎯 5가지 전략 캡처 시작: \(task.pageRecord.title)")
        
        // 메인 스레드에서 웹뷰 상태 확인
        guard let captureData = DispatchQueue.main.sync(execute: { () -> CaptureData? in
            guard webView.window != nil,
                  !webView.bounds.isEmpty,
                  webView.url != nil else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }) else {
            pendingCapturesQueue.async(flags: .barrier) { [weak self] in
                self?.pendingCaptures.remove(pageID)
            }
            return
        }
        
        // 사이트 타입 감지 후 캡처
        detectSiteType(webView: webView) { [weak self] siteType in
            guard let self = self else {
                self?.pendingCapturesQueue.async(flags: .barrier) { [weak self] in
                    self?.pendingCaptures.remove(pageID)
                }
                return
            }
            
            // 사이트 타입별 캡처 수행
            let captureResult = self.performEnhancedCapture(
                pageRecord: task.pageRecord,
                webView: webView,
                captureData: captureData,
                siteType: siteType,
                retryCount: task.type == .immediate ? 1 : 0
            )
            
            // 캡처 완료 후 저장
            if let tabID = task.tabID {
                self.saveToDisk(snapshot: captureResult, tabID: tabID)
            } else {
                self.storeInMemory(captureResult.snapshot, for: pageID)
            }
            
            // 진행 중 해제
            self.pendingCapturesQueue.async(flags: .barrier) {
                self.pendingCaptures.remove(pageID)
            }
            
            self.dbg("✅ \(siteType.rawValue) 전략 캡처 완료: \(task.pageRecord.title)")
        }
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // MARK: - 🎯 **안전한 향상된 캡처**
    private func performEnhancedCapture(
        pageRecord: PageRecord,
        webView: WKWebView,
        captureData: CaptureData,
        siteType: SiteType,
        retryCount: Int = 0
    ) -> (snapshot: SafeBFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptEnhancedCapture(
                pageRecord: pageRecord,
                webView: webView,
                captureData: captureData,
                siteType: siteType
            )
            
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        return (SafeBFCacheSnapshot(
            pageRecord: pageRecord,
            scrollPosition: captureData.scrollPosition,
            captureStatus: .failed,
            siteType: siteType
        ), nil)
    }
    
    private func attemptEnhancedCapture(
        pageRecord: PageRecord,
        webView: WKWebView,
        captureData: CaptureData,
        siteType: SiteType
    ) -> (snapshot: SafeBFCacheSnapshot, image: UIImage?) {
        
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var scrollStateInfo: SafeScrollStateInfo? = nil
        
        let group = DispatchGroup()
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        group.enter()
        DispatchQueue.main.async {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                group.leave()
            }
        }
        
        // 2. 향상된 스크롤 상태 캡처
        group.enter()
        DispatchQueue.main.async {
            let scrollScript = self.generateEnhancedScrollCaptureScript(for: siteType)
            
            webView.evaluateJavaScript(scrollScript) { result, error in
                if let error = error {
                    self.dbg("⚠️ 스크롤 상태 캡처 실패: \(error.localizedDescription)")
                } else if let resultData = result as? [String: Any] {
                    scrollStateInfo = self.parseScrollStateInfo(from: resultData, siteType: siteType)
                    jsState = resultData
                }
                group.leave()
            }
        }
        
        // 3. DOM 캡처
        group.enter()
        DispatchQueue.main.async {
            let domScript = self.generateCleanDOMScript()
            
            webView.evaluateJavaScript(domScript) { result, error in
                if let error = error {
                    self.dbg("⚠️ DOM 캡처 실패: \(error.localizedDescription)")
                } else {
                    domSnapshot = result as? String
                }
                group.leave()
            }
        }
        
        // 타임아웃 적용
        let result = group.wait(timeout: .now() + 3)
        if result == .timedOut {
            dbg("⏰ 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = visualSnapshot ?? renderWebViewToImage(webView)
        }
        
        // 캡처 상태 결정
        let captureStatus: SafeBFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && scrollStateInfo != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = scrollStateInfo != nil ? .partial : .visualOnly
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
        
        let snapshot = SafeBFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            jsState: jsState,
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version,
            siteType: siteType,
            scrollStateInfo: scrollStateInfo
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // MARK: - 🎯 **안전한 사이트 타입 감지 스크립트**
    private func generateSiteTypeDetectionScript() -> String {
        return """
        (function() {
            try {
                const hasVirtualization = !!(window.reactVirtualized ||
                                           window.virtualList ||
                                           window.virtuoso ||
                                           document.querySelector('[data-virtualized], .react-virtualized, .virtuoso-container'));
                
                if (hasVirtualization) {
                    return { siteType: 'virtual' };
                }
                
                const hasReactQuery = !!(window.ReactQueryCache ||
                                        window.__reactQueryClient ||
                                        window.queryClient ||
                                        document.querySelector('[data-rq-cache]'));
                
                if (hasReactQuery) {
                    return { siteType: 'query' };
                }
                
                const hasInfiniteScroll = !!(document.querySelector('.infinite-scroll, [data-infinite], [data-lazy], .lazy-load') ||
                                           (window.IntersectionObserver && document.querySelectorAll('[data-item-id]').length > 50));
                
                if (hasInfiniteScroll) {
                    return { siteType: 'lazy' };
                }
                
                const hasAsyncContent = !!(document.querySelector('.loading, .skeleton, [data-loading]') ||
                                         window.fetch !== window.originalFetch ||
                                         document.querySelectorAll('[data-item-id]').length > 0);
                
                if (hasAsyncContent) {
                    return { siteType: 'dynamic' };
                }
                
                return { siteType: 'static' };
                
            } catch(e) {
                console.error('사이트 타입 감지 오류:', e);
                return { siteType: 'dynamic' };
            }
        })()
        """
    }
    
    // MARK: - 🎯 **안전한 향상된 스크롤 캡처 스크립트**
    private func generateEnhancedScrollCaptureScript(for siteType: SiteType) -> String {
        let baseScript = """
        (function() {
            try {
                const result = {
                    scrollX: window.scrollX || 0,
                    scrollY: window.scrollY || 0,
                    siteType: '\(siteType.rawValue)',
                    timestamp: Date.now(),
                    viewport: { 
                        width: window.innerWidth || 0, 
                        height: window.innerHeight || 0 
                    }
                };
        """
        
        let specificScript: String
        switch siteType {
        case .staticSite:
            specificScript = """
                result.static = { simpleScroll: true };
            """
            
        case .dynamicSite:
            specificScript = """
                result.visibleItems = [];
                const items = document.querySelectorAll('[data-item-id], .list-item, .content-item, article, .card');
                const viewportTop = window.scrollY || 0;
                const viewportBottom = viewportTop + (window.innerHeight || 0);
                
                items.forEach((item, index) => {
                    try {
                        const rect = item.getBoundingClientRect();
                        const absoluteTop = rect.top + (window.scrollY || 0);
                        
                        if (absoluteTop < viewportBottom && absoluteTop + rect.height > viewportTop) {
                            result.visibleItems.push({
                                id: item.getAttribute('data-item-id') || ('item-' + index),
                                selector: generateSelector(item),
                                offsetTop: absoluteTop,
                                height: rect.height,
                                index: index
                            });
                        }
                    } catch(e) {}
                });
                
                result.loadingStates = {};
                document.querySelectorAll('.loading, [data-loading]').forEach(el => {
                    try {
                        result.loadingStates[generateSelector(el)] = true;
                    } catch(e) {}
                });
            """
            
        case .lazyLoading:
            specificScript = """
                const allItems = document.querySelectorAll('[data-item-id], .list-item, .content-item');
                const heights = [];
                allItems.forEach(item => {
                    try {
                        const height = item.getBoundingClientRect().height;
                        if (height > 0) heights.push(height);
                    } catch(e) {}
                });
                
                const averageHeight = heights.length > 0 ? heights.reduce((a, b) => a + b) / heights.length : 200;
                
                result.skeletonInfo = {
                    averageItemHeight: averageHeight,
                    loadedItemCount: allItems.length,
                    totalEstimatedHeight: document.documentElement.scrollHeight || 0,
                    estimatedTotalItems: Math.ceil((document.documentElement.scrollHeight || 0) / averageHeight)
                };
                
                result.visibleItems = [];
                allItems.forEach((item, index) => {
                    try {
                        const rect = item.getBoundingClientRect();
                        if (rect.top < (window.innerHeight || 0) && rect.bottom > 0) {
                            result.visibleItems.push({
                                id: item.getAttribute('data-item-id') || ('lazy-' + index),
                                selector: generateSelector(item),
                                offsetTop: rect.top + (window.scrollY || 0),
                                height: rect.height,
                                index: index
                            });
                        }
                    } catch(e) {}
                });
            """
            
        case .reactQuery:
            specificScript = """
                result.cacheInfo = {
                    hasQueryClient: !!(window.queryClient || window.__reactQueryClient),
                    cacheKeys: [],
                    dataTimestamp: Date.now()
                };
                
                result.visibleItems = [];
                const items = document.querySelectorAll('[data-item-id], .list-item, .content-item');
                items.forEach((item, index) => {
                    try {
                        const rect = item.getBoundingClientRect();
                        if (rect.top < (window.innerHeight || 0) && rect.bottom > 0) {
                            result.visibleItems.push({
                                id: item.getAttribute('data-item-id') || ('query-' + index),
                                selector: generateSelector(item),
                                offsetTop: rect.top + (window.scrollY || 0),
                                height: rect.height,
                                index: index
                            });
                        }
                    } catch(e) {}
                });
            """
            
        case .virtualized:
            specificScript = """
                const virtualContainer = document.querySelector('.react-virtualized, .virtuoso-container, [data-virtualized]');
                const estimatedItemHeight = 50;
                
                if (virtualContainer) {
                    const scrollTop = virtualContainer.scrollTop || (window.scrollY || 0);
                    const estimatedSequence = Math.floor(scrollTop / estimatedItemHeight);
                    
                    result.virtualizedInfo = {
                        sequence: estimatedSequence,
                        pageNumber: Math.floor(estimatedSequence / 20),
                        pageSize: 20,
                        totalItems: null,
                        visibleRange: {
                            start: Math.max(0, estimatedSequence - 5),
                            end: estimatedSequence + 15
                        }
                    };
                }
                
                result.visibleItems = [];
                const renderedItems = document.querySelectorAll('[data-index], [data-item-index]');
                renderedItems.forEach(item => {
                    try {
                        const index = parseInt(item.getAttribute('data-index') || item.getAttribute('data-item-index'));
                        if (!isNaN(index)) {
                            const rect = item.getBoundingClientRect();
                            result.visibleItems.push({
                                id: 'virtual-' + index,
                                selector: generateSelector(item),
                                offsetTop: rect.top + (window.scrollY || 0),
                                height: rect.height,
                                index: index
                            });
                        }
                    } catch(e) {}
                });
            """
        }
        
        let utilScript = """
            function generateSelector(element) {
                try {
                    if (element.id && element.id.length < 50) return '#' + element.id;
                    if (element.className && typeof element.className === 'string') {
                        const classes = element.className.split(' ').filter(c => c && c.length < 30).slice(0, 2);
                        if (classes.length > 0) return '.' + classes.join('.');
                    }
                    const tag = element.tagName.toLowerCase();
                    const parent = element.parentElement;
                    if (parent) {
                        const siblings = Array.from(parent.children);
                        const index = siblings.indexOf(element);
                        return parent.tagName.toLowerCase() + ' > ' + tag + ':nth-child(' + (index + 1) + ')';
                    }
                    return tag;
                } catch(e) {
                    return 'body';
                }
            }
        """
        
        return baseScript + specificScript + utilScript + """
            return result;
        } catch(e) {
            console.error('스크롤 캡처 오류:', e);
            return {
                scrollX: window.scrollX || 0,
                scrollY: window.scrollY || 0,
                error: e.message,
                siteType: '\(siteType.rawValue)'
            };
        }
        })()
        """
    }
    
    private func generateCleanDOMScript() -> String {
        return """
        (function() {
            try {
                if (document.readyState !== 'complete') return null;
                
                document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(el => {
                    try {
                        const classesToRemove = Array.from(el.classList).filter(c => 
                            c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus')
                        );
                        el.classList.remove(...classesToRemove);
                    } catch(e) {}
                });
                
                document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(el => {
                    try {
                        el.blur();
                    } catch(e) {}
                });
                
                const html = document.documentElement.outerHTML;
                return html.length > 100000 ? html.substring(0, 100000) : html;
            } catch(e) { 
                console.error('DOM 캡처 오류:', e);
                return null; 
            }
        })()
        """
    }
    
    // MARK: - 📊 안전한 스크롤 상태 정보 파싱
    private func parseScrollStateInfo(from data: [String: Any], siteType: SiteType) -> SafeScrollStateInfo? {
        guard let scrollX = data["scrollX"] as? Double,
              let scrollY = data["scrollY"] as? Double else {
            dbg("⚠️ 스크롤 위치 파싱 실패")
            return nil
        }
        
        // 보이는 아이템 파싱 (안전한 처리)
        var visibleItems: [SafeVisibleItemInfo] = []
        if let itemsData = data["visibleItems"] as? [[String: Any]] {
            visibleItems = itemsData.compactMap { itemData in
                guard let id = itemData["id"] as? String,
                      let selector = itemData["selector"] as? String,
                      let offsetTop = itemData["offsetTop"] as? Double,
                      let height = itemData["height"] as? Double,
                      id.count < 100, selector.count < 200,
                      offsetTop.isFinite, height.isFinite, height > 0 else {
                    return nil
                }
                
                return SafeVisibleItemInfo(
                    id: id,
                    offsetTop: offsetTop,
                    height: height,
                    selector: selector,
                    index: itemData["index"] as? Int
                )
            }
        }
        
        // 스켈레톤 정보 파싱
        var skeletonInfo: SafeSkeletonInfo? = nil
        if let skeletonData = data["skeletonInfo"] as? [String: Any] {
            let averageHeight = skeletonData["averageItemHeight"] as? Double ?? 200
            let totalHeight = skeletonData["totalEstimatedHeight"] as? Double ?? 0
            let loadedCount = skeletonData["loadedItemCount"] as? Int ?? 0
            let estimatedTotal = skeletonData["estimatedTotalItems"] as? Int ?? 0
            
            if averageHeight.isFinite && averageHeight > 0 &&
               totalHeight.isFinite && totalHeight >= 0 {
                skeletonInfo = SafeSkeletonInfo(
                    averageItemHeight: averageHeight,
                    totalEstimatedHeight: totalHeight,
                    loadedItemCount: max(0, loadedCount),
                    estimatedTotalItems: max(0, estimatedTotal)
                )
            }
        }
        
        // 가상화 정보 파싱
        var virtualizedInfo: SafeVirtualizedInfo? = nil
        if let virtualData = data["virtualizedInfo"] as? [String: Any] {
            let sequence = virtualData["sequence"] as? Int ?? 0
            let pageNumber = virtualData["pageNumber"] as? Int ?? 0
            let pageSize = virtualData["pageSize"] as? Int ?? 20
            let totalItems = virtualData["totalItems"] as? Int
            
            let visibleRange: SafeVisibleRange
            if let rangeData = virtualData["visibleRange"] as? [String: Int] {
                let start = max(0, rangeData["start"] ?? 0)
                let end = max(start, rangeData["end"] ?? 0)
                visibleRange = SafeVisibleRange(start: start, end: end)
            } else {
                visibleRange = SafeVisibleRange(start: 0, end: 0)
            }
            
            virtualizedInfo = SafeVirtualizedInfo(
                sequence: max(0, sequence),
                pageNumber: max(0, pageNumber),
                pageSize: max(1, pageSize),
                totalItems: totalItems,
                visibleRange: visibleRange
            )
        }
        
        // 로딩 상태 파싱 (안전한 처리)
        var loadingStates: [String: Bool] = [:]
        if let statesData = data["loadingStates"] as? [String: Bool] {
            for (key, value) in statesData {
                if key.count < 200 {
                    loadingStates[key] = value
                }
            }
        }
        
        return SafeScrollStateInfo(
            scrollX: scrollX,
            scrollY: scrollY,
            visibleItems: visibleItems,
            skeletonInfo: skeletonInfo,
            virtualizedInfo: virtualizedInfo,
            loadingStates: loadingStates
        )
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync {
                return renderWebViewToImage(webView)
            }
        }
        
        guard !webView.bounds.isEmpty else { return nil }
        
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 **안전한 디스크 저장 시스템**
    
    private func saveToDisk(snapshot: (snapshot: SafeBFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            
            guard let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version) else {
                self.dbg("❌ 페이지 디렉토리 경로 생성 실패")
                return
            }
            
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // 이미지 저장
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    if self.safeWriteData(jpegData, to: imagePath, description: "이미지") {
                        finalSnapshot = SafeBFCacheSnapshot(
                            pageRecord: finalSnapshot.pageRecord,
                            domSnapshot: finalSnapshot.domSnapshot,
                            scrollPosition: finalSnapshot.scrollPosition.cgPoint,
                            jsState: finalSnapshot.jsState,
                            timestamp: finalSnapshot.timestamp,
                            webViewSnapshotPath: imagePath.path,
                            captureStatus: finalSnapshot.captureStatus,
                            version: finalSnapshot.version,
                            siteType: finalSnapshot.siteType,
                            scrollStateInfo: finalSnapshot.scrollStateInfo
                        )
                    }
                }
            }
            
            // 상태 데이터 저장
            let statePath = pageDir.appendingPathComponent("state.json")
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let stateData = try encoder.encode(finalSnapshot)
                
                if self.safeWriteData(stateData, to: statePath, description: "상태") {
                    self.setDiskIndex(pageDir.path, for: pageID)
                    self.setMemoryCache(finalSnapshot, for: pageID)
                }
            } catch {
                self.dbg("❌ JSON 인코딩 실패: \(error.localizedDescription)")
            }
            
            // 메타데이터 저장
            let metadata = CacheMetadata(
                pageID: pageID,
                tabID: tabID,
                version: version,
                timestamp: Date(),
                url: snapshot.snapshot.pageRecord.url.absoluteString,
                title: snapshot.snapshot.pageRecord.title,
                siteType: snapshot.snapshot.siteType.rawValue
            )
            
            let metadataPath = pageDir.appendingPathComponent("metadata.json")
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let metadataData = try encoder.encode(metadata)
                _ = self.safeWriteData(metadataData, to: metadataPath, description: "메타데이터")
            } catch {
                self.dbg("❌ 메타데이터 인코딩 실패: \(error.localizedDescription)")
            }
            
            self.dbg("💾 \(snapshot.snapshot.siteType.rawValue) 전략 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
            // 이전 버전 정리
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
        let siteType: String
    }
    
    private func safeWriteData(_ data: Data, to url: URL, description: String) -> Bool {
        do {
            let tempURL = url.appendingPathExtension("tmp")
            try data.write(to: tempURL)
            
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItem(at: url, withItemAt: tempURL, 
                                                     backupItemName: nil, options: [], 
                                                     resultingItemURL: nil)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
            
            dbg("💾 \(description) 저장 성공: \(url.lastPathComponent)")
            return true
        } catch {
            dbg("❌ \(description) 저장 실패: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url.appendingPathExtension("tmp"))
            return false
        }
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            } catch {
                dbg("❌ 디렉토리 생성 실패: \(error.localizedDescription)")
            }
        }
    }
    
    private func cleanupOldVersions(pageID: UUID, tabID: UUID, currentVersion: Int) {
        guard let tabDir = tabDirectory(for: tabID) else { return }
        let pagePrefix = "Page_\(pageID.uuidString)_v"
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil)
            let pageDirs = contents.filter { $0.lastPathComponent.hasPrefix(pagePrefix) }
                .sorted { url1, url2 in
                    let v1 = Int(url1.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    let v2 = Int(url2.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    return v1 > v2
                }
            
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
    
    // MARK: - 💾 **안전한 디스크 캐시 로딩**
    
    private func loadDiskCacheIndexSafely() {
        guard let bfCacheDir = bfCacheDirectory else {
            dbg("❌ BFCache 디렉토리 경로 생성 실패")
            return
        }
        
        createDirectoryIfNeeded(at: bfCacheDir)
        
        var loadedCount = 0
        
        do {
            let tabDirs = try FileManager.default.contentsOfDirectory(at: bfCacheDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            
            for tabDir in tabDirs {
                if tabDir.lastPathComponent.hasPrefix("Tab_") {
                    do {
                        let pageDirs = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        
                        for pageDir in pageDirs {
                            if pageDir.lastPathComponent.hasPrefix("Page_") {
                                let metadataPath = pageDir.appendingPathComponent("metadata.json")
                                
                                do {
                                    let data = try Data(contentsOf: metadataPath)
                                    let decoder = JSONDecoder()
                                    decoder.dateDecodingStrategy = .iso8601
                                    let metadata = try decoder.decode(CacheMetadata.self, from: data)
                                    
                                    setDiskIndex(pageDir.path, for: metadata.pageID)
                                    cacheAccessQueue.async(flags: .barrier) {
                                        self._cacheVersion[metadata.pageID] = metadata.version
                                    }
                                    loadedCount += 1
                                } catch {
                                    dbg("⚠️ 메타데이터 로드 실패: \(metadataPath.lastPathComponent)")
                                    try? FileManager.default.removeItem(at: pageDir)
                                }
                            }
                        }
                    } catch {
                        dbg("⚠️ 탭 디렉토리 스캔 실패: \(tabDir.lastPathComponent)")
                    }
                }
            }
            
            dbg("💾 디스크 캐시 인덱스 로드 완료: \(loadedCount)개 항목")
        } catch {
            dbg("❌ 디스크 캐시 로드 실패: \(error)")
        }
    }
    
    // MARK: - 🔍 **안전한 스냅샷 조회 시스템**
    
    private func retrieveSnapshot(for pageID: UUID) -> SafeBFCacheSnapshot? {
        // 메모리 캐시 확인
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title) (\(snapshot.siteType.rawValue))")
            return snapshot
        }
        
        // 디스크 캐시 확인
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            do {
                let data = try Data(contentsOf: statePath)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let snapshot = try decoder.decode(SafeBFCacheSnapshot.self, from: data)
                
                setMemoryCache(snapshot, for: pageID)
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title) (\(snapshot.siteType.rawValue))")
                return snapshot
            } catch {
                dbg("❌ 디스크 캐시 로드 실패: \(error.localizedDescription)")
                cacheAccessQueue.async(flags: .barrier) {
                    self._diskCacheIndex.removeValue(forKey: pageID)
                }
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: diskPath))
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
    func hasCache(for pageID: UUID) -> Bool {
        if cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) != nil {
            return true
        }
        
        if cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) != nil {
            return true
        }
        
        return false
    }
    
    // MARK: - 메모리 캐시 관리
    
    private func storeInMemory(_ snapshot: SafeBFCacheSnapshot, for pageID: UUID) {
        setMemoryCache(snapshot, for: pageID)
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) (\(snapshot.siteType.rawValue)) [v\(snapshot.version)]")
    }
    
    // MARK: - 🧹 **안전한 캐시 정리**
    
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
                self._cacheVersion.removeValue(forKey: pageID)
            }
        }
        
        diskIOQueue.async { [weak self] in
            guard let self = self,
                  let tabDir = self.tabDirectory(for: tabID) else { return }
            
            do {
                try FileManager.default.removeItem(at: tabDir)
                self.dbg("🗑️ 탭 캐시 완전 삭제: \(tabID.uuidString)")
            } catch {
                self.dbg("⚠️ 탭 캐시 삭제 실패: \(error)")
            }
        }
    }
    
    // 메모리 경고 처리
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
            
            self.dbg("⚠️ 메모리 경고 - 메모리 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🎯 **안전한 제스처 시스템**
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.setupGestures(for: webView, stateModel: stateModel)
            }
            return
        }
        
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
        
        dbg("BFCache 제스처 설정 완료")
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
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                if let existing = activeTransitions[tabID] {
                    existing.previewContainer?.removeFromSuperview()
                    activeTransitions.removeValue(forKey: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                }
                
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
    
    // MARK: - 🎯 **나머지 제스처/전환 로직 (안전성 강화)**
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.captureCurrentSnapshot(webView: webView, completion: completion)
            }
            return
        }
        
        let captureConfig = WKSnapshotConfiguration()
        captureConfig.rect = webView.bounds
        captureConfig.afterScreenUpdates = false
        
        webView.takeSnapshot(with: captureConfig) { image, error in
            if let error = error {
                self.dbg("📸 현재 페이지 스냅샷 실패: \(error.localizedDescription)")
                let fallbackImage = self.renderWebViewToImage(webView)
                completion(fallbackImage)
            } else {
                completion(image)
            }
        }
    }
    
    private func beginGestureTransitionWithSnapshot(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection, currentSnapshot: UIImage?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.beginGestureTransitionWithSnapshot(tabID: tabID, webView: webView, stateModel: stateModel, direction: direction, currentSnapshot: currentSnapshot)
            }
            return
        }
        
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
                dbg("📸 타겟 페이지 \(snapshot.siteType.rawValue) 스냅샷 사용: \(targetRecord.title)")
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
                self?.performNavigationWithStrategies(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    private func performNavigationWithStrategies(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        tryStrategicBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - BFCache \(success ? "성공" : "실패")")
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (1초 타임아웃)")
            }
        }
    }
    
    private func tryStrategicBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            dbg("🎯 \(snapshot.siteType.rawValue) 전략으로 BFCache 복원 시작")
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ \(snapshot.siteType.rawValue) 전략 BFCache 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ \(snapshot.siteType.rawValue) 전략 BFCache 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
    
    // MARK: - 버튼 네비게이션
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryStrategicBFCacheRestore(stateModel: stateModel, direction: .back) { _ in }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        tryStrategicBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in }
    }
    
    // MARK: - 스와이프 제스처 감지 처리
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가 (과거 점프 방지): \(url.absoluteString)")
    }
    
    // MARK: - JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        (function() {
            'use strict';
            
            try {
                window.addEventListener('pageshow', function(event) {
                    if (event.persisted) {
                        console.log('🔄 BFCache 페이지 복원');
                        
                        if (window.location.pathname.includes('/feed') ||
                            window.location.pathname.includes('/timeline') ||
                            window.location.hostname.includes('twitter') ||
                            window.location.hostname.includes('facebook')) {
                            if (window.refreshDynamicContent) {
                                try {
                                    window.refreshDynamicContent();
                                } catch(e) {
                                    console.error('Dynamic content refresh failed:', e);
                                }
                            }
                        }
                    }
                });
                
                window.addEventListener('pagehide', function(event) {
                    if (event.persisted) {
                        console.log('📸 BFCache 페이지 저장');
                    }
                });
                
            } catch(e) {
                console.error('BFCache script error:', e);
            }
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
    
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        shared.setupGestures(for: webView, stateModel: stateModel)
        TabPersistenceManager.debugMessages.append("✅ 5가지 전략 BFCache 시스템 설치 완료")
    }
    
    static func uninstall(from webView: WKWebView) {
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
}

// MARK: - 퍼블릭 래퍼
extension BFCacheTransitionSystem {

    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📸 떠나기 스냅샷 캡처 시작: \(rec.title)")
    }

    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
        if stateModel.dataModel.currentPageIndex > 0 {
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                if !hasCache(for: previousRecord.id) {
                    let metadataSnapshot = SafeBFCacheSnapshot(
                        pageRecord: previousRecord,
                        captureStatus: .failed,
                        siteType: .dynamicSite
                    )
                    
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
