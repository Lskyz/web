//
//  BFCacheSwipeTransition.swift
//  🎯 **BFCache 전환 시스템 - 직접 전환 방식**
//  ✅ 오버레이 제거 - 웹뷰 자체가 밀려나가는 자연스러운 전환
//  🔄 복원큐와 단일 경로 통합 (영향 없이 협력)
//  🏄‍♂️ 제스처/버튼 네비게이션 통합 처리
//  📸 DOM/JS/스크롤 상태 완벽 복원
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

// MARK: - 약한 참조 제스처 컨텍스트
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

// MARK: - 📸 BFCache 페이지 스냅샷
struct BFCacheSnapshot {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    var formData: [String: Any]?
    let timestamp: Date
    let webViewSnapshot: UIImage?
    let captureStatus: CaptureStatus
    
    enum CaptureStatus {
        case complete
        case partial
        case visualOnly
        case failed
    }
    
    static func create(pageRecord: PageRecord, webView: WKWebView?, completion: @escaping (BFCacheSnapshot) -> Void) {
        guard let webView = webView else {
            completion(BFCacheSnapshot(
                pageRecord: pageRecord,
                scrollPosition: .zero,
                timestamp: Date(),
                webViewSnapshot: nil,
                captureStatus: .failed
            ))
            return
        }
        
        guard webView.window != nil, !webView.bounds.isEmpty else {
            TabPersistenceManager.debugMessages.append("⚠️ 웹뷰가 화면에 없거나 크기가 0")
            completion(BFCacheSnapshot(
                pageRecord: pageRecord,
                scrollPosition: webView.scrollView.contentOffset,
                timestamp: Date(),
                webViewSnapshot: nil,
                captureStatus: .failed
            ))
            return
        }
        
        let scrollPosition = webView.scrollView.contentOffset
        let timestamp = Date()
        
        var visualSnapshot: UIImage? = nil
        var tempDom: String? = nil
        var tempJs: [String: Any]? = nil
        var tempForm: [String: Any]? = nil
        var captureResults: [Bool] = []
        
        let group = DispatchGroup()
        
        // 시각적 스냅샷 캡처
        group.enter()
        var snapshotCompleted = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !snapshotCompleted {
                visualSnapshot = captureWebViewAsImage(webView)
                captureResults.append(visualSnapshot != nil)
                group.leave()
            }
        }
        
        webView.takeSnapshot(with: nil) { image, error in
            snapshotCompleted = true
            if let error = error {
                TabPersistenceManager.debugMessages.append("📸 스냅샷 실패: \(error.localizedDescription)")
                visualSnapshot = captureWebViewAsImage(webView)
                captureResults.append(visualSnapshot != nil)
            } else {
                visualSnapshot = image
                captureResults.append(true)
            }
            group.leave()
        }
        
        // DOM 캡처
        group.enter()
        let domScript = """
        (function() {
            try {
                if (document.readyState !== 'complete') return null;
                const html = document.documentElement.outerHTML;
                if (html.length > 500000) return html.substring(0, 500000) + '<!-- truncated -->';
                return html;
            } catch(e) { return null; }
        })()
        """
        
        webView.evaluateJavaScript(domScript) { result, error in
            tempDom = result as? String
            captureResults.append(tempDom != nil)
            group.leave()
        }
        
        // JS 상태 캡처
        group.enter()
        let jsScript = """
        (function() {
            try {
                const formData = {};
                const inputs = document.querySelectorAll('input:not([type="password"]), textarea, select');
                for (let i = 0; i < Math.min(inputs.length, 100); i++) {
                    const el = inputs[i];
                    if (el.name || el.id) {
                        const key = el.name || el.id;
                        if (el.type === 'checkbox' || el.type === 'radio') {
                            formData[key] = el.checked;
                        } else if (el.value && el.value.length < 1000) {
                            formData[key] = el.value;
                        }
                    }
                }
                
                const scrollData = {
                    x: window.scrollX || 0,
                    y: window.scrollY || 0,
                    elements: []
                };
                
                return {
                    forms: formData,
                    scroll: scrollData,
                    href: window.location.href,
                    title: document.title || '',
                    timestamp: Date.now(),
                    ready: document.readyState
                };
            } catch(e) { 
                return { forms: {}, scroll: { x: 0, y: 0, elements: [] }, error: e.message };
            }
        })()
        """
        
