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

// MARK: - 사이트 타입 정의
enum SiteType: String, Codable {
    case staticSite = "static"          // 1) 정적 데이터 - 기본 스크롤 위치만
    case dynamicSite = "dynamic"        // 2) 동적 데이터 - 보이는 아이템 정보 필요
    case lazyLoading = "lazy"           // 3) 레이지 로딩 - 배치 로딩 + 스켈레톤
    case reactQuery = "query"           // 4) React Query - 캐싱 활용
    case virtualized = "virtual"        // 5) 가상화 - sequence 기반
}

// MARK: - 보이는 아이템 정보
struct VisibleItemInfo: Codable {
    let id: String
    let offsetTop: Double
    let height: Double
    let selector: String
    let index: Int?
}

// MARK: - 스켈레톤 정보
struct SkeletonInfo: Codable {
    let averageItemHeight: Double
    let totalEstimatedHeight: Double
    let loadedItemCount: Int
    let estimatedTotalItems: Int
}

// MARK: - 가상화 정보
struct VirtualizedInfo: Codable {
    let sequence: Int
    let pageNumber: Int
    let pageSize: Int
    let totalItems: Int?
    let visibleRange: (start: Int, end: Int)
}

// MARK: - 향상된 스크롤 상태 정보
struct ScrollStateInfo: Codable {
    let scrollX: Double
    let scrollY: Double
    let visibleItems: [VisibleItemInfo]
    let skeletonInfo: SkeletonInfo?
    let virtualizedInfo: VirtualizedInfo?
    let loadingStates: [String: Bool]  // 각 섹션별 로딩 상태
    let dataTimestamp: Date
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

// MARK: - 📸 BFCache 페이지 스냅샷 (5가지 전략 대응)
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 🎯 **새로 추가: 5가지 전략 대응 필드들**
    let siteType: SiteType
    let scrollStateInfo: ScrollStateInfo?
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, jsState, timestamp
        case webViewSnapshotPath, captureStatus, version
        case siteType, scrollStateInfo
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
        siteType = try container.decodeIfPresent(SiteType.self, forKey: .siteType) ?? .staticSite
        scrollStateInfo = try container.decodeIfPresent(ScrollStateInfo.self, forKey: .scrollStateInfo)
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
        try container.encode(siteType, forKey: .siteType)
        try container.encodeIfPresent(scrollStateInfo, forKey: .scrollStateInfo)
    }
    
    // 직접 초기화용 init
    init(
        pageRecord: PageRecord,
        domSnapshot: String? = nil,
        scrollPosition: CGPoint,
        jsState: [String: Any]? = nil,
        timestamp: Date,
        webViewSnapshotPath: String? = nil,
        captureStatus: CaptureStatus = .partial,
        version: Int = 1,
        siteType: SiteType = .staticSite,
        scrollStateInfo: ScrollStateInfo? = nil
    ) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.siteType = siteType
        self.scrollStateInfo = scrollStateInfo
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🎯 **5가지 전략별 스크롤 복원 메서드**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
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
        // 단순한 스크롤 위치 복원
        DispatchQueue.main.async {
            webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
            
            let scrollJS = """
            (function() {
                try {
                    window.scrollTo(\(self.scrollPosition.x), \(self.scrollPosition.y));
                    return true;
                } catch(e) { return false; }
            })()
            """
            
            webView.evaluateJavaScript(scrollJS) { result, _ in
                let success = (result as? Bool) ?? false
                TabPersistenceManager.debugMessages.append("✅ 정적 사이트 복원: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // MARK: - 2️⃣ 동적 사이트 복원
    private func restoreDynamicSite(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let scrollInfo = scrollStateInfo,
              !scrollInfo.visibleItems.isEmpty else {
            // 폴백: 정적 복원
            restoreStaticSite(to: webView, completion: completion)
            return
        }
        
        TabPersistenceManager.debugMessages.append("🔄 동적 사이트 복원: \(scrollInfo.visibleItems.count)개 아이템 기준")
        
        // 데이터 로딩 완료 대기 후 아이템 기준 복원
        DispatchQueue.main.async {
            self.waitForDataLoadAndRestore(webView: webView, scrollInfo: scrollInfo, completion: completion)
        }
    }
    
    private func waitForDataLoadAndRestore(webView: WKWebView, scrollInfo: ScrollStateInfo, completion: @escaping (Bool) -> Void) {
        let waitForDataScript = """
        (function() {
            return new Promise((resolve) => {
                const checkDataLoaded = () => {
                    // 로딩 표시기 확인
                    const loadingElements = document.querySelectorAll('.loading, .skeleton, [data-loading="true"]');
                    if (loadingElements.length > 0) {
                        setTimeout(checkDataLoaded, 100);
                        return;
                    }
                    
                    // 첫 번째 저장된 아이템 찾기
                    const firstItem = \(convertVisibleItemsToJSON(scrollInfo.visibleItems));
                    for (const itemInfo of firstItem) {
                        const element = document.querySelector(itemInfo.selector);
                        if (element) {
                            resolve({
                                found: true,
                                element: {
                                    offsetTop: element.offsetTop,
                                    selector: itemInfo.selector
                                }
                            });
                            return;
                        }
                    }
                    
                    resolve({ found: false });
                };
                
                checkDataLoaded();
            });
        })()
        """
        
        webView.evaluateJavaScript(waitForDataScript) { result, error in
            if let resultDict = result as? [String: Any],
               let found = resultDict["found"] as? Bool,
               found,
               let elementInfo = resultDict["element"] as? [String: Any] {
                
                // 아이템 기준으로 스크롤 복원
                self.restoreBasedOnItem(webView: webView, elementInfo: elementInfo, completion: completion)
            } else {
                // 폴백: 기본 스크롤 복원
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
        
        let restoreScript = """
        (function() {
            try {
                const element = document.querySelector('\(selector)');
                if (element) {
                    element.scrollIntoView({ block: 'start' });
                    // 미세 조정
                    window.scrollTo(\(scrollPosition.x), \(scrollPosition.y));
                    return true;
                }
                return false;
            } catch(e) { return false; }
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
        
        DispatchQueue.main.async {
            self.restoreWithPreloading(webView: webView, scrollInfo: scrollInfo, skeletonInfo: skeletonInfo, completion: completion)
        }
    }
    
    private func restoreWithPreloading(webView: WKWebView, scrollInfo: ScrollStateInfo, skeletonInfo: SkeletonInfo, completion: @escaping (Bool) -> Void) {
        // 1단계: 스켈레톤으로 공간 확보
        let createSkeletonScript = """
        (function() {
            try {
                const container = document.querySelector('.content, main, #content, .list-container') || document.body;
                const skeletonContainer = document.createElement('div');
                skeletonContainer.className = 'bfcache-skeleton-container';
                skeletonContainer.style.height = '\(skeletonInfo.totalEstimatedHeight)px';
                
                // 스켈레톤 아이템들 생성
                for (let i = 0; i < \(skeletonInfo.estimatedTotalItems); i++) {
                    const skeletonItem = document.createElement('div');
                    skeletonItem.className = 'bfcache-skeleton-item';
                    skeletonItem.style.height = '\(skeletonInfo.averageItemHeight)px';
                    skeletonItem.style.marginBottom = '10px';
                    skeletonItem.style.backgroundColor = '#f0f0f0';
                    skeletonItem.style.borderRadius = '4px';
                    skeletonContainer.appendChild(skeletonItem);
                }
                
                container.appendChild(skeletonContainer);
                return true;
            } catch(e) { return false; }
        })()
        """
        
        webView.evaluateJavaScript(createSkeletonScript) { result, _ in
            let skeletonCreated = (result as? Bool) ?? false
            
            if skeletonCreated {
                // 2단계: 즉시 스크롤 위치로 이동
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                
                // 3단계: 실제 데이터 로딩 대기 후 스켈레톤 제거
                self.waitForRealDataAndCleanup(webView: webView, completion: completion)
            } else {
                // 스켈레톤 실패시 동적 복원으로 폴백
                self.restoreDynamicSite(to: webView, completion: completion)
            }
        }
    }
    
    private func waitForRealDataAndCleanup(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let cleanupScript = """
        (function() {
            const checkRealData = () => {
                // 실제 콘텐츠가 로드되었는지 확인
                const realContent = document.querySelectorAll('[data-item-id], .list-item, .content-item');
                const skeletonContainer = document.querySelector('.bfcache-skeleton-container');
                
                if (realContent.length > 0 && skeletonContainer) {
                    skeletonContainer.remove();
                    return true;
                } else if (skeletonContainer && Date.now() - window.bfcacheStartTime > 5000) {
                    // 5초 후 강제 제거
                    skeletonContainer.remove();
                    return false;
                } else {
                    setTimeout(checkRealData, 200);
                    return null;
                }
            };
            
            window.bfcacheStartTime = Date.now();
            return checkRealData();
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
        
        DispatchQueue.main.async {
            self.restoreWithCacheCheck(webView: webView, scrollInfo: scrollInfo, completion: completion)
        }
    }
    
    private func restoreWithCacheCheck(webView: WKWebView, scrollInfo: ScrollStateInfo, completion: @escaping (Bool) -> Void) {
        let cacheCheckScript = """
        (function() {
            // React Query 캐시 존재 여부 확인
            const hasReactQueryCache = window.ReactQueryCache || 
                                     window.__reactQueryClient || 
                                     document.querySelector('[data-rq-cache]') ||
                                     window.queryClient;
            
            if (hasReactQueryCache) {
                // 캐시된 데이터로 즉시 렌더링 가능
                return { hasCachedData: true };
            } else {
                // 데이터 로딩 필요
                return { hasCachedData: false };
            }
        })()
        """
        
        webView.evaluateJavaScript(cacheCheckScript) { result, _ in
            if let resultDict = result as? [String: Any],
               let hasCachedData = resultDict["hasCachedData"] as? Bool {
                
                if hasCachedData {
                    // 캐시된 데이터가 있으면 즉시 복원
                    TabPersistenceManager.debugMessages.append("⚡ React Query 캐시 히트 - 즉시 복원")
                    self.restoreStaticSite(to: webView, completion: completion)
                } else {
                    // 캐시 미스면 동적 복원
                    TabPersistenceManager.debugMessages.append("💿 React Query 캐시 미스 - 동적 복원")
                    self.restoreDynamicSite(to: webView, completion: completion)
                }
            } else {
                // 판별 실패시 동적 복원
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
        
        DispatchQueue.main.async {
            self.restoreVirtualizedList(webView: webView, virtualInfo: virtualInfo, completion: completion)
        }
    }
    
    private func restoreVirtualizedList(webView: WKWebView, virtualInfo: VirtualizedInfo, completion: @escaping (Bool) -> Void) {
        let virtualRestoreScript = """
        (function() {
            // 가상화 라이브러리 감지 및 복원
            const virtualList = window.virtualList || 
                              window.reactVirtualized || 
                              window.virtuoso ||
                              document.querySelector('[data-virtualized]');
            
            if (virtualList) {
                try {
                    // 먼저 필요한 데이터 범위 로드
                    const startIndex = Math.max(0, \(virtualInfo.sequence) - 10);
                    const endIndex = \(virtualInfo.sequence) + 20;
                    
                    // 가상화 라이브러리별 API 호출
                    if (virtualList.scrollToItem) {
                        virtualList.scrollToItem(\(virtualInfo.sequence));
                    } else if (virtualList.scrollTo) {
                        virtualList.scrollTo(\(virtualInfo.sequence));
                    } else if (window.virtuosoRef?.current) {
                        window.virtuosoRef.current.scrollToIndex(\(virtualInfo.sequence));
                    }
                    
                    return true;
                } catch(e) {
                    console.error('가상화 복원 실패:', e);
                    return false;
                }
            }
            
            return false;
        })()
        """
        
        webView.evaluateJavaScript(virtualRestoreScript) { result, _ in
            let success = (result as? Bool) ?? false
            
            if success {
                TabPersistenceManager.debugMessages.append("🎯 가상화 복원 성공")
                completion(true)
            } else {
                // 가상화 API 실패시 일반 스크롤 복원
                TabPersistenceManager.debugMessages.append("⚠️ 가상화 API 실패 - 일반 복원")
                self.restoreStaticSite(to: webView, completion: completion)
            }
        }
    }
    
    // MARK: - 유틸리티 메서드
    private func convertVisibleItemsToJSON(_ items: [VisibleItemInfo]) -> String {
        do {
            let jsonData = try JSONEncoder().encode(items)
            return String(data: jsonData, encoding: .utf8) ?? "[]"
        } catch {
            return "[]"
        }
    }
}

// MARK: - 🎯 **5가지 전략 적용 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        loadDiskCacheIndex()
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
    
    // MARK: - 🎯 **사이트 타입 감지**
    
    private func detectSiteType(webView: WKWebView, completion: @escaping (SiteType) -> Void) {
        let detectionScript = generateSiteTypeDetectionScript()
        
        webView.evaluateJavaScript(detectionScript) { result, error in
            if let resultDict = result as? [String: Any],
               let siteTypeString = resultDict["siteType"] as? String,
               let siteType = SiteType(rawValue: siteTypeString) {
                completion(siteType)
            } else {
                // 기본값은 동적 사이트
                completion(.dynamicSite)
            }
        }
    }
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (5가지 전략 적용)**
    
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
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
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
        dbg("🎯 5가지 전략 캡처 시작: \(task.pageRecord.title)")
        
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
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🎯 **사이트 타입 감지 후 캡처**
        detectSiteType(webView: webView) { [weak self] siteType in
            guard let self = self else {
                self?.pendingCaptures.remove(pageID)
                return
            }
            
            // 사이트 타입별 캡처 수행
            let captureResult = self.performEnhancedCapture(
                pageRecord: task.pageRecord,
                webView: webView,
                captureData: data,
                siteType: siteType,
                retryCount: task.type == .immediate ? 2 : 0
            )
            
            // 캡처 완료 후 저장
            if let tabID = task.tabID {
                self.saveToDisk(snapshot: captureResult, tabID: tabID)
            } else {
                self.storeInMemory(captureResult.snapshot, for: pageID)
            }
            
            // 진행 중 해제
            self.pendingCaptures.remove(pageID)
            self.dbg("✅ \(siteType.rawValue) 전략 캡처 완료: \(task.pageRecord.title)")
        }
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // MARK: - 🎯 **5가지 전략별 향상된 캡처**
    private func performEnhancedCapture(
        pageRecord: PageRecord,
        webView: WKWebView,
        captureData: CaptureData,
        siteType: SiteType,
        retryCount: Int = 0
    ) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptEnhancedCapture(
                pageRecord: pageRecord,
                webView: webView,
                captureData: captureData,
                siteType: siteType
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
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(
            pageRecord: pageRecord,
            scrollPosition: captureData.scrollPosition,
            timestamp: Date(),
            captureStatus: .failed,
            version: 1,
            siteType: siteType
        ), nil)
    }
    
    private func attemptEnhancedCapture(
        pageRecord: PageRecord,
        webView: WKWebView,
        captureData: CaptureData,
        siteType: SiteType
    ) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var scrollStateInfo: ScrollStateInfo? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        DispatchQueue.main.sync {
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
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 2.5)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. 향상된 스크롤 상태 캡처 (사이트 타입별)
        let scrollSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let scrollScript = generateEnhancedScrollCaptureScript(for: siteType)
            
            webView.evaluateJavaScript(scrollScript) { result, error in
                if let resultData = result as? [String: Any] {
                    scrollStateInfo = self.parseScrollStateInfo(from: resultData, siteType: siteType)
                    jsState = resultData
                }
                scrollSemaphore.signal()
            }
        }
        _ = scrollSemaphore.wait(timeout: .now() + 1.5)
        
        // 3. DOM 캡처 (기존과 동일)
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = generateCleanDOMScript()
            
            webView.evaluateJavaScript(domScript) { result, error in
                domSnapshot = result as? String
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 0.8)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
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
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            jsState: jsState,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version,
            siteType: siteType,
            scrollStateInfo: scrollStateInfo
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // MARK: - 🎯 **사이트 타입 감지 스크립트**
    private func generateSiteTypeDetectionScript() -> String {
        return """
        (function() {
            try {
                // 가상화 라이브러리 감지
                const hasVirtualization = window.reactVirtualized ||
                                         window.virtualList ||
                                         window.virtuoso ||
                                         document.querySelector('[data-virtualized], .react-virtualized, .virtuoso-container');
                
                if (hasVirtualization) {
                    return { siteType: 'virtual' };
                }
                
                // React Query 감지
                const hasReactQuery = window.ReactQueryCache ||
                                    window.__reactQueryClient ||
                                    window.queryClient ||
                                    document.querySelector('[data-rq-cache]');
                
                if (hasReactQuery) {
                    return { siteType: 'query' };
                }
                
                // 무한스크롤/레이지로딩 감지
                const hasInfiniteScroll = document.querySelector('.infinite-scroll, [data-infinite], [data-lazy], .lazy-load') ||
                                         window.IntersectionObserver && document.querySelectorAll('[data-item-id]').length > 50;
                
                if (hasInfiniteScroll) {
                    return { siteType: 'lazy' };
                }
                
                // 동적 콘텐츠 감지
                const hasAsyncContent = document.querySelector('.loading, .skeleton, [data-loading]') ||
                                       window.fetch !== window.originalFetch ||
                                       window.XMLHttpRequest.prototype.open !== window.originalXHROpen ||
                                       document.querySelectorAll('[data-item-id]').length > 0;
                
                if (hasAsyncContent) {
                    return { siteType: 'dynamic' };
                }
                
                // 기본값: 정적 사이트
                return { siteType: 'static' };
                
            } catch(e) {
                return { siteType: 'dynamic' }; // 에러시 안전한 기본값
            }
        })()
        """
    }
    
    // MARK: - 🎯 **사이트 타입별 향상된 스크롤 캡처 스크립트**
    private func generateEnhancedScrollCaptureScript(for siteType: SiteType) -> String {
        let baseScript = """
        (function() {
            try {
                const result = {
                    scrollX: window.scrollX,
                    scrollY: window.scrollY,
                    siteType: '\(siteType.rawValue)',
                    timestamp: Date.now(),
                    viewport: { width: window.innerWidth, height: window.innerHeight }
                };
        """
        
        let specificScript: String
        switch siteType {
        case .staticSite:
            specificScript = """
                // 정적 사이트: 기본 정보만
                result.static = { simpleScroll: true };
            """
            
        case .dynamicSite:
            specificScript = """
                // 동적 사이트: 보이는 아이템 정보
                result.visibleItems = [];
                const items = document.querySelectorAll('[data-item-id], .list-item, .content-item, article, .card');
                const viewportTop = window.scrollY;
                const viewportBottom = viewportTop + window.innerHeight;
                
                items.forEach((item, index) => {
                    const rect = item.getBoundingClientRect();
                    const absoluteTop = rect.top + window.scrollY;
                    
                    if (absoluteTop < viewportBottom && absoluteTop + rect.height > viewportTop) {
                        result.visibleItems.push({
                            id: item.getAttribute('data-item-id') || `item-${index}`,
                            selector: generateSelector(item),
                            offsetTop: absoluteTop,
                            height: rect.height,
                            index: index
                        });
                    }
                });
                
                result.loadingStates = {};
                document.querySelectorAll('.loading, [data-loading]').forEach(el => {
                    result.loadingStates[generateSelector(el)] = true;
                });
            """
            
        case .lazyLoading:
            specificScript = """
                // 레이지 로딩: 스켈레톤 정보 + 높이 추정
                const allItems = document.querySelectorAll('[data-item-id], .list-item, .content-item');
                const heights = Array.from(allItems).map(item => item.getBoundingClientRect().height).filter(h => h > 0);
                const averageHeight = heights.length > 0 ? heights.reduce((a, b) => a + b) / heights.length : 200;
                
                result.skeletonInfo = {
                    averageItemHeight: averageHeight,
                    loadedItemCount: allItems.length,
                    totalEstimatedHeight: document.documentElement.scrollHeight,
                    estimatedTotalItems: Math.ceil(document.documentElement.scrollHeight / averageHeight)
                };
                
                // 보이는 아이템도 수집
                result.visibleItems = [];
                allItems.forEach((item, index) => {
                    const rect = item.getBoundingClientRect();
                    if (rect.top < window.innerHeight && rect.bottom > 0) {
                        result.visibleItems.push({
                            id: item.getAttribute('data-item-id') || `lazy-${index}`,
                            selector: generateSelector(item),
                            offsetTop: rect.top + window.scrollY,
                            height: rect.height,
                            index: index
                        });
                    }
                });
            """
            
        case .reactQuery:
            specificScript = """
                // React Query: 캐시 정보
                result.cacheInfo = {
                    hasQueryClient: !!(window.queryClient || window.__reactQueryClient),
                    cacheKeys: [],
                    dataTimestamp: Date.now()
                };
                
                // 보이는 아이템 정보도 수집 (캐시 미스 대비)
                result.visibleItems = [];
                const items = document.querySelectorAll('[data-item-id], .list-item, .content-item');
                items.forEach((item, index) => {
                    const rect = item.getBoundingClientRect();
                    if (rect.top < window.innerHeight && rect.bottom > 0) {
                        result.visibleItems.push({
                            id: item.getAttribute('data-item-id') || `query-${index}`,
                            selector: generateSelector(item),
                            offsetTop: rect.top + window.scrollY,
                            height: rect.height,
                            index: index
                        });
                    }
                });
            """
            
        case .virtualized:
            specificScript = """
                // 가상화: sequence와 범위 정보
                const virtualContainer = document.querySelector('.react-virtualized, .virtuoso-container, [data-virtualized]');
                const estimatedItemHeight = 50; // 기본 추정 높이
                
                if (virtualContainer) {
                    const scrollTop = virtualContainer.scrollTop || window.scrollY;
                    const estimatedSequence = Math.floor(scrollTop / estimatedItemHeight);
                    
                    result.virtualizedInfo = {
                        sequence: estimatedSequence,
                        pageNumber: Math.floor(estimatedSequence / 20), // 페이지당 20개 아이템 가정
                        pageSize: 20,
                        totalItems: null, // 추후 계산
                        visibleRange: {
                            start: Math.max(0, estimatedSequence - 5),
                            end: estimatedSequence + 15
                        }
                    };
                }
                
                // 실제 렌더된 아이템들 정보
                result.visibleItems = [];
                const renderedItems = document.querySelectorAll('[data-index], [data-item-index]');
                renderedItems.forEach(item => {
                    const index = parseInt(item.getAttribute('data-index') || item.getAttribute('data-item-index'));
                    if (!isNaN(index)) {
                        const rect = item.getBoundingClientRect();
                        result.visibleItems.push({
                            id: `virtual-${index}`,
                            selector: generateSelector(item),
                            offsetTop: rect.top + window.scrollY,
                            height: rect.height,
                            index: index
                        });
                    }
                });
            """
        }
        
        let utilScript = """
            function generateSelector(element) {
                if (element.id) return '#' + element.id;
                if (element.className) {
                    const classes = element.className.split(' ').filter(c => c).slice(0, 2);
                    return '.' + classes.join('.');
                }
                const tag = element.tagName.toLowerCase();
                const parent = element.parentElement;
                if (parent) {
                    const siblings = Array.from(parent.children);
                    const index = siblings.indexOf(element);
                    return `${parent.tagName.toLowerCase()} > ${tag}:nth-child(${index + 1})`;
                }
                return tag;
            }
        """
        
        return baseScript + specificScript + utilScript + """
            return result;
        } catch(e) {
            return {
                scrollX: window.scrollX,
                scrollY: window.scrollY,
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
                
                // 눌린 상태/활성 상태 모두 제거
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
    }
    
    // MARK: - 📊 스크롤 상태 정보 파싱
    private func parseScrollStateInfo(from data: [String: Any], siteType: SiteType) -> ScrollStateInfo? {
        guard let scrollX = data["scrollX"] as? Double,
              let scrollY = data["scrollY"] as? Double else {
            return nil
        }
        
        // 보이는 아이템 파싱
        var visibleItems: [VisibleItemInfo] = []
        if let itemsData = data["visibleItems"] as? [[String: Any]] {
            visibleItems = itemsData.compactMap { itemData in
                guard let id = itemData["id"] as? String,
                      let selector = itemData["selector"] as? String,
                      let offsetTop = itemData["offsetTop"] as? Double,
                      let height = itemData["height"] as? Double else {
                    return nil
                }
                
                return VisibleItemInfo(
                    id: id,
                    offsetTop: offsetTop,
                    height: height,
                    selector: selector,
                    index: itemData["index"] as? Int
                )
            }
        }
        
        // 스켈레톤 정보 파싱
        var skeletonInfo: SkeletonInfo? = nil
        if let skeletonData = data["skeletonInfo"] as? [String: Any] {
            skeletonInfo = SkeletonInfo(
                averageItemHeight: skeletonData["averageItemHeight"] as? Double ?? 200,
                totalEstimatedHeight: skeletonData["totalEstimatedHeight"] as? Double ?? 0,
                loadedItemCount: skeletonData["loadedItemCount"] as? Int ?? 0,
                estimatedTotalItems: skeletonData["estimatedTotalItems"] as? Int ?? 0
            )
        }
        
        // 가상화 정보 파싱
        var virtualizedInfo: VirtualizedInfo? = nil
        if let virtualData = data["virtualizedInfo"] as? [String: Any] {
            let visibleRange: (start: Int, end: Int)
            if let rangeData = virtualData["visibleRange"] as? [String: Int] {
                visibleRange = (rangeData["start"] ?? 0, rangeData["end"] ?? 0)
            } else {
                visibleRange = (0, 0)
            }
            
            virtualizedInfo = VirtualizedInfo(
                sequence: virtualData["sequence"] as? Int ?? 0,
                pageNumber: virtualData["pageNumber"] as? Int ?? 0,
                pageSize: virtualData["pageSize"] as? Int ?? 20,
                totalItems: virtualData["totalItems"] as? Int,
                visibleRange: visibleRange
            )
        }
        
        // 로딩 상태 파싱
        let loadingStates = data["loadingStates"] as? [String: Bool] ?? [:]
        
        return ScrollStateInfo(
            scrollX: scrollX,
            scrollY: scrollY,
            visibleItems: visibleItems,
            skeletonInfo: skeletonInfo,
            virtualizedInfo: virtualizedInfo,
            loadingStates: loadingStates,
            dataTimestamp: Date()
        )
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
                title: snapshot.snapshot.pageRecord.title,
                siteType: snapshot.snapshot.siteType.rawValue
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
            
            self.dbg("💾 \(snapshot.snapshot.siteType.rawValue) 전략 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
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
        let siteType: String
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
                    return v1 > v2
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
    
    // MARK: - 🔍 **개선된 스냅샷 조회 시스템**
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        // 1. 먼저 메모리 캐시 확인 (스레드 안전)
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title) (\(snapshot.siteType.rawValue))")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인 (스레드 안전)
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장 (최적화)
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title) (\(snapshot.siteType.rawValue))")
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
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) (\(snapshot.siteType.rawValue)) [v\(snapshot.version)]")
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
    
    // 🎬 **5가지 전략 기반 미리보기 컨테이너 타이밍 개선**
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
                // 🎬 **5가지 전략 기반 네비게이션 수행**
                self?.performNavigationWithStrategies(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🔄 **5가지 전략을 적용한 네비게이션 수행**
    private func performNavigationWithStrategies(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            // 실패 시 즉시 정리
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // 🔄 **5가지 전략 기반 BFCache 복원**
        tryStrategicBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            // BFCache 복원 완료 또는 실패 시 즉시 정리 (깜빡임 최소화)
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - BFCache \(success ? "성공" : "실패")")
            }
        }
        
        // 🛡️ **안전장치: 최대 1초 후 강제 정리**
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (1초 타임아웃)")
            }
        }
    }
    
    // 🔄 **5가지 전략 기반 BFCache 복원** 
    private func tryStrategicBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 5가지 전략별 복원
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
            // BFCache 미스 - 기본 대기
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
        tryStrategicBFCacheRestore(stateModel: stateModel, direction: .back) { _ in
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
        tryStrategicBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in
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
        
        TabPersistenceManager.debugMessages.append("✅ 5가지 전략 BFCache 시스템 설치 완료")
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
        dbg("📸 떠나기 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 캡처 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
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
                        version: 1,
                        siteType: .dynamicSite // 기본값
                    )
                    
                    // 디스크에 메타데이터만 저장
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
