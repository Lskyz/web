//
//  BFCacheSwipeTransition.swift
//  🎯 **리팩토링된 동적 페이지 대응 BFCache 시스템**
//  ✅ 보존: 페이지 미리보기, 스와이프 새 페이지 추가, 전환 애니메이션
//  🔧 개선: Library/Caches 저장, Promise 기반 JS Bridge, 진행형 로딩 보정
//  📊 추가: 모니터링 시스템, 강화된 에러 처리, 성능 관리
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

// MARK: - 🧵 제스처 컨텍스트 (보존)
private class GestureContext {
    let tabID: UUID
    let gestureID: UUID = UUID()
    weak var webView: WKWebView?
    weak var stateModel: WebViewStateModel?
    private var isValid: Bool = true
    private let validationQueue = DispatchQueue(label: "gesture.validation", attributes: .concurrent)
    
    init(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        self.tabID = tabID
        self.webView = webView
        self.stateModel = stateModel
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 생성: \(String(gestureID.uuidString.prefix(8)))")
    }
    
    func validateAndExecute(_ operation: () -> Void) {
        validationQueue.sync {
            guard isValid else {
                TabPersistenceManager.debugMessages.append("🧵 무효한 컨텍스트 - 작업 취소: \(String(gestureID.uuidString.prefix(8)))")
                return
            }
            operation()
        }
    }
    
    func invalidate() {
        validationQueue.async(flags: .barrier) {
            self.isValid = false
            TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 무효화: \(String(self.gestureID.uuidString.prefix(8)))")
        }
    }
    
    deinit {
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 해제: \(String(gestureID.uuidString.prefix(8)))")
    }
}

// MARK: - 📸 **개선된 BFCache 스냅샷 모델**
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
    
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, scrollPositionPercent
        case contentSize, viewportSize, actualScrollableSize, jsState
        case timestamp, webViewSnapshotPath, captureStatus, version
    }
    
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
    
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