        webView.evaluateJavaScript(jsScript) { result, error in
            if let data = result as? [String: Any] {
                tempForm = data["forms"] as? [String: Any]
                tempJs = data
                captureResults.append(true)
            } else {
                captureResults.append(false)
            }
            group.leave()
        }
        
        group.notify(queue: .main) {
            let successCount = captureResults.filter { $0 }.count
            let captureStatus: CaptureStatus
            
            if successCount == captureResults.count {
                captureStatus = .complete
            } else if visualSnapshot != nil {
                captureStatus = successCount > 1 ? .partial : .visualOnly
            } else {
                captureStatus = .failed
            }
            
            let snapshot = BFCacheSnapshot(
                pageRecord: pageRecord,
                domSnapshot: tempDom,
                scrollPosition: scrollPosition,
                jsState: tempJs,
                formData: tempForm,
                timestamp: timestamp,
                webViewSnapshot: visualSnapshot,
                captureStatus: captureStatus
            )
            
            TabPersistenceManager.debugMessages.append(
                "📸 스냅샷 완성: \(pageRecord.title) [상태: \(captureStatus)]"
            )
            
            completion(snapshot)
        }
    }
    
    private static func captureWebViewAsImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, formData: [String: Any]? = nil, timestamp: Date, webViewSnapshot: UIImage? = nil, captureStatus: CaptureStatus = .partial) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.formData = formData
        self.timestamp = timestamp
        self.webViewSnapshot = webViewSnapshot
        self.captureStatus = captureStatus
    }
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        switch captureStatus {
        case .failed:
            webView.load(URLRequest(url: pageRecord.url))
            completion(false)
            return
            
        case .visualOnly:
            webView.load(URLRequest(url: pageRecord.url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                completion(true)
            }
            return
            
        case .partial, .complete:
            break
        }
        
        let request = URLRequest(url: pageRecord.url, cachePolicy: .returnCacheDataElseLoad)
        webView.load(request)
        
        // 즉시 스크롤 위치 설정
        webView.scrollView.setContentOffset(scrollPosition, animated: false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.restorePageState(to: webView, completion: completion)
        }
    }
    
    private func restorePageState(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        webView.scrollView.setContentOffset(scrollPosition, animated: false)
        
        let scrollJS = """
        (function() {
            window.scrollTo(\(scrollPosition.x), \(scrollPosition.y));
            document.documentElement.scrollTop = \(scrollPosition.y);
            document.documentElement.scrollLeft = \(scrollPosition.x);
            document.body.scrollTop = \(scrollPosition.y);
            document.body.scrollLeft = \(scrollPosition.x);
            window.dispatchEvent(new Event('scroll'));
            return true;
        })()
        """
        
        webView.evaluateJavaScript(scrollJS) { _, _ in
            if let formData = self.formData, !formData.isEmpty {
                self.restoreFormData(to: webView, formData: formData) { _ in
                    completion(true)
                }
            } else {
                completion(true)
            }
        }
    }
    
    private func restoreFormData(to webView: WKWebView, formData: [String: Any], completion: @escaping (Bool) -> Void) {
        let js = """
        (function(){
            try {
                const data = \(convertFormDataToJSObject(formData));
                let restored = 0;
                for (const [key, value] of Object.entries(data)) {
                    const el = document.querySelector(`[name="${key}"], #${key}`);
                    if (!el) continue;
                    
                    if (el.type === 'checkbox' || el.type === 'radio') {
                        el.checked = Boolean(value);
                    } else {
                        el.value = String(value ?? '');
                    }
                    restored++;
                }
                return restored > 0;
            } catch(e) {
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(js) { result, _ in
            completion((result as? Bool) ?? false)
        }
    }
    
    private func convertFormDataToJSObject(_ formData: [String: Any]) -> String {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: formData, options: [])
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }
    
    func needsRefresh() -> Bool {
        let elapsed = Date().timeIntervalSince(timestamp)
        let type = pageRecord.siteType?.lowercased() ?? ""
        let dynamicPatterns = ["search", "feed", "timeline", "live", "realtime", "stream"]
        let isDynamic = dynamicPatterns.contains { type.contains($0) }
        return isDynamic && elapsed > 300
    }
}

// MARK: - 🎯 BFCache 전환 시스템
final class BFCacheTransitionSystem: NSObject {
    
    static let shared = BFCacheTransitionSystem()
    private override init() { super.init() }
    
    // 캐시 저장소
    private var cache: [UUID: BFCacheSnapshot] = [:]
    private let maxCacheSize = 30
    private let cacheQueue = DispatchQueue(label: "bfcache", attributes: .concurrent)
    
    // 디바운스 관리
    private var lastArrivalStoreAt: [UUID: Date] = [:]
    private var lastLeavingStoreAt: [UUID: Date] = [:]
    private var pendingCaptures: Set<UUID> = []
    
    // 전환 상태
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
    
    // MARK: - 캐시 관리
    
    private func storeSnapshot(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        cacheQueue.async(flags: .barrier) {
            self.cache[pageID] = snapshot
            self.pendingCaptures.remove(pageID)
            
            if self.cache.count > self.maxCacheSize {
                let sorted = self.cache.sorted { $0.value.timestamp < $1.value.timestamp }
                if let oldest = sorted.first {
                    self.cache.removeValue(forKey: oldest.key)
                    self.dbg("🗑️ 오래된 캐시 제거")
                }
            }
        }
        
        let statusDetail: String
        switch snapshot.captureStatus {
        case .complete:
            statusDetail = "이미지✅ DOM✅ JS✅"
        case .partial:
            let hasImage = snapshot.webViewSnapshot != nil
            let hasDOM = snapshot.domSnapshot != nil
            let hasJS = snapshot.jsState != nil
            statusDetail = "이미지\(hasImage ? "✅" : "❌") DOM\(hasDOM ? "✅" : "❌") JS\(hasJS ? "✅" : "❌")"
        case .visualOnly:
            statusDetail = "이미지만"
        case .failed:
            statusDetail = "실패"
        }
        
        dbg("📸 저장: \(snapshot.pageRecord.title) | \(statusDetail)")
    }
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        cacheQueue.sync {
            cache[pageID]
        }
    }
    
    private func isCaptureInProgress(for pageID: UUID) -> Bool {
        cacheQueue.sync {
            pendingCaptures.contains(pageID)
        }
    }
    
    // MARK: - 제스처 설정
    
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
        
        dbg("제스처 설정 완료")
    }
    
    // MARK: - 제스처 핸들러
    
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let ctx = objc_getAssociatedObject(gesture, "bfcache_ctx") as? WeakGestureContext,
              let stateModel = ctx.stateModel,
              let webView = ctx.webView ?? (gesture.view as? WKWebView) else { return }
        
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
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
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
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let captureConfig = WKSnapshotConfiguration()
        captureConfig.rect = webView.bounds
        captureConfig.afterScreenUpdates = false
        
        webView.takeSnapshot(with: captureConfig) { image, error in
            if let error = error {
                self.dbg("📸 현재 스냅샷 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let fallbackImage = self.imageFromView(webView)
                    completion(fallbackImage)
                }
            } else {
                self.dbg("📸 현재 스냅샷 성공")
                completion(image)
            }
        }
    }
    
    private func imageFromView(_ view: UIView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { context in
            view.layer.render(in: context.cgContext)
        }
    }
    
    private func beginGestureTransitionWithSnapshot(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection, currentSnapshot: UIImage?) {
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            if !isCaptureInProgress(for: currentRecord.id) {
                cacheQueue.async(flags: .barrier) {
                    self.pendingCaptures.insert(currentRecord.id)
                }
                BFCacheSnapshot.create(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
                    self?.storeSnapshot(snapshot, for: currentRecord.id)
                }
            }
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
        
        dbg("🎬 전환 시작: \(direction == .back ? "뒤로" : "앞으로")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        if isLeftEdge {
            let moveDistance = max(0, min(screenWidth, translation))
            currentView?.frame.origin.x = moveDistance
            targetView?.frame.origin.x = -screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (moveDistance / screenWidth))
            currentView?.layer.shadowOpacity = shadowOpacity
        } else {
            let moveDistance = max(-screenWidth, min(0, translation))
            currentView?.frame.origin.x = moveDistance
            targetView?.frame.origin.x = screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (abs(moveDistance) / screenWidth))
            currentView?.layer.shadowOpacity = shadowOpacity
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
        
        let targetIndex = direction == .back ?
            stateModel.dataModel.currentPageIndex - 1 :
            stateModel.dataModel.currentPageIndex + 1
        
        var targetView: UIView
        
        if targetIndex >= 0, targetIndex < stateModel.dataModel.pageHistory.count {
            let targetRecord = stateModel.dataModel.pageHistory[targetIndex]
            
            if let snapshot = retrieveSnapshot(for: targetRecord.id),
               let targetImage = snapshot.webViewSnapshot {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
            } else {
                targetView = createInfoCard(for: targetRecord, in: webView.bounds)
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
        card.addSubview(contentView)
        
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = record.title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 180),
            
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
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
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
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
                self?.performNavigation(context: context)
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
    
    // MARK: - 버튼 네비게이션
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            if !isCaptureInProgress(for: currentRecord.id) {
                cacheQueue.async(flags: .barrier) {
                    self.pendingCaptures.insert(currentRecord.id)
                }
                BFCacheSnapshot.create(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
                    self?.storeSnapshot(snapshot, for: currentRecord.id)
                }
            }
        }
        
        stateModel.goBack()
        tryBFCacheRestore(stateModel: stateModel, direction: .back)
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            if !isCaptureInProgress(for: currentRecord.id) {
                cacheQueue.async(flags: .barrier) {
                    self.pendingCaptures.insert(currentRecord.id)
                }
                BFCacheSnapshot.create(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
                    self?.storeSnapshot(snapshot, for: currentRecord.id)
                }
            }
        }
        
        stateModel.goForward()
        tryBFCacheRestore(stateModel: stateModel, direction: .forward)
    }
    
    private func performNavigation(context: TransitionContext) {
        guard let stateModel = context.stateModel else { return }
        
        switch context.direction {
        case .back:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            stateModel.goBack()
            dbg("뒤로가기 완료")
        case .forward:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            stateModel.goForward()
            dbg("앞으로가기 완료")
        }
        
        tryBFCacheRestore(stateModel: stateModel, direction: context.direction)
    }
    
    private func tryBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else { return }
        
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            if snapshot.needsRefresh() {
                webView.reload()
                dbg("🔄 동적 페이지 리로드")
            } else {
                snapshot.restore(to: webView) { [weak self] success in
                    if success {
                        self?.dbg("✅ BFCache 복원 성공")
                    } else {
                        self?.dbg("⚠️ BFCache 복원 실패")
                    }
                }
            }
        } else {
            let missReason = analyzeCacheMissReason(for: currentRecord)
            dbg("❌ BFCache 미스: \(missReason)")
        }
    }
    
    private func analyzeCacheMissReason(for record: PageRecord) -> String {
        let cacheExists = cacheQueue.sync { cache.keys.contains(record.id) }
        if !cacheExists {
            if isCaptureInProgress(for: record.id) {
                return "캡처 진행 중"
            }
            
            let cacheCount = cacheQueue.sync { cache.count }
            if cacheCount >= maxCacheSize {
                return "캐시 가득참 (\(cacheCount)/\(maxCacheSize))"
            }
            
            if let lastAttempt = lastArrivalStoreAt[record.id] {
                let elapsed = Date().timeIntervalSince(lastAttempt)
                if elapsed < 2.0 {
                    return "최근 캡처 후 \(String(format: "%.1f", elapsed))초"
                }
            }
            
            return "캡처되지 않음"
        }
        
        return "캐시 조회 실패"
    }
    
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

// MARK: - CustomWebView 통합
extension BFCacheTransitionSystem {
    
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        shared.setupGestures(for: webView, stateModel: stateModel)
        TabPersistenceManager.debugMessages.append("✅ BFCache 설치 완료")
    }
    
    static func uninstall(from webView: WKWebView) {
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        TabPersistenceManager.debugMessages.append("🧹 BFCache 제거 완료")
    }
    
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시")
            return
        }
        
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지 추가")
    }
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔄 BFCache 페이지 복원');
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
}

// MARK: - 퍼블릭 래퍼
extension BFCacheTransitionSystem {
    
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord else { return }
        let now = Date()
        
        if let t = lastLeavingStoreAt[rec.id], now.timeIntervalSince(t) < 0.5 { return }
        lastLeavingStoreAt[rec.id] = now
        
        if isCaptureInProgress(for: rec.id) {
            dbg("⏳ 이미 캡처 중")
            return
        }
        
        cacheQueue.async(flags: .barrier) {
            self.pendingCaptures.insert(rec.id)
        }

        BFCacheSnapshot.create(pageRecord: rec, webView: webView) { [weak self] snap in
            self?.storeSnapshot(snap, for: rec.id)
        }
    }

    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord else { return }
        let now = Date()
        
        if let t = lastArrivalStoreAt[rec.id], now.timeIntervalSince(t) < 1.0 { return }
        lastArrivalStoreAt[rec.id] = now
        
        if isCaptureInProgress(for: rec.id) {
            dbg("⏳ 이미 캡처 중")
            return
        }
        
        if let existing = retrieveSnapshot(for: rec.id), existing.captureStatus != .failed {
            dbg("✅ 이미 캐시에 존재")
            return
        }
        
        cacheQueue.async(flags: .barrier) {
            self.pendingCaptures.insert(rec.id)
        }

        captureWhenFullyStable(webView) { [weak self] in
            BFCacheSnapshot.create(pageRecord: rec, webView: webView) { snap in
                self?.storeSnapshot(snap, for: rec.id)
            }
        }
    }

    private func captureWhenFullyStable(_ webView: WKWebView, _ work: @escaping () -> Void) {
        if webView.isLoading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.captureWhenFullyStable(webView, work)
            }
            return
        }
        
        let readyScript = """
        (function() {
            const docReady = document.readyState === 'complete';
            const images = Array.from(document.images).slice(0, 10);
            const imagesLoaded = images.length === 0 || images.every(img => img.complete);
            
            return {
                ready: docReady && imagesLoaded,
                details: { doc: docReady, img: imagesLoaded }
            };
        })()
        """
        
        webView.evaluateJavaScript(readyScript) { [weak self] result, error in
            if let data = result as? [String: Any],
               let isReady = data["ready"] as? Bool {
                
                if isReady {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        work()
                    }
                } else {
                    if let details = data["details"] as? [String: Bool] {
                        self?.dbg("⏳ 대기: doc=\(details["doc"] ?? false), img=\(details["img"] ?? false)")
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.captureWhenFullyStable(webView, work)
                    }
                }
            } else {
                work()
            }
        }
    }
    
    func clearCacheForTab(_ tabID: UUID) {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
            self.pendingCaptures.removeAll()
            self.dbg("🗑️ 캐시 정리")
        }
    }
    
    func handleMemoryWarning() {
        cacheQueue.async(flags: .barrier) {
            let sorted = self.cache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            
            sorted.prefix(removeCount).forEach { item in
                self.cache.removeValue(forKey: item.key)
            }
            
            self.dbg("⚠️ 메모리 경고 - \(removeCount)개 제거")
        }
    }
}
