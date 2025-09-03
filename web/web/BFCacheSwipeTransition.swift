//
//  BFCacheSwipeTransition.swift
//  🎯 **블로그 5가지 시나리오 적용된 스크롤 복구 시스템**
//  ✅ 시나리오 1: 정적 데이터 - History API 스타일 즉시 복원
//  ✅ 시나리오 2: 동적 데이터 - 가시 아이템 정보 기준 복원  
//  ✅ 시나리오 3: 레이지 로딩 - 스켈레톤 + 배치 로딩 복원
//  ✅ 시나리오 4: 캐시 활용 - React Query 스타일 즉시 복원
//  ✅ 시나리오 5: 가상화 - 시퀀스 기반 복원
//  🚫 복잡한 4단계 시스템 제거 → 상황별 맞춤 복원으로 대체
//  🚫 적응형 타이밍 학습 제거 → 고정된 합리적 대기시간
//  ✅ 현실적인 복원 (완벽보단 자연스럽게)
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

// MARK: - 📸 블로그 시나리오 적용된 BFCache 스냅샷
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 📊 **새로 추가: 페이지 타입별 복원 전략**
    let pageType: PageType
    let visibleItemsInfo: [VisibleItemInfo]? // 시나리오 2: 동적 데이터용
    let estimatedContentHeight: CGFloat?     // 시나리오 3: 레이지 로딩용
    let sequenceInfo: SequenceInfo?          // 시나리오 5: 가상화용
    
    enum PageType: String, Codable {
        case staticContent = "static"        // 시나리오 1: 정적 데이터
        case dynamicContent = "dynamic"      // 시나리오 2: 동적 데이터  
        case lazyLoading = "lazy"           // 시나리오 3: 레이지 로딩
        case cached = "cached"              // 시나리오 4: 캐시 활용
        case virtualized = "virtualized"    // 시나리오 5: 가상화
    }
    
    struct VisibleItemInfo: Codable {
        let id: String
        let offsetTop: CGFloat
        let elementSelector: String
    }
    
    struct SequenceInfo: Codable {
        let listSequence: Int
        let pageNumber: Int
        let pageSize: Int
        let totalItems: Int
    }
    
    enum CaptureStatus: String, Codable {
        case complete, partial, visualOnly, failed
    }
    
    // MARK: - Codable 구현
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, jsState, timestamp
        case webViewSnapshotPath, captureStatus, version, pageType
        case visibleItemsInfo, estimatedContentHeight, sequenceInfo
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
        pageType = try container.decodeIfPresent(PageType.self, forKey: .pageType) ?? .staticContent
        visibleItemsInfo = try container.decodeIfPresent([VisibleItemInfo].self, forKey: .visibleItemsInfo)
        estimatedContentHeight = try container.decodeIfPresent(CGFloat.self, forKey: .estimatedContentHeight)
        sequenceInfo = try container.decodeIfPresent(SequenceInfo.self, forKey: .sequenceInfo)
        
        // JSON decode for [String: Any]
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
        try container.encode(pageType, forKey: .pageType)
        try container.encodeIfPresent(visibleItemsInfo, forKey: .visibleItemsInfo)
        try container.encodeIfPresent(estimatedContentHeight, forKey: .estimatedContentHeight)
        try container.encodeIfPresent(sequenceInfo, forKey: .sequenceInfo)
        
        // JSON encode for [String: Any]
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
    }
    
    // 직접 초기화
    init(pageRecord: PageRecord, scrollPosition: CGPoint, jsState: [String: Any]? = nil,
         timestamp: Date = Date(), webViewSnapshotPath: String? = nil, 
         captureStatus: CaptureStatus = .partial, version: Int = 1,
         pageType: PageType = .staticContent, visibleItemsInfo: [VisibleItemInfo]? = nil,
         estimatedContentHeight: CGFloat? = nil, sequenceInfo: SequenceInfo? = nil) {
        self.pageRecord = pageRecord
        self.domSnapshot = nil
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.pageType = pageType
        self.visibleItemsInfo = visibleItemsInfo
        self.estimatedContentHeight = estimatedContentHeight
        self.sequenceInfo = sequenceInfo
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🎯 **핵심: 블로그 5가지 시나리오별 복원 메서드**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard captureStatus != .failed else {
            completion(false)
            return
        }
        
        TabPersistenceManager.debugMessages.append("🔄 시나리오별 복원 시작: \(pageType.rawValue)")
        
        switch pageType {
        case .staticContent:
            restoreStaticContent(to: webView, completion: completion)
        case .dynamicContent:
            restoreDynamicContent(to: webView, completion: completion)
        case .lazyLoading:
            restoreLazyLoadingContent(to: webView, completion: completion)
        case .cached:
            restoreCachedContent(to: webView, completion: completion)
        case .virtualized:
            restoreVirtualizedContent(to: webView, completion: completion)
        }
    }
    
    // 🎯 **시나리오 1: 정적 데이터 - History API 스타일 즉시 복원**
    private func restoreStaticContent(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            // 즉시 스크롤 복원 (정적이므로 대기 불필요)
            webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
            
            let basicScrollJS = """
            (function() {
                window.scrollTo(\(self.scrollPosition.x), \(self.scrollPosition.y));
                return true;
            })()
            """
            
            webView.evaluateJavaScript(basicScrollJS) { result, _ in
                let success = (result as? Bool) ?? false
                TabPersistenceManager.debugMessages.append("✅ 시나리오1 정적 복원: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // 🎯 **시나리오 2: 동적 데이터 - 가시 아이템 기준 복원**
    private func restoreDynamicContent(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            // 동적 데이터 로딩 대기 (현실적인 300ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.restoreWithVisibleItems(to: webView, completion: completion)
            }
        }
    }
    
    private func restoreWithVisibleItems(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let visibleItems = visibleItemsInfo, !visibleItems.isEmpty else {
            // fallback to basic scroll
            restoreStaticContent(to: webView, completion: completion)
            return
        }
        
        let targetItem = visibleItems[0] // 첫 번째 가시 아이템 기준
        let dynamicScrollJS = """
        (function() {
            try {
                // 저장된 아이템을 찾아서 기준점으로 사용
                const targetElement = document.querySelector('\(targetItem.elementSelector)');
                if (targetElement) {
                    targetElement.scrollIntoView();
                    // 미세 조정
                    window.scrollTo(\(scrollPosition.x), \(scrollPosition.y));
                    return true;
                } else {
                    // 대체: 기본 스크롤 위치로
                    window.scrollTo(\(scrollPosition.x), \(scrollPosition.y));
                    return false;
                }
            } catch(e) {
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(dynamicScrollJS) { result, _ in
            let success = (result as? Bool) ?? false
            TabPersistenceManager.debugMessages.append("✅ 시나리오2 동적 복원: \(success ? "성공" : "실패")")
            completion(success)
        }
    }
    
    // 🎯 **시나리오 3: 레이지 로딩 - 스켈레톤 + 배치 로딩**
    private func restoreLazyLoadingContent(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            // 1단계: 스켈레톤으로 공간 확보
            if let estimatedHeight = self.estimatedContentHeight {
                self.createSkeletonPlaceholder(to: webView, height: estimatedHeight)
            }
            
            // 2단계: 스크롤 위치 설정
            webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
            
            // 3단계: 실제 데이터 로딩 대기 (현실적인 500ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let lazyScrollJS = """
                (function() {
                    // 스켈레톤 제거 후 실제 스크롤 복원
                    const skeletons = document.querySelectorAll('.bfcache-skeleton');
                    skeletons.forEach(s => s.remove());
                    
                    window.scrollTo(\(self.scrollPosition.x), \(self.scrollPosition.y));
                    return true;
                })()
                """
                
                webView.evaluateJavaScript(lazyScrollJS) { result, _ in
                    let success = (result as? Bool) ?? false
                    TabPersistenceManager.debugMessages.append("✅ 시나리오3 레이지 복원: \(success ? "성공" : "실패")")
                    completion(success)
                }
            }
        }
    }
    
    private func createSkeletonPlaceholder(to webView: WKWebView, height: CGFloat) {
        let skeletonJS = """
        (function() {
            const skeleton = document.createElement('div');
            skeleton.className = 'bfcache-skeleton';
            skeleton.style.height = '\(height)px';
            skeleton.style.backgroundColor = '#f0f0f0';
            skeleton.style.position = 'absolute';
            skeleton.style.top = '0';
            skeleton.style.width = '100%';
            skeleton.style.zIndex = '1000';
            document.body.appendChild(skeleton);
        })()
        """
        
        webView.evaluateJavaScript(skeletonJS, completionHandler: nil)
    }
    
    // 🎯 **시나리오 4: 캐시 활용 - React Query 스타일 즉시 복원**
    private func restoreCachedContent(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            // 캐시된 데이터가 있으므로 즉시 복원 가능
            webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
            
            let cachedScrollJS = """
            (function() {
                // 캐시된 상태이므로 즉시 스크롤 복원
                window.scrollTo(\(self.scrollPosition.x), \(self.scrollPosition.y));
                
                // 저장된 컨테이너 스크롤도 복원
                \(self.generateContainerScrollScript())
                
                return true;
            })()
            """
            
            webView.evaluateJavaScript(cachedScrollJS) { result, _ in
                let success = (result as? Bool) ?? false
                TabPersistenceManager.debugMessages.append("✅ 시나리오4 캐시 복원: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // 🎯 **시나리오 5: 가상화 - 시퀀스 기반 복원**
    private func restoreVirtualizedContent(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let sequence = sequenceInfo else {
            restoreStaticContent(to: webView, completion: completion)
            return
        }
        
        DispatchQueue.main.async {
            let virtualizedJS = """
            (function() {
                try {
                    // 가상화된 리스트에 시퀀스 정보 전달
                    if (window.virtualList && window.virtualList.scrollToSequence) {
                        window.virtualList.scrollToSequence(\(sequence.listSequence));
                        return true;
                    } else {
                        // Fallback: 기본 스크롤
                        window.scrollTo(\(self.scrollPosition.x), \(self.scrollPosition.y));
                        return false;
                    }
                } catch(e) {
                    return false;
                }
            })()
            """
            
            webView.evaluateJavaScript(virtualizedJS) { result, _ in
                let success = (result as? Bool) ?? false
                TabPersistenceManager.debugMessages.append("✅ 시나리오5 가상화 복원: \(success ? "성공" : "실패")")
                completion(success)
            }
        }
    }
    
    // 컨테이너 스크롤 복원 스크립트 생성
    private func generateContainerScrollScript() -> String {
        guard let jsState = jsState,
              let scrollData = jsState["scroll"] as? [String: Any],
              let elements = scrollData["elements"] as? [[String: Any]],
              !elements.isEmpty else {
            return "// 저장된 컨테이너 스크롤 없음"
        }
        
        var scriptParts: [String] = []
        for element in elements.prefix(5) { // 상위 5개만
            guard let selector = element["selector"] as? String,
                  let top = element["top"] as? Double else { continue }
            
            scriptParts.append("""
            try {
                const el = document.querySelector('\(selector)');
                if (el) el.scrollTop = \(top);
            } catch(e) {}
            """)
        }
        
        return scriptParts.joined(separator: "\n")
    }
}

// MARK: - 🎯 **블로그 시나리오 적용된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 직렬화 캐시 시스템 (기존 유지)
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // 스레드 안전 캐시 시스템
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
    
    // MARK: - 📁 파일 시스템 경로 (기존 유지)
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
    
    // MARK: - 전환 상태 (기존 유지)
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
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    enum CaptureType {
        case immediate
        case background
    }
    
    // MARK: - 🎯 **블로그 시나리오 적용된 캡처 시스템**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    private var pendingCaptures: Set<UUID> = []
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        serialQueue.async { [weak self] in
            self?.performSmartCapture(task)
        }
    }
    
    // 🎯 **스마트 캡처: 블로그 시나리오 자동 감지 + 맞춤 캡처**
    private func performSmartCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        guard !pendingCaptures.contains(pageID) else {
            dbg("⏸️ 중복 캡처 방지: \(task.pageRecord.title)")
            return
        }
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        pendingCaptures.insert(pageID)
        dbg("🎯 스마트 캡처 시작: \(task.pageRecord.title)")
        
        // 메인 스레드에서 캐스케이딩 캡처 수행
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캐스케이딩 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                isLoading: webView.isLoading,
                url: task.pageRecord.url
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🎯 **핵심: 페이지 타입 자동 감지**
        let pageType = detectPageType(url: data.url, webView: webView)
        
        // 페이지 타입별 맞춤 캡처
        let captureResult = performScenarioBasedCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            pageType: pageType
        )
        
        // 캐시 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        pendingCaptures.remove(pageID)
        dbg("✅ 스마트 캡처 완료 (\(pageType.rawValue)): \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
        let url: URL
    }
    
    // 🎯 **페이지 타입 자동 감지** (블로그 시나리오 매핑)
    private func detectPageType(url: URL, webView: WKWebView) -> BFCacheSnapshot.PageType {
        let urlString = url.absoluteString.lowercased()
        let host = url.host?.lowercased() ?? ""
        
        // 시나리오 5: 가상화 (대량 리스트 감지)
        if urlString.contains("list") || urlString.contains("feed") || 
           urlString.contains("timeline") || host.contains("twitter") {
            return .virtualized
        }
        
        // 시나리오 3: 레이지 로딩 (무한스크롤 사이트)
        if host.contains("instagram") || host.contains("facebook") || 
           urlString.contains("infinite") || urlString.contains("scroll") {
            return .lazyLoading
        }
        
        // 시나리오 4: 캐시 활용 (이미 방문한 페이지)
        if hasCache(for: UUID()) { // 실제로는 pageID로 체크
            return .cached
        }
        
        // 시나리오 2: 동적 데이터 (SPA, API 기반 사이트)
        if urlString.contains("search") || urlString.contains("api") ||
           host.contains("google") || host.contains("github") {
            return .dynamicContent
        }
        
        // 시나리오 1: 정적 데이터 (기본값)
        return .staticContent
    }
    
    // 🎯 **시나리오별 맞춤 캡처**
    private func performScenarioBasedCapture(pageRecord: PageRecord, webView: WKWebView, 
                                           captureData: CaptureData, pageType: BFCacheSnapshot.PageType) 
                                           -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        var visualSnapshot: UIImage?
        var jsState: [String: Any]?
        var visibleItemsInfo: [BFCacheSnapshot.VisibleItemInfo]?
        var estimatedContentHeight: CGFloat?
        var sequenceInfo: BFCacheSnapshot.SequenceInfo?
        
        // 공통: 비주얼 스냅샷
        visualSnapshot = captureVisualSnapshot(webView: webView, bounds: captureData.bounds)
        
        // 시나리오별 특화 캡처
        switch pageType {
        case .staticContent:
            // 시나리오 1: 기본 스크롤만 캡처
            jsState = captureBasicScrollState(webView: webView)
            
        case .dynamicContent:
            // 시나리오 2: 가시 아이템 정보 캡처
            jsState = captureDynamicScrollState(webView: webView)
            visibleItemsInfo = extractVisibleItemsInfo(from: jsState)
            
        case .lazyLoading:
            // 시나리오 3: 콘텐츠 높이 추정 + 스켈레톤 정보
            jsState = captureLazyScrollState(webView: webView)
            estimatedContentHeight = estimateContentHeight(from: jsState)
            
        case .cached:
            // 시나리오 4: 빠른 복원용 정보만
            jsState = captureBasicScrollState(webView: webView)
            
        case .virtualized:
            // 시나리오 5: 가상화 시퀀스 정보
            jsState = captureVirtualizedState(webView: webView)
            sequenceInfo = extractSequenceInfo(from: jsState)
        }
        
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && jsState != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = .visualOnly
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
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            scrollPosition: captureData.scrollPosition,
            jsState: jsState,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version,
            pageType: pageType,
            visibleItemsInfo: visibleItemsInfo,
            estimatedContentHeight: estimatedContentHeight,
            sequenceInfo: sequenceInfo
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // MARK: - 🎯 **시나리오별 JavaScript 캡처 메서드들**
    
    private func captureBasicScrollState(webView: WKWebView) -> [String: Any]? {
        return executeJavaScriptSync(webView: webView, script: """
        (function() {
            try {
                return {
                    scroll: { x: window.scrollX, y: window.scrollY }
                };
            } catch(e) { return null; }
        })()
        """)
    }
    
    private func captureDynamicScrollState(webView: WKWebView) -> [String: Any]? {
        return executeJavaScriptSync(webView: webView, script: """
        (function() {
            try {
                // 가시 아이템들 정보 수집
                const visibleItems = [];
                const items = document.querySelectorAll('[data-item-id], .item, .card, article');
                
                for (let i = 0; i < Math.min(items.length, 10); i++) {
                    const item = items[i];
                    const rect = item.getBoundingClientRect();
                    if (rect.top >= 0 && rect.top <= window.innerHeight) {
                        visibleItems.push({
                            id: item.id || item.dataset.itemId || 'item-' + i,
                            offsetTop: item.offsetTop,
                            selector: item.id ? '#' + item.id : '.item'
                        });
                    }
                }
                
                return {
                    scroll: { x: window.scrollX, y: window.scrollY },
                    visibleItems: visibleItems
                };
            } catch(e) { return null; }
        })()
        """)
    }
    
    private func captureLazyScrollState(webView: WKWebView) -> [String: Any]? {
        return executeJavaScriptSync(webView: webView, script: """
        (function() {
            try {
                return {
                    scroll: { x: window.scrollX, y: window.scrollY },
                    contentHeight: document.documentElement.scrollHeight,
                    viewportHeight: window.innerHeight
                };
            } catch(e) { return null; }
        })()
        """)
    }
    
    private func captureVirtualizedState(webView: WKWebView) -> [String: Any]? {
        return executeJavaScriptSync(webView: webView, script: """
        (function() {
            try {
                // 가상화 리스트 정보 추출 (있는 경우)
                let listInfo = {};
                if (window.virtualList) {
                    listInfo = {
                        sequence: window.virtualList.getCurrentSequence?.() || 0,
                        pageNumber: window.virtualList.getCurrentPage?.() || 0,
                        pageSize: window.virtualList.getPageSize?.() || 20,
                        totalItems: window.virtualList.getTotalItems?.() || 0
                    };
                }
                
                return {
                    scroll: { x: window.scrollX, y: window.scrollY },
                    virtualList: listInfo
                };
            } catch(e) { return null; }
        })()
        """)
    }
    
    // MARK: - 헬퍼 메서드들
    
    private func executeJavaScriptSync(webView: WKWebView, script: String) -> [String: Any]? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script) { jsResult, _ in
                result = jsResult as? [String: Any]
                semaphore.signal()
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 1.0)
        return result
    }
    
    private func extractVisibleItemsInfo(from jsState: [String: Any]?) -> [BFCacheSnapshot.VisibleItemInfo]? {
        guard let jsState = jsState,
              let visibleItems = jsState["visibleItems"] as? [[String: Any]] else { return nil }
        
        return visibleItems.compactMap { item in
            guard let id = item["id"] as? String,
                  let offsetTop = item["offsetTop"] as? Double,
                  let selector = item["selector"] as? String else { return nil }
            
            return BFCacheSnapshot.VisibleItemInfo(
                id: id,
                offsetTop: CGFloat(offsetTop),
                elementSelector: selector
            )
        }
    }
    
    private func estimateContentHeight(from jsState: [String: Any]?) -> CGFloat? {
        guard let jsState = jsState,
              let contentHeight = jsState["contentHeight"] as? Double else { return nil }
        return CGFloat(contentHeight)
    }
    
    private func extractSequenceInfo(from jsState: [String: Any]?) -> BFCacheSnapshot.SequenceInfo? {
        guard let jsState = jsState,
              let virtualList = jsState["virtualList"] as? [String: Any],
              let sequence = virtualList["sequence"] as? Int else { return nil }
        
        return BFCacheSnapshot.SequenceInfo(
            listSequence: sequence,
            pageNumber: virtualList["pageNumber"] as? Int ?? 0,
            pageSize: virtualList["pageSize"] as? Int ?? 20,
            totalItems: virtualList["totalItems"] as? Int ?? 0
        )
    }
    
    private func captureVisualSnapshot(webView: WKWebView, bounds: CGRect) -> UIImage? {
        let semaphore = DispatchSemaphore(value: 0)
        var image: UIImage?
        
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { result, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    image = self.renderWebViewToImage(webView)
                } else {
                    image = result
                }
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃")
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
    
    // MARK: - 💾 디스크 저장 시스템 (기존 유지)
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // 이미지 저장
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    do {
                        try jpegData.write(to: imagePath)
                        finalSnapshot.webViewSnapshotPath = imagePath.path
                    } catch {
                        self.dbg("❌ 이미지 저장 실패: \(error.localizedDescription)")
                    }
                }
            }
            
            // 상태 데이터 저장
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                do {
                    try stateData.write(to: statePath)
                } catch {
                    self.dbg("❌ 상태 저장 실패: \(error.localizedDescription)")
                }
            }
            
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)] (\(finalSnapshot.pageType.rawValue))")
            
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
        }
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
    
    // MARK: - 디스크 캐시 로딩 (기존 유지)
    
    private func loadDiskCacheIndex() {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.createDirectoryIfNeeded(at: self.bfCacheDirectory)
            
            var loadedCount = 0
            
            do {
                let tabDirs = try FileManager.default.contentsOfDirectory(at: self.bfCacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                
                for tabDir in tabDirs {
                    if tabDir.lastPathComponent.hasPrefix("Tab_") {
                        let pageDirs = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        
                        for pageDir in pageDirs {
                            if pageDir.lastPathComponent.hasPrefix("Page_") {
                                let metadataPath = pageDir.appendingPathComponent("metadata.json")
                                if let data = try? Data(contentsOf: metadataPath),
                                   let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) {
                                    
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
    
    private struct CacheMetadata: Codable {
        let pageID: UUID
        let tabID: UUID
        let version: Int
        let timestamp: Date
        let url: String
        let title: String
    }
    
    // MARK: - 스냅샷 조회 시스템 (기존 유지)
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title) (\(snapshot.pageType.rawValue))")
            return snapshot
        }
        
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title) (\(snapshot.pageType.rawValue))")
                return snapshot
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
    
    private func storeInMemory(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        setMemoryCache(snapshot, for: pageID)
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)] (\(snapshot.pageType.rawValue))")
    }
    
    // MARK: - 캐시 정리 (기존 유지)
    
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
    
    // MARK: - 🎯 제스처 시스템 (기존 유지하되 단순화된 복원 호출)
    
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
    
    // MARK: - 제스처 전환 로직 (기존 유지)
    
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
    
    // 🎯 **단순화된 전환 완료** (블로그 시나리오별 복원 호출)
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
                self?.performSimplifiedNavigation(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🎯 **단순화된 네비게이션 수행** (블로그 시나리오별 복원 적용)
    private func performSimplifiedNavigation(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 앞으로가기 완료")
        }
        
        // 🎯 **블로그 시나리오별 BFCache 복원**
        tryScenarioBasedBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - BFCache \(success ? "성공" : "실패")")
            }
        }
        
        // 안전장치: 최대 800ms 후 강제 정리 (현실적인 타임아웃)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (800ms 타임아웃)")
            }
        }
    }
    
    // 🎯 **핵심: 블로그 시나리오별 BFCache 복원**
    private func tryScenarioBasedBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // 🎯 **핵심: 블로그 시나리오별 복원 호출**
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ 시나리오별 BFCache 복원 성공: \(currentRecord.title) (\(snapshot.pageType.rawValue))")
                } else {
                    self?.dbg("⚠️ 시나리오별 BFCache 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 현실적인 기본 대기
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
    
    // MARK: - 버튼 네비게이션 (블로그 시나리오 적용)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryScenarioBasedBFCacheRestore(stateModel: stateModel, direction: .back) { _ in }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        tryScenarioBasedBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in }
    }
    
    // MARK: - 스와이프 제스처 감지 처리
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가: \(url.absoluteString)")
    }
    
    // MARK: - 🌐 JavaScript 스크립트 (기존 유지)
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔄 BFCache 페이지 복원');
                
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
    
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        shared.setupGestures(for: webView, stateModel: stateModel)
        TabPersistenceManager.debugMessages.append("✅ 블로그 시나리오 적용된 BFCache 시스템 설치 완료")
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

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출
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
        
        // 이전 페이지들도 메타데이터 확인
        if stateModel.dataModel.currentPageIndex > 0 {
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                if !hasCache(for: previousRecord.id) {
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollPosition: .zero,
                        timestamp: Date(),
                        captureStatus: .failed,
                        version: 1
                    )
                    
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