// MARK: - 🎯 **BFCache 전환 시스템 (핵심 보존)**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 큐 시스템
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private let gestureQueue = DispatchQueue(label: "gesture.management", attributes: .concurrent)
    
    // MARK: - 캐시 시스템
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
    // MARK: - 🔒 **보존: 제스처 전환 상태 (그대로 유지)**
    private var _activeTransitions: [UUID: TransitionContext] = [:]
    private var _gestureContexts: [UUID: GestureContext] = [:]
    
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
    
    // MARK: - 📁 파일 시스템 경로 (Library/Caches로 변경)
    private var bfCacheDirectory: URL {
        let cachesPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesPath.appendingPathComponent("BFCache", isDirectory: true)
    }
    
    private func tabDirectory(for tabID: UUID) -> URL {
        return bfCacheDirectory.appendingPathComponent("Tab_\(tabID.uuidString)", isDirectory: true)
    }
    
    private func pageDirectory(for pageID: UUID, tabID: UUID, version: Int) -> URL {
        return tabDirectory(for: tabID).appendingPathComponent("Page_\(pageID.uuidString)_v\(version)", isDirectory: true)
    }
    
    // MARK: - 🔒 **보존: 제스처 시스템 (핵심 로직 그대로)**
    
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        // 메인 스레드 확인
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleGesture(gesture)
            }
            return
        }
        
        // 탭 ID 조회
        guard let tabIDString = objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String,
              let tabID = UUID(uuidString: tabIDString) else {
            dbg("🧵 제스처에서 탭 ID 조회 실패")
            gesture.state = .cancelled
            return
        }
        
        // 컨텍스트 유효성 검사
        guard let context = getGestureContext(for: tabID) else {
            dbg("🧵 제스처 컨텍스트 없음 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
            gesture.state = .cancelled
            return
        }
        
        context.validateAndExecute { [weak self] in
            guard let self = self,
                  let webView = context.webView,
                  let stateModel = context.stateModel else {
                TabPersistenceManager.debugMessages.append("🧵 컨텍스트 무효 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
                gesture.state = .cancelled
                return
            }
            
            self.processGestureState(
                gesture: gesture,
                tabID: tabID,
                webView: webView,
                stateModel: stateModel
            )
        }
    }
    
    // MARK: - 🔒 **보존: 제스처 상태 처리 (핵심 로직 그대로)**
    private func processGestureState(gesture: UIScreenEdgePanGestureRecognizer, tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        let width = gesture.view?.bounds.width ?? 1
        
        let absX = abs(translation.x), absY = abs(translation.y)
        let horizontalEnough = absX > 8 && absX > absY
        let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
        
        switch gesture.state {
        case .began:
            guard getActiveTransition(for: tabID) == nil else {
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                if let existing = getActiveTransition(for: tabID) {
                    existing.previewContainer?.removeFromSuperview()
                    removeActiveTransition(for: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                // 현재 페이지 즉시 캡처
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                }
                
                // 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
                captureCurrentSnapshot(webView: webView) { [weak self] snapshot in
                    DispatchQueue.main.async {
                        self?.beginGestureTransitionWithSnapshot(
                            tabID: tabID,
                            webView: webView,
                            stateModel: stateModel,
                            direction: direction,
                            currentSnapshot: snapshot
                        )
                    }
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
    
    // MARK: - 🔒 **보존: 페이지 미리보기 UI (그대로 유지)**
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
    
    // MARK: - 🔒 **보존: 끌어당겨 밀어내는 전환 애니메이션 (그대로 유지)**
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = getActiveTransition(for: tabID),
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
        guard let context = getActiveTransition(for: tabID),
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
                self?.performNavigationWithFixedTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    private func cancelGestureTransition(tabID: UUID) {
        guard let context = getActiveTransition(for: tabID),
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
                self.removeActiveTransition(for: context.tabID)
            }
        )
    }
    
    // MARK: - 🔒 **보존: 항상 새 페이지 추가 (절대 수정 금지)**
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
    
    // MARK: - 🔒 **보존: 버튼 네비게이션 (그대로 유지)**
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
    
    // MARK: - 🔧 **개선: Promise 기반 JS Bridge**
    
    private func executeJavaScript(_ script: String, in webView: WKWebView) -> Promise<Any?> {
        return Promise { fulfill, reject in
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    reject(error)
                } else {
                    fulfill(result)
                }
            }
        }
    }
    
    private struct Promise<T> {
        typealias FulfillHandler = (T) -> Void
        typealias RejectHandler = (Error) -> Void
        
        private let executor: (@escaping FulfillHandler, @escaping RejectHandler) -> Void
        
        init(_ executor: @escaping (@escaping FulfillHandler, @escaping RejectHandler) -> Void) {
            self.executor = executor
        }
        
        func then(_ handler: @escaping (T) -> Void) {
            executor(handler, { _ in })
        }
        
        func timeout(_ seconds: TimeInterval) -> Promise<T?> {
            return Promise<T?> { fulfill, reject in
                var completed = false
                
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    if !completed {
                        completed = true
                        fulfill(nil)
                    }
                }
                
                executor({ value in
                    if !completed {
                        completed = true
                        fulfill(value)
                    }
                }, { error in
                    if !completed {
                        completed = true
                        reject(error)
                    }
                })
            }
        }
    }
    
    // MARK: - 🔧 **개선: 동적 렌더링 대기**
    
    private func waitForDynamicContent(in webView: WKWebView, completion: @escaping () -> Void) {
        let waitScript = """
        (function() {
            return new Promise(resolve => {
                let stabilityCount = 0;
                const requiredStability = 3;
                let timeout;
                
                const observer = new MutationObserver(() => {
                    stabilityCount = 0;
                    clearTimeout(timeout);
                    timeout = setTimeout(() => {
                        stabilityCount++;
                        if (stabilityCount >= requiredStability) {
                            observer.disconnect();
                            resolve(true);
                        }
                    }, 300);
                });
                
                observer.observe(document.body, { childList: true, subtree: true });
                
                setTimeout(() => {
                    observer.disconnect();
                    resolve(false);
                }, 4000);
            });
        })()
        """
        
        executeJavaScript(waitScript, in: webView)
            .timeout(5.0)
            .then { _ in
                completion()
            }
    }
    
    // MARK: - 🔧 **개선: 진행형 로딩 보정**
    
    private func performProgressiveRestore(webView: WKWebView, snapshot: BFCacheSnapshot, completion: @escaping (Bool) -> Void) {
        var restoreSteps: [() -> Promise<Bool>] = []
        
        // 단계 1: DOM 앵커 복원
        restoreSteps.append { [weak self] in
            self?.restoreWithDOMAnchor(webView: webView, snapshot: snapshot) ?? Promise { $0(false), _ in }
        }
        
        // 단계 2: Lazy Load 트리거
        if let jsState = snapshot.jsState,
           let lazyPattern = jsState["lazyLoadPattern"] as? [String: Any],
           lazyPattern["hasLazyLoad"] as? Bool == true {
            restoreSteps.append { [weak self] in
                self?.triggerLazyLoad(webView: webView, pattern: lazyPattern) ?? Promise { $0(false), _ in }
            }
        }
        
        // 단계 3: iframe 복원
        if let jsState = snapshot.jsState,
           let iframes = jsState["iframes"] as? [[String: Any]],
           !iframes.isEmpty {
            restoreSteps.append { [weak self] in
                self?.restoreIframes(webView: webView, iframes: iframes) ?? Promise { $0(false), _ in }
            }
        }
        
        // 단계 4: 최종 검증
        restoreSteps.append { [weak self] in
            self?.finalVerification(webView: webView, targetPosition: snapshot.scrollPosition) ?? Promise { $0(false), _ in }
        }
        
        // 순차 실행
        executeRestoreSteps(restoreSteps, index: 0) { success in
            completion(success)
        }
    }
    
    private func executeRestoreSteps(_ steps: [() -> Promise<Bool>], index: Int, completion: @escaping (Bool) -> Void) {
        guard index < steps.count else {
            completion(true)
            return
        }
        
        steps[index]().then { [weak self] success in
            if !success {
                self?.dbg("❌ 복원 단계 \(index + 1) 실패")
            }
            self?.executeRestoreSteps(steps, index: index + 1, completion: completion)
        }
    }
    
    private func restoreWithDOMAnchor(webView: WKWebView, snapshot: BFCacheSnapshot) -> Promise<Bool> {
        guard let jsState = snapshot.jsState,
              let anchor = jsState["viewportAnchor"] as? [String: Any] else {
            return Promise { $0(false), _ in }
        }
        
        let restoreScript = """
        (function() {
            const anchor = \(convertToJSONString(anchor) ?? "null");
            if (!anchor || !anchor.selector) return false;
            
            const element = document.querySelector(anchor.selector);
            if (!element) return false;
            
            const rect = element.getBoundingClientRect();
            const elementTop = window.scrollY + rect.top;
            const restoreY = elementTop - (anchor.offsetFromTop || 0);
            
            // 스티키 헤더 보정
            const stickyHeader = document.querySelector('header[style*="sticky"], nav[style*="sticky"], [class*="sticky-header"]');
            const stickyOffset = stickyHeader ? stickyHeader.offsetHeight : 0;
            
            window.scrollTo(0, restoreY - stickyOffset);
            return true;
        })()
        """
        
        return executeJavaScript(restoreScript, in: webView)
            .timeout(1.0)
            .then { result in
                Promise { fulfill, _ in
                    fulfill((result as? Bool) ?? false)
                }
            }
    }
    
    private func triggerLazyLoad(webView: WKWebView, pattern: [String: Any]) -> Promise<Bool> {
        let triggerScript = """
        (function() {
            // Intersection Observer 기반 lazy load 트리거
            const lazyElements = document.querySelectorAll('[data-lazy], [loading="lazy"], .lazy-load');
            let triggered = 0;
            
            lazyElements.forEach(el => {
                // 강제로 뷰포트에 들어온 것처럼 이벤트 발생
                el.classList.add('in-viewport');
                el.dispatchEvent(new Event('lazyload'));
                
                // src 속성 복원
                if (el.dataset.src && !el.src) {
                    el.src = el.dataset.src;
                    triggered++;
                }
            });
            
            // 스크롤 이벤트로 추가 트리거
            window.dispatchEvent(new Event('scroll'));
            
            return triggered > 0;
        })()
        """
        
        return executeJavaScript(triggerScript, in: webView).timeout(2.0).then { result in
            Promise { fulfill, _ in
                fulfill((result as? Bool) ?? false)
            }
        }
    }
    
    private func restoreIframes(webView: WKWebView, iframes: [[String: Any]]) -> Promise<Bool> {
        let iframeScript = """
        (function() {
            const iframes = \(convertToJSONString(iframes) ?? "[]");
            let restored = 0;
            
            for (const info of iframes) {
                const iframe = document.querySelector(info.selector);
                if (iframe && iframe.contentWindow) {
                    try {
                        iframe.contentWindow.scrollTo(info.scrollX || 0, info.scrollY || 0);
                        restored++;
                    } catch(e) {
                        // Cross-origin iframe
                        iframe.contentWindow.postMessage({
                            type: 'restoreScroll',
                            scrollX: info.scrollX || 0,
                            scrollY: info.scrollY || 0
                        }, '*');
                    }
                }
            }
            
            return restored > 0;
        })()
        """
        
        return executeJavaScript(iframeScript, in: webView).timeout(1.0).then { result in
            Promise { fulfill, _ in
                fulfill((result as? Bool) ?? false)
            }
        }
    }
    
    private func finalVerification(webView: WKWebView, targetPosition: CGPoint) -> Promise<Bool> {
        let verifyScript = """
        (function() {
            const targetY = \(targetPosition.y);
            const currentY = window.scrollY || window.pageYOffset || 0;
            const tolerance = 50;
            
            if (Math.abs(currentY - targetY) > tolerance) {
                window.scrollTo(0, targetY);
            }
            
            return Math.abs(window.scrollY - targetY) <= tolerance;
        })()
        """
        
        return executeJavaScript(verifyScript, in: webView).timeout(0.5).then { result in
            Promise { fulfill, _ in
                fulfill((result as? Bool) ?? false)
            }
        }
    }
    
    // MARK: - 🔧 **개선: 캡처 파이프라인**
    
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
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
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
        
        // 동적 렌더링 대기 (type에 따라 다르게)
        if task.type == .immediate {
            // 떠나기 전 캡처는 즉시
            performCapture(task: task, webView: webView)
        } else {
            // 도착 후 캡처는 안정성 대기
            waitForDynamicContent(in: webView) { [weak self] in
                self?.performCapture(task: task, webView: webView)
            }
        }
    }
    
    private func performCapture(task: CaptureTask, webView: WKWebView) {
        let startTime = Date()
        var captureStatus: BFCacheSnapshot.CaptureStatus = .failed
        
        // 1. Visual Snapshot
        let visualSemaphore = DispatchSemaphore(value: 0)
        var visualSnapshot: UIImage? = nil
        
        DispatchQueue.main.async {
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                visualSnapshot = image ?? self.renderWebViewToImage(webView)
                visualSemaphore.signal()
            }
        }
        _ = visualSemaphore.wait(timeout: .now() + 3.0)
        
        // 2. JSState Capture
        let jsStateSemaphore = DispatchSemaphore(value: 0)
        var jsState: [String: Any]? = nil
        
        DispatchQueue.main.async {
            let captureScript = self.generateCaptureScript()
            webView.evaluateJavaScript(captureScript) { result, _ in
                jsState = result as? [String: Any]
                jsStateSemaphore.signal()
            }
        }
        _ = jsStateSemaphore.wait(timeout: .now() + 2.0)
        
        // 3. Determine Status
        if visualSnapshot != nil && jsState != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = .visualOnly
        } else if jsState != nil {
            captureStatus = .partial
        }
        
        // 4. Create Snapshot
        let scrollPosition = DispatchQueue.main.sync { webView.scrollView.contentOffset }
        let contentSize = DispatchQueue.main.sync { webView.scrollView.contentSize }
        let viewportSize = DispatchQueue.main.sync { webView.bounds.size }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: task.pageRecord,
            scrollPosition: scrollPosition,
            scrollPositionPercent: calculateScrollPercent(scrollPosition, contentSize: contentSize, viewportSize: viewportSize),
            contentSize: contentSize,
            viewportSize: viewportSize,
            actualScrollableSize: contentSize,
            jsState: jsState,
            timestamp: Date(),
            captureStatus: captureStatus,
            version: getNextVersion(for: task.pageRecord.id)
        )
        
        // 5. Save
        if let tabID = task.tabID {
            saveToDisk(snapshot: (snapshot, visualSnapshot), tabID: tabID)
        }
        
        pendingCaptures.remove(task.pageRecord.id)
        
        let captureTime = Date().timeIntervalSince(startTime)
        dbg("✅ 캡처 완료: \(task.pageRecord.title) - \(captureStatus.rawValue) (\(String(format: "%.2f", captureTime))초)")
    }
    
    // MARK: - 💾 **개선: Storage Manager**
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // Save image
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    try? jpegData.write(to: imagePath)
                    finalSnapshot.webViewSnapshotPath = imagePath.path
                }
            }
            
            // Save state
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                try? stateData.write(to: statePath)
            }
            
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            // Cleanup old versions (keep latest 3)
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
            
            self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
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
    
    // MARK: - 헬퍼 메서드들
    
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
        setActiveTransition(context, for: tabID)
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func performNavigationWithFixedTiming(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            removeActiveTransition(for: context.tabID)
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
        
        tryBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.removeActiveTransition(for: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - BFCache \(success ? "성공" : "실패")")
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
            performProgressiveRestore(webView: webView, snapshot: snapshot, completion: completion)
        } else {
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                completion(false)
            }
        }
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
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    private func generateCaptureScript() -> String {
        return """
        (function() {
            try {
                // Viewport Anchor Detection
                function findViewportAnchor() {
                    const candidates = document.querySelectorAll('article, h1, h2, h3, .post, .content, main');
                    let bestAnchor = null;
                    let bestScore = -1;
                    
                    for (const el of candidates) {
                        const rect = el.getBoundingClientRect();
                        if (rect.top >= 0 && rect.top < window.innerHeight) {
                            const score = (window.innerHeight - rect.top) * rect.width * rect.height;
                            if (score > bestScore) {
                                bestScore = score;
                                bestAnchor = {
                                    selector: el.id ? '#' + el.id : el.className ? '.' + el.className.split(' ')[0] : el.tagName.toLowerCase(),
                                    offsetFromTop: window.scrollY - (window.scrollY + rect.top),
                                    offsetFromLeft: window.scrollX - (window.scrollX + rect.left),
                                    elementRect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}
                                };
                            }
                        }
                    }
                    return bestAnchor;
                }
                
                // Scrollable Elements Detection
                function findScrollableElements() {
                    const scrollables = [];
                    const elements = document.querySelectorAll('*');
                    
                    for (const el of elements) {
                        if (scrollables.length >= 100) break;
                        
                        const style = window.getComputedStyle(el);
                        if ((style.overflowY === 'auto' || style.overflowY === 'scroll') &&
                            el.scrollHeight > el.clientHeight && el.scrollTop > 0) {
                            scrollables.push({
                                selector: el.id ? '#' + el.id : el.className ? '.' + el.className.split(' ')[0] : el.tagName.toLowerCase(),
                                scrollTop: el.scrollTop,
                                scrollLeft: el.scrollLeft,
                                scrollPercent: {
                                    x: el.scrollLeft / (el.scrollWidth - el.clientWidth) * 100,
                                    y: el.scrollTop / (el.scrollHeight - el.clientHeight) * 100
                                },
                                maxScroll: {
                                    width: el.scrollWidth - el.clientWidth,
                                    height: el.scrollHeight - el.clientHeight
                                },
                                dataAttributes: Array.from(el.attributes)
                                    .filter(a => a.name.startsWith('data-'))
                                    .reduce((acc, a) => ({...acc, [a.name]: a.value}), {})
                            });
                        }
                    }
                    return scrollables;
                }
                
                // Iframe State Detection
                function findIframes() {
                    const iframes = [];
                    document.querySelectorAll('iframe').forEach(iframe => {
                        try {
                            iframes.push({
                                selector: iframe.id ? '#' + iframe.id : 'iframe[src*="' + (iframe.src || '').split('/').pop() + '"]',
                                scrollX: iframe.contentWindow.scrollX || 0,
                                scrollY: iframe.contentWindow.scrollY || 0,
                                src: iframe.src || '',
                                crossOrigin: false
                            });
                        } catch(e) {
                            iframes.push({
                                selector: iframe.id ? '#' + iframe.id : 'iframe',
                                scrollX: 0,
                                scrollY: 0,
                                src: iframe.src || '',
                                crossOrigin: true
                            });
                        }
                    });
                    return iframes;
                }
                
                // Lazy Load Pattern Detection
                function detectLazyLoadPattern() {
                    const hasIntersection = document.querySelectorAll('[data-lazy], [loading="lazy"]').length > 0;
                    const hasScrollTrigger = document.querySelectorAll('.lazy-load, .infinite-scroll').length > 0;
                    
                    if (!hasIntersection && !hasScrollTrigger) return null;
                    
                    return {
                        type: hasIntersection ? 'intersection' : 'scroll',
                        triggerElements: Array.from(document.querySelectorAll('[data-lazy], [loading="lazy"], .lazy-load'))
                            .slice(0, 10)
                            .map(el => el.id || el.className || el.tagName.toLowerCase()),
                        containerSelector: document.querySelector('.infinite-scroll-container, .feed, .timeline')?.className || null
                    };
                }
                
                // Dynamic Content State
                function analyzeDynamicContent() {
                    const stickyHeader = document.querySelector('header[style*="sticky"], nav[style*="sticky"], [class*="sticky-header"]');
                    
                    return {
                        hasInfiniteScroll: document.querySelector('.infinite-scroll, [data-infinite-scroll]') !== null,
                        hasStickyHeader: stickyHeader !== null,
                        stickyHeaderHeight: stickyHeader ? stickyHeader.offsetHeight : 0,
                        contentStabilityScore: 1.0  // Placeholder
                    };
                }
                
                return {
                    viewportAnchor: findViewportAnchor(),
                    scrollElements: findScrollableElements(),
                    iframes: findIframes(),
                    lazyLoadPattern: detectLazyLoadPattern(),
                    dynamicContentState: analyzeDynamicContent(),
                    timestamp: Date.now()
                };
            } catch(e) {
                return {
                    viewportAnchor: null,
                    scrollElements: [],
                    iframes: [],
                    lazyLoadPattern: null,
                    dynamicContentState: null,
                    timestamp: Date.now()
                };
            }
        })()
        """
    }
    
    // MARK: - Thread-safe accessors
    
    private func setActiveTransition(_ context: TransitionContext, for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions[tabID] = context
        }
    }
    
    private func removeActiveTransition(for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions.removeValue(forKey: tabID)
        }
    }
    
    private func getActiveTransition(for tabID: UUID) -> TransitionContext? {
        return gestureQueue.sync { _activeTransitions[tabID] }
    }
    
    private func setGestureContext(_ context: GestureContext, for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._gestureContexts[key] = context
        }
    }
    
    private func removeGestureContext(for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            if let context = self._gestureContexts.removeValue(forKey: key) {
                context.invalidate()
            }
        }
    }
    
    private func getGestureContext(for key: UUID) -> GestureContext? {
        return gestureQueue.sync { _gestureContexts[key] }
    }
    
    private func setMemoryCache(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache[pageID] = snapshot
        }
    }
    
    private func setDiskIndex(_ path: String, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._diskCacheIndex[pageID] = path
        }
    }
    
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
    
    private func getNextVersion(for pageID: UUID) -> Int {
        return cacheAccessQueue.sync(flags: .barrier) {
            let currentVersion = self._cacheVersion[pageID] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageID] = newVersion
            return newVersion
        }
    }
    
    private func calculateScrollPercent(_ position: CGPoint, contentSize: CGSize, viewportSize: CGSize) -> CGPoint {
        let maxScrollX = max(0, contentSize.width - viewportSize.width)
        let maxScrollY = max(0, contentSize.height - viewportSize.height)
        
        return CGPoint(
            x: maxScrollX > 0 ? (position.x / maxScrollX * 100.0) : 0,
            y: maxScrollY > 0 ? (position.y / maxScrollY * 100.0) : 0
        )
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private func convertToJSONString(_ object: Any) -> String? {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: object, options: [])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    // MARK: - Setup & Cleanup
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        webView.allowsBackForwardNavigationGestures = false
        
        guard let tabID = stateModel.tabID else {
            dbg("🧵 탭 ID 없음 - 제스처 설정 스킵")
            return
        }
        
        cleanupExistingGestures(for: webView, tabID: tabID)
        
        let gestureContext = GestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
        setGestureContext(gestureContext, for: tabID)
        
        DispatchQueue.main.async { [weak self] in
            self?.createAndAttachGestures(webView: webView, tabID: tabID)
        }
        
        dbg("🎯 BFCache 제스처 설정 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    private func cleanupExistingGestures(for webView: WKWebView, tabID: UUID) {
        removeGestureContext(for: tabID)
        
        webView.gestureRecognizers?.forEach { gesture in
            if let edgeGesture = gesture as? UIScreenEdgePanGestureRecognizer,
               edgeGesture.edges == .left || edgeGesture.edges == .right {
                webView.removeGestureRecognizer(gesture)
                dbg("🧵 기존 제스처 제거: \(edgeGesture.edges)")
            }
        }
    }
    
    private func createAndAttachGestures(webView: WKWebView, tabID: UUID) {
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        
        objc_setAssociatedObject(leftEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(rightEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        webView.addGestureRecognizer(leftEdge)
        webView.addGestureRecognizer(rightEdge)
        
        dbg("🧵 제스처 연결 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
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
                                let statePath = pageDir.appendingPathComponent("state.json")
                                if let data = try? Data(contentsOf: statePath),
                                   let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                                    
                                    self.setDiskIndex(pageDir.path, for: snapshot.pageRecord.id)
                                    self.cacheAccessQueue.async(flags: .barrier) {
                                        self._cacheVersion[snapshot.pageRecord.id] = snapshot.version
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
    
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        removeGestureContext(for: tabID)
        removeActiveTransition(for: tabID)
        
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
            try? FileManager.default.removeItem(at: tabDir)
            self.dbg("🗑️ 탭 캐시 완전 삭제: \(tabID.uuidString)")
        }
    }
    
    // MARK: - Public Wrappers
    
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
    }
    
    // MARK: - Debug
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[BFCache🎯] \(msg)")
    }
    
    // MARK: - JavaScript
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🎯 BFCache 페이지 복원');
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 BFCache 페이지 저장');
            }
        });
        
        // Cross-origin iframe 스크롤 복원 리스너
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                try {
                    window.scrollTo(event.data.scrollX || 0, event.data.scrollY || 0);
                } catch(e) {
                    console.error('Cross-origin iframe 스크롤 복원 실패:', e);
                }
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

// MARK: - UIGestureRecognizerDelegate
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - CustomWebView Integration
extension BFCacheTransitionSystem {
    
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        shared.setupGestures(for: webView, stateModel: stateModel)
        TabPersistenceManager.debugMessages.append("✅ BFCache 시스템 설치 완료")
    }
    
    static func uninstall(from webView: WKWebView) {
        if let tabIDString = webView.gestureRecognizers?.compactMap({ gesture in
            objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String
        }).first, let tabID = UUID(uuidString: tabIDString) {
            shared.removeGestureContext(for: tabID)
            shared.removeActiveTransition(for: tabID)
        }
        
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        TabPersistenceManager.debugMessages.append("BFCache 시스템 제거 완료")
    }
    
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
}
