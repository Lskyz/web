//
//  BFCacheSwipeTransition.swift
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

// MARK: - 📸 BFCache 페이지 스냅샷 (간소화)
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
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
    
    init(pageRecord: PageRecord, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1) {
        self.pageRecord = pageRecord
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
}

// MARK: - 🎯 **강화된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 큐 시스템
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // MARK: - 💾 캐시 시스템
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
    
    // MARK: - 🔧 단순화된 캡처 (이미지만)
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, tabID: UUID? = nil) {
        guard let webView = webView else { return }
        
        serialQueue.async { [weak self] in
            self?.performSimpleCapture(pageRecord: pageRecord, webView: webView, tabID: tabID)
        }
    }
    
    private func performSimpleCapture(pageRecord: PageRecord, webView: WKWebView, tabID: UUID?) {
        mainSyncOrNow {
            // JavaScript로 스크롤 상태 저장 호출
            webView.evaluateJavaScript("window.__saveScrollState && window.__saveScrollState()") { _, _ in
                // 상태 저장 완료
            }
            
            // 스냅샷 캡처
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { [weak self] image, error in
                guard let self = self else { return }
                
                let version = (self._cacheVersion[pageRecord.id] ?? 0) + 1
                self._cacheVersion[pageRecord.id] = version
                
                var snapshot = BFCacheSnapshot(
                    pageRecord: pageRecord,
                    timestamp: Date(),
                    captureStatus: image != nil ? .visualOnly : .failed,
                    version: version
                )
                
                if let image = image, let tabID = tabID {
                    // 이미지 디스크 저장
                    self.saveImageToDisk(image: image, snapshot: &snapshot, tabID: tabID)
                }
                
                self.setMemoryCache(snapshot, for: pageRecord.id)
                self.dbg("📸 스냅샷 캡처: \(pageRecord.title)")
            }
        }
    }
    
    private func saveImageToDisk(image: UIImage, snapshot: inout BFCacheSnapshot, tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageDir = self.pageDirectory(for: snapshot.pageRecord.id, tabID: tabID, version: snapshot.version)
            self.createDirectoryIfNeeded(at: pageDir)
            
            let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
            if let jpegData = image.jpegData(compressionQuality: 0.7) {
                do {
                    try jpegData.write(to: imagePath)
                    snapshot.webViewSnapshotPath = imagePath.path
                    self.dbg("💾 이미지 저장: \(snapshot.pageRecord.title)")
                } catch {
                    self.dbg("❌ 이미지 저장 실패: \(error)")
                }
            }
        }
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    // MARK: - 🔍 스냅샷 조회
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            return snapshot
        }
        return nil
    }
    
    func hasCache(for pageID: UUID) -> Bool {
        return cacheAccessQueue.sync { _memoryCache[pageID] } != nil
    }
    
    // MARK: - 캐시 정리
    
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
            try? FileManager.default.removeItem(at: tabDir)
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
            
            self.dbg("⚠️ 메모리 경고 - 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    private func loadDiskCacheIndex() {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            self.createDirectoryIfNeeded(at: self.bfCacheDirectory)
            // 간단한 인덱스 로드 로직
        }
    }
    
    // MARK: - 🎯 제스처 시스템
    
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
                gesture.state = .cancelled
                return
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, tabID: tabID)
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
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let captureConfig = WKSnapshotConfiguration()
        captureConfig.rect = webView.bounds
        captureConfig.afterScreenUpdates = false
        
        webView.takeSnapshot(with: captureConfig) { image, error in
            if let error = error {
                self.dbg("📸 현재 페이지 스냅샷 실패: \(error.localizedDescription)")
                completion(self.renderWebViewToImage(webView))
            } else {
                completion(image)
            }
        }
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
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
        
        dbg("🎬 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = activeTransitions[tabID],
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = context.webView?.bounds.width ?? 375
        let currentWebView = previewContainer.viewWithTag(1001)
        let targetPreview = previewContainer.viewWithTag(1002)
        
        if isLeftEdge {
            let moveDistance = max(0, min(screenWidth, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = -screenWidth + moveDistance
            currentWebView?.layer.shadowOpacity = Float(0.3 * (moveDistance / screenWidth))
        } else {
            let moveDistance = max(-screenWidth, min(0, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = screenWidth + moveDistance
            currentWebView?.layer.shadowOpacity = Float(0.3 * (abs(moveDistance) / screenWidth))
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
               let targetImage = snapshot.loadImage() {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
                dbg("📸 타겟 페이지 스냅샷 사용: \(targetRecord.title)")
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
        card.addSubview(contentView)
        
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
        contentView.addSubview(urlLabel)
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 120),
            
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -15),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
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
                self?.performNavigation(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    private func performNavigation(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 네비게이션 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("⬅️ 뒤로가기 수행")
        case .forward:
            stateModel.goForward()
            dbg("➡️ 앞으로가기 수행")
        }
        
        // JavaScript 스크롤 복원이 pageshow 이벤트에서 자동으로 실행됨
        // 약간의 딜레이 후 미리보기 정리
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            previewContainer.removeFromSuperview()
            self.activeTransitions.removeValue(forKey: context.tabID)
            self.dbg("🎬 미리보기 정리 완료")
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
            captureSnapshot(pageRecord: currentRecord, webView: webView, tabID: tabID)
        }
        
        stateModel.goBack()
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, tabID: tabID)
        }
        
        stateModel.goForward()
    }
    
    // MARK: - 🌐 JavaScript 스크립트 (제시하신 방법 통합)
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        // ================ 동적 스크롤 복원 시스템 ================
        (function () {
          if (window.__sr_installed__) return;
          window.__sr_installed__ = true;

          // 1) 기본 복원 끄기 (우리가 복원)
          try { if ('scrollRestoration' in history) { history.scrollRestoration = 'manual'; } } catch (e) {}

          // CSS.escape polyfill
          if (!window.CSS) window.CSS = {};
          if (typeof CSS.escape !== 'function') {
            CSS.escape = function(value) {
              return String(value).replace(/[^a-zA-Z0-9_\\-]/g, '\\\\$&');
            };
          }

          // 유틸
          const H = s => {
            s = (s||'').slice(0,256);
            let x=0;
            for (let i=0;i<s.length;i++) x=(x*31+s.charCodeAt(i))|0;
            return x;
          };
          
          const vvH = () => (window.visualViewport && window.visualViewport.height) || window.innerHeight;
          
          const safeQuery = sel => {
            try { return document.querySelector(sel); } catch { return null; }
          };
          
          const cssPath = el => {
            if (!el || el === document.body) return null;
            if (el.id) return '#'+CSS.escape(el.id);
            const p = [];
            while (el && el.nodeType === 1 && p.length < 5) {
              let s = el.nodeName.toLowerCase();
              if (el.id) {
                s = '#'+CSS.escape(el.id);
                p.unshift(s);
                break;
              }
              let idx = 1, sib = el;
              while ((sib = sib.previousElementSibling) && idx < 10) {
                if (sib.nodeName === el.nodeName) idx++;
              }
              p.unshift(idx>1 ? `${s}:nth-of-type(${idx})` : s);
              el = el.parentElement;
            }
            return p.length ? p.join('>') : null;
          };

          // 스크롤 가능한 컨테이너 수집
          const collectContainers = () => {
            const sels = ['[data-scroll]','.scroll','.scrollable','.list','.feed','.content','.container'];
            const seen = new Set(), out = [];
            sels.forEach(sel => {
              document.querySelectorAll(sel).forEach(el => {
                if (seen.has(el)) return;
                seen.add(el);
                const st = getComputedStyle(el);
                if (/(auto|scroll)/.test(st.overflow+st.overflowY+st.overflowX)) {
                  out.push({
                    sel: sel,
                    path: cssPath(el),
                    top: el.scrollTop||0,
                    left: el.scrollLeft||0
                  });
                }
              });
            });
            return out;
          };

          // 뷰포트 중앙 앵커
          const captureAnchor = () => {
            const center = vvH()/2;
            const pool = document.querySelectorAll('article,[role="article"],[data-key],[data-id],li,a[href],img[src],section,[id]');
            let best=null, dist=1e9;
            pool.forEach(el=>{
              const r = el.getBoundingClientRect();
              const mid = r.top + r.height/2;
              const d = Math.abs(mid - center);
              if (d < dist) {
                dist = d;
                best = el;
              }
            });
            if (!best) return null;
            return {
              sel: best.id ? '#'+CSS.escape(best.id) : null,
              key: best.getAttribute('data-key') || best.getAttribute('data-id') ||
                   best.getAttribute('data-item-id') || best.getAttribute('href') ||
                   best.getAttribute('src') || null,
              hash: H((best.textContent||'').trim())
            };
          };

          // 상태 저장
          function saveState() {
            const doc = document.documentElement;
            const vh = vvH();
            const maxTop = Math.max(0, (doc.scrollHeight||0) - vh);
            const y = window.scrollY || document.documentElement.scrollTop || 0;

            const state = {
              ver: 1,
              ts: Date.now(),
              scroll: { y, ratio: maxTop>0 ? Math.max(0, Math.min(1, y/maxTop)) : 0 },
              containers: collectContainers(),
              anchor: captureAnchor(),
              vv: { innerH: window.innerHeight, visualH: vvH() }
            };
            
            // History State에 저장
            try {
              const cur = history.state && typeof history.state === 'object' ? history.state : {};
              history.replaceState({ ...cur, __scroll__: state }, document.title);
              console.log('📌 스크롤 상태 저장:', state);
            } catch(e) {
              console.error('스크롤 저장 실패:', e);
            }
            return state;
          }

          // 상태 복원 (적응 루프 포함)
          async function restoreState(state) {
            if (!state || !state.scroll) return false;
            console.log('🔄 스크롤 복원 시작:', state);

            // 0) 문서 비율/픽셀 즉시 정렬
            const vh = vvH();
            const maxTop = Math.max(0, (document.documentElement.scrollHeight||0) - vh);
            const yFromRatio = Math.round((state.scroll.ratio||0) * maxTop);
            const y = Number.isFinite(yFromRatio) && yFromRatio>0 ? yFromRatio : (state.scroll.y||0);
            window.scrollTo(0, Math.max(0, Math.min(maxTop, y)));

            // 1) 앵커 복원
            if (state.anchor) {
              let el = null;
              if (state.anchor.sel) el = safeQuery(state.anchor.sel);
              if (!el && state.anchor.key) {
                el = document.querySelector(`[data-key="${state.anchor.key}"],[data-id="${state.anchor.key}"],[data-item-id="${state.anchor.key}"],a[href="${state.anchor.key}"],img[src="${state.anchor.key}"]`);
              }
              if (!el && state.anchor.hash) {
                const pool = document.querySelectorAll('article,[role="article"],[data-key],[data-id],li,a[href]');
                let best=null, diff=1e9;
                pool.forEach(e=>{
                  const h = H((e.textContent||'').trim());
                  const d = Math.abs(h - state.anchor.hash);
                  if (d < diff) {
                    diff = d;
                    best = e;
                  }
                });
                el = best;
              }
              if (el) {
                el.scrollIntoView({ block: 'center', inline: 'nearest' });
                console.log('🎯 앵커 복원:', el);
              }
            }

            // 2) 컨테이너 복원
            (state.containers||[]).forEach(c=>{
              const el = c.path ? safeQuery(c.path) : (c.sel ? safeQuery(c.sel) : null);
              if (el && typeof el.scrollTop === 'number') {
                el.scrollTop = c.top||0;
                el.scrollLeft = c.left||0;
              }
            });

            // 3) 적응 루프 (동적 로딩 보정)
            const wait = ms => new Promise(r=>setTimeout(r, ms));
            let ok = false;
            for (let i=0;i<6;i++){
              await wait(100);
              const vh2 = vvH();
              const max2 = Math.max(0, document.documentElement.scrollHeight - vh2);
              const target = Math.max(0, Math.min(max2, y));
              const err = Math.abs(window.scrollY - target);
              if (err <= 20) {
                ok = true;
                break;
              }
              window.scrollTo(0, target);
            }
            
            console.log('✅ 스크롤 복원 완료:', ok);
            return ok;
          }

          // pageshow/pagehide 이벤트
          window.addEventListener('pageshow', (e)=>{
            const st = (history.state && history.state.__scroll__) || null;
            if (st) {
              console.log('📍 pageshow - BFCache 복귀:', !!e.persisted);
              restoreState(st);
            }
            
            // Swift와 연동 (옵션)
            if (e.persisted && window.webkit?.messageHandlers?.bfcacheRestore) {
              window.webkit.messageHandlers.bfcacheRestore.postMessage({
                persisted: true,
                state: st
              });
            }
          });
          
          window.addEventListener('pagehide', (e)=>{
            saveState();
            console.log('💾 pagehide - 상태 저장 완료');
          });

          // 링크 클릭/폼 제출 시 저장
          document.addEventListener('click', (e)=>{
            const target = e.target.closest('a[href], button[type="submit"]');
            if (target) {
              saveState();
            }
          }, true);

          // 전역 노출
          window.__saveScrollState = saveState;
          window.__restoreScrollState = restoreState;
          
          console.log('✅ 동적 스크롤 복원 시스템 설치 완료');
        })();
        """
        return WKUserScript(
            source: scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }
    
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
        TabPersistenceManager.debugMessages.append("[BFCache] \(msg)")
    }
    
    // 메인스레드 재진입 안전 래퍼
    @inline(__always)
    private func mainSyncOrNow<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync { work() }
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
        TabPersistenceManager.debugMessages.append("✅ JavaScript 기반 스크롤 복원 시스템 설치 완료")
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
        
        captureSnapshot(pageRecord: rec, webView: webView, tabID: tabID)
        dbg("📸 떠나기 스냅샷 캡처: \(rec.title)")
    }
    
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처: \(rec.title)")
    }
}
