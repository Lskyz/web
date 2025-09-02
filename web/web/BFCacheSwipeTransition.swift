//
//  BFCacheSwipeTransition.swift
//  🎯 **기존 구조 유지 + 동적사이트 처리 통합**
//  ✅ 직렬화 큐, 메모리 관리, 제스처 시스템 모두 유지
//  🔄 동적 콘텐츠 캡처/복원을 기존 로직에 자연스럽게 통합
//  🚫 중복 코드 제거, 기존 메서드 확장
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

// MARK: - 📸 BFCache 페이지 스냅샷 (동적 콘텐츠 지원 통합)
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 🆕 동적 콘텐츠 데이터 (기존 구조에 통합)
    var dynamicContent: DynamicContentData?
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
        case dynamicOptimized // 🆕 동적 콘텐츠 최적화됨
    }
    
    // 🆕 동적 콘텐츠 데이터 구조
    struct DynamicContentData: Codable {
        let virtualPosition: VirtualPosition
        let contentItems: [ContentItem]
        let sitePattern: String
        
        struct VirtualPosition: Codable {
            let centerItemIndex: Int
            let centerItemId: String?
            let itemOffset: Double
            let scrollRatio: Double
        }
        
        struct ContentItem: Codable {
            let index: Int
            let id: String
            let html: String
            let title: String
            let position: CGRect
        }
    }
    
    // MARK: - Codable 구현 (동적 콘텐츠 통합)
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, jsState, timestamp
        case webViewSnapshotPath, captureStatus, version, dynamicContent
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
        dynamicContent = try container.decodeIfPresent(DynamicContentData.self, forKey: .dynamicContent)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(dynamicContent, forKey: .dynamicContent)
    }
    
    // 기존 초기화 메서드 확장
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1, dynamicContent: DynamicContentData? = nil) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.dynamicContent = dynamicContent
    }
    
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🔄 기존 복원 메서드에 동적 콘텐츠 지원 통합
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 기존 상태별 분기 유지
        switch captureStatus {
        case .failed:
            TabPersistenceManager.debugMessages.append("BFCache 캡처 실패 - 즉시 완료")
            completion(false)
            return
            
        case .visualOnly:
            DispatchQueue.main.async {
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                TabPersistenceManager.debugMessages.append("BFCache 스크롤만 즉시 복원")
                completion(true)
            }
            return
            
        case .dynamicOptimized:
            // 🆕 동적 콘텐츠 우선 복원
            TabPersistenceManager.debugMessages.append("BFCache 동적 콘텐츠 복원 시작")
            DispatchQueue.main.async {
                self.restoreWithDynamicContent(to: webView, completion: completion)
            }
            return
            
        case .partial, .complete:
            break
        }
        
        TabPersistenceManager.debugMessages.append("BFCache 상태 복원 시작 (통합 모드)")
        DispatchQueue.main.async {
            self.restorePageState(to: webView, completion: completion)
        }
    }
    
    // 🆕 동적 콘텐츠 우선 복원 (기존 로직 확장)
    private func restoreWithDynamicContent(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let dynamicData = dynamicContent else {
            // 동적 데이터 없으면 기존 로직으로 fallback
            restorePageState(to: webView, completion: completion)
            return
        }
        
        let restoreScript = generateDynamicRestoreScript(dynamicData)
        
        webView.evaluateJavaScript(restoreScript) { [weak self] result, error in
            let success = (result as? Bool) ?? false
            
            if success {
                TabPersistenceManager.debugMessages.append("✅ 동적 콘텐츠 복원 성공")
                completion(true)
            } else {
                TabPersistenceManager.debugMessages.append("⚠️ 동적 콘텐츠 복원 실패, 기본 모드로 대체")
                // 기존 복원으로 fallback
                self?.restorePageState(to: webView, completion: completion)
            }
        }
    }
    
    // 기존 restorePageState 메서드 유지 (수정 없음)
    private func restorePageState(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var restoreSteps: [() -> Void] = []
        var stepResults: [Bool] = []
        var currentStep = 0
        
        var nextStep: (() -> Void)!
        nextStep = {
            if currentStep < restoreSteps.count {
                let step = restoreSteps[currentStep]; currentStep += 1; step()
            } else {
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > totalSteps / 2
                TabPersistenceManager.debugMessages.append("BFCache 복원 완료: \(successCount)/\(totalSteps) 성공 -> \(overallSuccess ? "성공" : "실패")")
                completion(overallSuccess)
            }
        }
        
        // 기존 스크롤 복원 로직 유지
        restoreSteps.append {
            let targetPos = self.scrollPosition
            TabPersistenceManager.debugMessages.append("🔄 스크롤 복원 시도: x=\(targetPos.x), y=\(targetPos.y)")
            
            webView.scrollView.setContentOffset(targetPos, animated: false)
            
            let robustScrollJS = """
            (function() {
                function attemptScroll() {
                    try {
                        if (document.readyState !== 'complete') {
                            setTimeout(attemptScroll, 30);
                            return false;
                        }
                        
                        window.scrollTo(\(targetPos.x), \(targetPos.y));
                        document.documentElement.scrollTop = \(targetPos.y);
                        document.body.scrollTop = \(targetPos.y);
                        document.documentElement.scrollLeft = \(targetPos.x);
                        document.body.scrollLeft = \(targetPos.x);
                        
                        console.log('🔄 스크롤 복원 완료:', window.scrollY, window.scrollX);
                        return true;
                    } catch(e) {
                        console.error('🔄 스크롤 복원 실패:', e);
                        return false;
                    }
                }
                return attemptScroll();
            })()
            """
            
            webView.evaluateJavaScript(robustScrollJS) { result, error in
                let success = (result as? Bool) ?? false
                stepResults.append(success)
                
                if !success || targetPos.y > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        webView.scrollView.setContentOffset(targetPos, animated: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            let finalScrollJS = "window.scrollTo(\(targetPos.x), \(targetPos.y)); window.scrollY >= \(targetPos.y - 50)"
                            webView.evaluateJavaScript(finalScrollJS) { finalResult, _ in
                                let finalSuccess = (finalResult as? Bool) ?? false
                                TabPersistenceManager.debugMessages.append("🔄 최종 스크롤 상태: \(finalSuccess ? "성공" : "실패")")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    nextStep()
                                }
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        nextStep()
                    }
                }
            }
        }
        
        // 기존 고급 스크롤 복원 로직 유지
        if let jsState = self.jsState,
           let s = jsState["scroll"] as? [String:Any],
           let els = s["elements"] as? [[String:Any]], !els.isEmpty {
            restoreSteps.append {
                let js = """
                (function(){
                    try{
                        const arr=\(self.convertScrollElementsToJSArray(els)); let ok=0;
                        for(const it of arr){
                            if(!it.selector) continue;
                            const el=document.querySelector(it.selector);
                            if(el && el.scrollTop !== undefined){
                                el.scrollTop=it.top||0; el.scrollLeft=it.left||0; ok++;
                            }
                        }
                        return ok>=0;
                    }catch(e){return false;}
                })()
                """
                webView.evaluateJavaScript(js) { result, _ in
                    stepResults.append((result as? Bool) ?? false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        nextStep()
                    }
                }
            }
        }
        
        nextStep()
    }
    
    // 🆕 동적 복원 스크립트 생성
    private func generateDynamicRestoreScript(_ dynamicData: DynamicContentData) -> String {
        let contentItemsJSON = contentItemsToJSON(dynamicData.contentItems)
        
        return """
        (function() {
            try {
                console.log('🔄 동적 콘텐츠 복원 시작');
                
                // 1️⃣ 콘텐츠 삽입
                const contentItems = \(contentItemsJSON);
                const virtualPos = {
                    centerIndex: \(dynamicData.virtualPosition.centerItemIndex),
                    centerItemId: '\(dynamicData.virtualPosition.centerItemId ?? "")',
                    itemOffset: \(dynamicData.virtualPosition.itemOffset),
                    scrollRatio: \(dynamicData.virtualPosition.scrollRatio)
                };
                
                // 컨테이너 찾기
                const containers = ['.article-list', '.post-list', '.content-list', '.list-container', 'ul', 'ol', 'tbody'];
                let targetContainer = null;
                
                for (const selector of containers) {
                    const container = document.querySelector(selector);
                    if (container) {
                        targetContainer = container;
                        break;
                    }
                }
                
                if (!targetContainer) {
                    console.warn('동적 콘텐츠 컨테이너를 찾을 수 없음');
                    return false;
                }
                
                // 2️⃣ 캐시된 아이템 삽입
                let insertedCount = 0;
                contentItems.forEach(item => {
                    try {
                        if (!document.querySelector(`[data-bfcache-id="\${item.id}"]`)) {
                            const div = document.createElement('div');
                            div.innerHTML = item.html;
                            const newItem = div.firstElementChild;
                            
                            if (newItem) {
                                newItem.setAttribute('data-bfcache-id', item.id);
                                newItem.setAttribute('data-bfcache-restored', 'true');
                                targetContainer.appendChild(newItem);
                                insertedCount++;
                            }
                        }
                    } catch(e) {
                        console.warn('아이템 삽입 실패:', e);
                    }
                });
                
                console.log(`동적 콘텐츠 삽입: \${insertedCount}개`);
                
                // 3️⃣ 스크롤 복원 (아이템 기준)
                if (virtualPos.centerItemId) {
                    const targetItem = document.querySelector(`[data-bfcache-id="\${virtualPos.centerItemId}"]`);
                    if (targetItem) {
                        const rect = targetItem.getBoundingClientRect();
                        const targetY = rect.top + window.scrollY - virtualPos.itemOffset;
                        window.scrollTo({ top: targetY, left: 0, behavior: 'instant' });
                        console.log(`아이템 기준 스크롤: \${targetY}px`);
                        return true;
                    }
                }
                
                // 4️⃣ 비율 기준 스크롤 (fallback)
                const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
                const targetY = Math.max(0, maxScroll * virtualPos.scrollRatio);
                window.scrollTo({ top: targetY, left: 0, behavior: 'instant' });
                console.log(`비율 기준 스크롤: \${targetY}px`);
                
                return insertedCount > 0;
            } catch(e) {
                console.error('동적 콘텐츠 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 유틸리티 메서드들
    private func convertScrollElementsToJSArray(_ elements: [[String: Any]]) -> String {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: elements, options: [])
            return String(data: jsonData, encoding: .utf8) ?? "[]"
        } catch {
            TabPersistenceManager.debugMessages.append("스크롤 요소 JSON 변환 실패: \(error.localizedDescription)")
            return "[]"
        }
    }
    
    private func contentItemsToJSON(_ items: [DynamicContentData.ContentItem]) -> String {
        let jsonItems = items.map { item in
            return """
            {
                "index": \(item.index),
                "id": "\(item.id)",
                "html": "\(item.html.replacingOccurrences(of: "\"", with: "\\\""))",
                "title": "\(item.title.replacingOccurrences(of: "\"", with: "\\\""))"
            }
            """
        }
        return "[\(jsonItems.joined(separator: ","))]"
    }
}

// MARK: - 🎯 **안정성 강화된 BFCache 전환 시스템** (기존 구조 유지)
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤 (기존 유지)
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 기존 모든 프로퍼티 유지
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
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
    
    // MARK: - 기존 파일 시스템 경로 유지
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
    
    // MARK: - 기존 전환 상태 유지
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
    
    // MARK: - 🔄 기존 캡처 작업에 동적 콘텐츠 지원 통합
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
        
        // 기존 직렬화 큐 시스템 유지
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    // 🔄 기존 performAtomicCapture에 동적 콘텐츠 감지 통합
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 기존 중복 캡처 방지 로직 유지
        guard !pendingCaptures.contains(pageID) else {
            dbg("⏸️ 중복 캡처 방지: \(task.pageRecord.title)")
            return
        }
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        pendingCaptures.insert(pageID)
        dbg("🎯 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 기존 메인 스레드 상태 확인 유지
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
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
        
        // 🔄 기존 캡처 로직에 동적 콘텐츠 감지 통합
        let captureResult = performEnhancedCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        // 기존 저장 로직 유지
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        pendingCaptures.remove(pageID)
        dbg("✅ 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔄 기존 performRobustCapture를 확장하여 동적 콘텐츠 지원
    private func performEnhancedCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptEnhancedCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            dbg("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    // 🔄 기존 attemptCapture에 동적 콘텐츠 캡처 통합
    private func attemptEnhancedCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var dynamicContent: BFCacheSnapshot.DynamicContentData? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        // 기존 1. 비주얼 스냅샷 로직 유지
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
        
        // 🆕 2. 동적 콘텐츠 감지 및 캡처
        let dynamicSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let dynamicScript = makeDynamicContentCaptureScript()
            
            webView.evaluateJavaScript(dynamicScript) { result, error in
                if let data = result as? [String: Any],
                   let isDynamic = data["isDynamic"] as? Bool,
                   isDynamic {
                    dynamicContent = self.parseDynamicContentData(data)
                    self.dbg("🔄 동적 콘텐츠 감지됨: \(pageRecord.title)")
                }
                dynamicSemaphore.signal()
            }
        }
        _ = dynamicSemaphore.wait(timeout: .now() + 1.0)
        
        // 기존 3. DOM 캡처 로직 유지 (폼데이터 제거)
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 눌린 상태/활성 상태 제거
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(el => {
                        el.classList.remove(...Array.from(el.classList).filter(c => 
                            c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus')
                        ));
                    });
                    
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
        
        // 기존 4. JS 상태 캡처 로직 유지 (폼 데이터 제거)
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = """
            (function() {
                try {
                    const scrollableElements = [];
                    document.querySelectorAll('[scrollTop], [scrollLeft]').forEach((el, i) => {
                        if (i >= 20) return;
                        if (el.scrollTop > 0 || el.scrollLeft > 0) {
                            scrollableElements.push({
                                selector: el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.className ? '.' + el.className.split(' ')[0] : ''),
                                top: el.scrollTop,
                                left: el.scrollLeft
                            });
                        }
                    });
                    
                    return {
                        scroll: { 
                            x: window.scrollX, 
                            y: window.scrollY,
                            elements: scrollableElements
                        },
                        href: window.location.href,
                        title: document.title
                    };
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 0.8)
        
        // 🔄 캡처 상태 결정 (동적 콘텐츠 고려)
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if dynamicContent != nil {
            captureStatus = .dynamicOptimized
        } else if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 기존 버전 증가 로직 유지
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
            dynamicContent: dynamicContent // 🆕 동적 콘텐츠 추가
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🆕 동적 콘텐츠 캡처 스크립트 생성
    private func makeDynamicContentCaptureScript() -> String {
        return """
        (function() {
            try {
                // 동적 사이트 패턴 감지
                const infiniteScrollSelectors = [
                    '.load-more', '.btn-more', '[onclick*="more"]',
                    '[class*="infinite"]', '[data-infinite]'
                ];
                
                let hasInfiniteScroll = false;
                for (const selector of infiniteScrollSelectors) {
                    if (document.querySelector(selector)) {
                        hasInfiniteScroll = true;
                        break;
                    }
                }
                
                // 가상화 감지 (문서 높이 대비 실제 요소 수)
                const docHeight = document.documentElement.scrollHeight;
                const itemSelectors = [
                    '[class*="item"]:not([class*="menu"])', '[class*="post"]', '[class*="article"]',
                    'li', 'tr', '.card', '.entry'
                ];
                
                let totalItems = 0;
                for (const selector of itemSelectors) {
                    const items = document.querySelectorAll(selector);
                    if (items.length > totalItems) {
                        totalItems = items.length;
                    }
                }
                
                const hasVirtualization = docHeight > (totalItems * 80); // 평균 80px 가정
                const isDynamic = hasInfiniteScroll || hasVirtualization;
                
                if (!isDynamic) {
                    return { isDynamic: false };
                }
                
                // 현재 뷰포트 중심 아이템 찾기
                const viewportCenter = window.innerHeight / 2 + window.scrollY;
                const items = document.querySelectorAll(itemSelectors.join(', '));
                
                let centerItemIndex = 0;
                let centerItemId = '';
                let minDistance = Infinity;
                
                items.forEach((item, index) => {
                    const rect = item.getBoundingClientRect();
                    const itemCenter = rect.top + window.scrollY + (rect.height / 2);
                    const distance = Math.abs(itemCenter - viewportCenter);
                    
                    if (distance < minDistance) {
                        minDistance = distance;
                        centerItemIndex = index;
                        centerItemId = item.id || item.dataset.id || `item_${index}`;
                    }
                });
                
                // 중심 아이템 주변 ±20개 캡처 (총 40개)
                const startIndex = Math.max(0, centerItemIndex - 20);
                const endIndex = Math.min(items.length, centerItemIndex + 20);
                const capturedItems = [];
                
                for (let i = startIndex; i < endIndex; i++) {
                    const item = items[i];
                    const rect = item.getBoundingClientRect();
                    
                    // HTML 간소화 (이미지, 스크립트 제거)
                    let html = item.outerHTML
                        .replace(/<img[^>]*>/gi, '')
                        .replace(/<script[^>]*>.*?<\/script>/gi, '')
                        .replace(/style="[^"]*"/gi, '');
                    
                    if (html.length > 2000) {
                        html = html.substring(0, 2000) + '...';
                    }
                    
                    capturedItems.push({
                        index: i,
                        id: item.id || item.dataset.id || `item_${i}`,
                        html: html,
                        title: item.textContent?.trim().substring(0, 100) || '',
                        position: {
                            x: rect.left + window.scrollX,
                            y: rect.top + window.scrollY,
                            width: rect.width,
                            height: rect.height
                        }
                    });
                }
                
                return {
                    isDynamic: true,
                    sitePattern: hasInfiniteScroll ? 'infinite_scroll' : 'virtualized',
                    virtualPosition: {
                        centerItemIndex: centerItemIndex,
                        centerItemId: centerItemId,
                        itemOffset: window.scrollY - (items[centerItemIndex]?.getBoundingClientRect().top + window.scrollY || 0),
                        scrollRatio: window.scrollY / Math.max(1, docHeight - window.innerHeight)
                    },
                    contentItems: capturedItems
                };
                
            } catch(e) {
                console.error('동적 콘텐츠 캡처 실패:', e);
                return { isDynamic: false };
            }
        })()
        """
    }
    
    // 🆕 동적 콘텐츠 데이터 파싱
    private func parseDynamicContentData(_ data: [String: Any]) -> BFCacheSnapshot.DynamicContentData? {
        guard let sitePattern = data["sitePattern"] as? String,
              let virtualPosData = data["virtualPosition"] as? [String: Any],
              let contentItemsData = data["contentItems"] as? [[String: Any]] else {
            return nil
        }
        
        let virtualPosition = BFCacheSnapshot.DynamicContentData.VirtualPosition(
            centerItemIndex: virtualPosData["centerItemIndex"] as? Int ?? 0,
            centerItemId: virtualPosData["centerItemId"] as? String,
            itemOffset: virtualPosData["itemOffset"] as? Double ?? 0,
            scrollRatio: virtualPosData["scrollRatio"] as? Double ?? 0
        )
        
        let contentItems = contentItemsData.compactMap { itemData -> BFCacheSnapshot.DynamicContentData.ContentItem? in
            guard let index = itemData["index"] as? Int,
                  let id = itemData["id"] as? String,
                  let html = itemData["html"] as? String,
                  let title = itemData["title"] as? String,
                  let posData = itemData["position"] as? [String: Any] else {
                return nil
            }
            
            let position = CGRect(
                x: posData["x"] as? CGFloat ?? 0,
                y: posData["y"] as? CGFloat ?? 0,
                width: posData["width"] as? CGFloat ?? 0,
                height: posData["height"] as? CGFloat ?? 0
            )
            
            return BFCacheSnapshot.DynamicContentData.ContentItem(
                index: index,
                id: id,
                html: html,
                title: title,
                position: position
            )
        }
        
        return BFCacheSnapshot.DynamicContentData(
            virtualPosition: virtualPosition,
            contentItems: contentItems,
            sitePattern: sitePattern
        )
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 **기존 디스크 저장 시스템 유지**
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
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
    
    // MARK: - 💾 **기존 디스크 캐시 로딩 유지**
    
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
    
    // MARK: - 🔍 **기존 스냅샷 조회 시스템 유지**
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title)")
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
    
    // MARK: - 메모리 캐시 관리 (기존 유지)
    
    private func storeInMemory(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        setMemoryCache(snapshot, for: pageID)
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)]")
    }
    
    // MARK: - 🧹 **기존 캐시 정리 유지**
    
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
    
    // MARK: - 🎯 **기존 제스처 시스템 완전 유지** (수정 없음)
    
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
    
    // MARK: - 🎯 **기존 제스처/전환 로직 완전 유지** (나머지 모든 메서드들)
    
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
                self?.performNavigationWithSmartTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    private func performNavigationWithSmartTiming(context: TransitionContext, previewContainer: UIView) {
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
        
        tryBFCacheRestoreWithCallback(stateModel: stateModel, direction: context.direction) { [weak self] success in
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - BFCache \(success ? "성공" : "실패")")
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (0.5초 타임아웃)")
            }
        }
    }
    
    private func tryBFCacheRestoreWithCallback(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                completion(false)
            }
            return
        }
        
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ BFCache 상태 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ BFCache 상태 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
    
    private func tryBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else { 
            completion(false)
            return
        }
        
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ BFCache 상태 복원 성공: \(currentRecord.title) [상태: \(snapshot.captureStatus)]")
                } else {
                    self?.dbg("⚠️ BFCache 상태 복원 실패: \(currentRecord.title)")
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    completion(success)
                }
            }
        } else {
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                completion(false)
            }
        }
    }
    
    // MARK: - 버튼 네비게이션 (즉시 전환) - 기존 유지
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryBFCacheRestore(stateModel: stateModel, direction: .back) { _ in }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        tryBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in }
    }
    
    // MARK: - 기존 스와이프 제스처 감지 처리 유지
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가 (과거 점프 방지): \(url.absoluteString)")
    }
    
    // MARK: - 🌐 기존 JavaScript 스크립트 유지
    
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

// MARK: - UIGestureRecognizerDelegate - 기존 유지
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - CustomWebView 통합 인터페이스 - 기존 유지
extension BFCacheTransitionSystem {
    
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        shared.setupGestures(for: webView, stateModel: stateModel)
        TabPersistenceManager.debugMessages.append("✅ BFCache 시스템 설치 완료")
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

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출 - 기존 유지
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
