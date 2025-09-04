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

    init(pageRecord: PageRecord,
         timestamp: Date,
         webViewSnapshotPath: String? = nil,
         captureStatus: CaptureStatus = .partial,
         version: Int = 1) {
        self.pageRecord = pageRecord
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
    }

    // 이미지 로드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

// MARK: - 🎯 강화된 BFCache 전환 시스템
final class BFCacheTransitionSystem: NSObject {

    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }

    // MARK: - 큐
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)

    // MARK: - 캐시 저장소
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]  // 미래 확장용
    private var _cacheVersion: [UUID: Int] = [:]

    // 스레드 안전 접근자
    private var memoryCache: [UUID: BFCacheSnapshot] { cacheAccessQueue.sync { _memoryCache } }
    private func setMemoryCache(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) { self._memoryCache[pageID] = snapshot }
    }
    private func removeFromMemoryCache(_ pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) { self._memoryCache.removeValue(forKey: pageID) }
    }

    // MARK: - 파일 경로
    private var bfCacheDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("BFCache", isDirectory: true)
    }
    private func tabDirectory(for tabID: UUID) -> URL {
        bfCacheDirectory.appendingPathComponent("Tab_\(tabID.uuidString)", isDirectory: true)
    }
    private func pageDirectory(for pageID: UUID, tabID: UUID, version: Int) -> URL {
        tabDirectory(for: tabID).appendingPathComponent("Page_\(pageID.uuidString)_v\(version)", isDirectory: true)
    }

    // MARK: - 전환 컨텍스트
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

    enum NavigationDirection { case back, forward }

    // MARK: - 🔧 단순화된 캡처(이미지 중심)
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, tabID: UUID? = nil) {
        guard let webView = webView else { return }
        serialQueue.async { [weak self] in
            self?.performSimpleCapture(pageRecord: pageRecord, webView: webView, tabID: tabID)
        }
    }

    private func performSimpleCapture(pageRecord: PageRecord, webView: WKWebView, tabID: UUID?) {
        mainSyncOrNow {
            // 스크롤 상태 저장(JS)
            webView.evaluateJavaScript("window.__saveScrollState && window.__saveScrollState()") { _, _ in }

            // 화면 스냅샷
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            config.afterScreenUpdates = false

            webView.takeSnapshot(with: config) { [weak self] image, _ in
                guard let self = self else { return }

                let version = (self._cacheVersion[pageRecord.id] ?? 0) + 1
                self._cacheVersion[pageRecord.id] = version

                let base = BFCacheSnapshot(
                    pageRecord: pageRecord,
                    timestamp: Date(),
                    captureStatus: image != nil ? .visualOnly : .failed,
                    version: version
                )

                // 이미지 저장 필요 없는 경우
                guard let img = image, let tabID = tabID else {
                    self.setMemoryCache(base, for: pageRecord.id)
                    self.dbg("📸 스냅샷 캡처: \(pageRecord.title)")
                    return
                }

                // 디스크 저장 → 경로 콜백으로 반영
                self.saveImageToDisk(image: img, pageID: pageRecord.id, tabID: tabID, version: version) { [weak self] path in
                    guard let self = self else { return }
                    var final = base
                    if let path = path { final.webViewSnapshotPath = path }
                    self.setMemoryCache(final, for: pageRecord.id)
                    self.dbg("📸 스냅샷 캡처: \(pageRecord.title)")
                }
            }
        }
    }

    private func saveImageToDisk(
        image: UIImage,
        pageID: UUID,
        tabID: UUID,
        version: Int,
        completion: @escaping (String?) -> Void
    ) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { completion(nil); return }
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            self.createDirectoryIfNeeded(at: pageDir)
            let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
            guard let jpegData = image.jpegData(compressionQuality: 0.7) else {
                self.dbg("❌ 이미지 JPEG 변환 실패")
                completion(nil)
                return
            }
            do {
                try jpegData.write(to: imagePath)
                self.dbg("💾 이미지 저장: \(imagePath.lastPathComponent)")
                completion(imagePath.path)
            } catch {
                self.dbg("❌ 이미지 저장 실패: \(error.localizedDescription)")
                completion(nil)
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
        cacheAccessQueue.sync { _memoryCache[pageID] }
    }
    func hasCache(for pageID: UUID) -> Bool {
        cacheAccessQueue.sync { _memoryCache[pageID] != nil }
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
            // (옵션) 기존 디스크 인덱스 스캔/복원 로직 추가 가능
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
            if shouldComplete { completeGestureTransition(tabID: tabID) }
            else { cancelGestureTransition(tabID: tabID) }

        case .cancelled, .failed:
            cancelGestureTransition(tabID: tabID)

        default: break
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
        return renderer.image { ctx in webView.layer.render(in: ctx.cgContext) }
    }

    private func beginGestureTransitionWithSnapshot(
        tabID: UUID,
        webView: WKWebView,
        stateModel: WebViewStateModel,
        direction: NavigationDirection,
        currentSnapshot: UIImage?
    ) {
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

    private func createPreviewContainer(
        webView: WKWebView,
        direction: NavigationDirection,
        stateModel: WebViewStateModel,
        currentSnapshot: UIImage? = nil
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

        // 타겟 페이지 미리보기
        let targetIndex = direction == .back
            ? stateModel.dataModel.currentPageIndex - 1
            : stateModel.dataModel.currentPageIndex + 1

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
        targetView.frame.origin.x = (direction == .back) ? -webView.bounds.width : webView.bounds.width

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

        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("⬅️ 뒤로가기 수행")
        case .forward:
            stateModel.goForward()
            dbg("➡️ 앞으로가기 수행")
        }

        // pageshow에서 JS 복원 동작
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

    // MARK: - 🌐 JavaScript 스크립트 (동적 스크롤 복원)
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = #"""
(function () {
  if (window.__sr_installed__) return;
  window.__sr_installed__ = true;

  // 1) 브라우저 기본 스크롤 복원 비활성화
  try { if ('scrollRestoration' in history) { history.scrollRestoration = 'manual'; } } catch (e) {}

  // CSS.escape polyfill
  if (!window.CSS) window.CSS = {};
  if (typeof CSS.escape !== 'function') {
    CSS.escape = function(value) {
      return String(value).replace(/[^a-zA-Z0-9_\-]/g, '\\$&');
    };
  }

  // 유틸
  const H = s => { s=(s||'').slice(0,256); let x=0; for(let i=0;i<s.length;i++) x=(x*31+s.charCodeAt(i))|0; return x; };
  const vvH = () => (window.visualViewport && window.visualViewport.height) || window.innerHeight;
  const safeQuery = sel => { try { return document.querySelector(sel); } catch { return null; } };
  const se = () => (document.scrollingElement || document.documentElement);

  const cssPath = el => {
    if (!el || el===document.body) return null;
    if (el.id) return '#'+CSS.escape(el.id);
    const p=[]; let n=el, guard=0;
    while(n && n.nodeType===1 && guard++<5){
      if (n.id){ p.unshift('#'+CSS.escape(n.id)); break; }
      let idx=1, sib=n;
      while((sib=sib.previousElementSibling)) if (sib.nodeName===n.nodeName) idx++;
      p.unshift(n.nodeName.toLowerCase()+(idx>1?`:nth-of-type(${idx})`:'')); n=n.parentElement;
    }
    return p.join('>');
  };

  const collectContainers = () => {
    const sels=['[data-scroll]','.scroll','.scrollable','.list','.feed','.content','.container','.overflow-auto','.overflow-scroll'];
    const seen=new Set(), out=[];
    for (const sel of sels){
      try {
        document.querySelectorAll(sel).forEach(el=>{
          if (seen.has(el)) return; seen.add(el);
          const st=getComputedStyle(el);
          if (/(auto|scroll)/.test(st.overflow+st.overflowY+st.overflowX)){
            const path=cssPath(el);
            if (path) out.push({ sel, path, top: el.scrollTop||0, left: el.scrollLeft||0 });
          }
        });
      } catch(e){}
    }
    return out;
  };

  const captureAnchor = () => {
    const center = vvH()/2;
    const pool = document.querySelectorAll('article,[role="article"],[data-key],[data-id],h1,h2,h3,li,a[href]:not([href^="#"]),img[src],section[id],[id]');
    let best=null, dist=1e9;
    pool.forEach(el=>{
      const r=el.getBoundingClientRect();
      if ((!r.width && !r.height) || r.top<-2000 || r.top>window.innerHeight+2000) return;
      const mid=r.top + r.height/2;
      const d=Math.abs(mid - center);
      if (d < dist){ dist=d; best=el; }
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

  function saveState() {
    const doc = document.documentElement;
    const vh = vvH();
    const maxTop = Math.max(0, (doc.scrollHeight||0) - vh);
    const y = window.scrollY || window.pageYOffset || doc.scrollTop || 0;
    const x = window.scrollX || window.pageXOffset || doc.scrollLeft || 0;

    const state = {
      ver: 2,
      ts: Date.now(),
      url: window.location.href,
      scroll: {
        x, y,
        ratio: maxTop>0 ? Math.max(0, Math.min(1, y/maxTop)) : 0,
        maxHeight: doc.scrollHeight
      },
      containers: collectContainers(),
      anchor: captureAnchor(),
      vv: { innerH: window.innerHeight, visualH: vvH() }
    };

    try {
      const cur = (history.state && typeof history.state === 'object') ? history.state : {};
      history.replaceState({ ...cur, __scroll__: state }, document.title);
    } catch(e) { /* ignore */ }

    try { sessionStorage.setItem('__scroll_backup__', JSON.stringify(state)); } catch(e) {}
    return state;
  }

  async function restoreState(state) {
    if (!state || !state.scroll) {
      try {
        const backup = sessionStorage.getItem('__scroll_backup__');
        if (backup) state = JSON.parse(backup);
      } catch(e) {}
      if (!state || !state.scroll) return false;
    }

    // DOM 안정 대기
    if (document.readyState !== 'complete') {
      await new Promise(r => {
        window.addEventListener('load', r, { once: true });
        setTimeout(r, 2000);
      });
    }

    // 0) 비율 기반 즉시 복원
    const vh = vvH();
    const maxTop = Math.max(0, (document.documentElement.scrollHeight||0) - vh);
    const yFromRatio = Math.round((state.scroll.ratio||0) * maxTop);
    const targetY = Number.isFinite(yFromRatio) && yFromRatio>0 ? yFromRatio : (state.scroll.y||0);
    const targetX = state.scroll.x || 0;
    window.scrollTo(targetX, Math.max(0, Math.min(maxTop, targetY)));

    // 1) 앵커 복원 (지연)
    setTimeout(() => {
      if (!state.anchor) return;
      let el = null;

      if (state.anchor.sel) el = safeQuery(state.anchor.sel);

      if (!el && state.anchor.key) {
        const keys = [
          `[data-key="${CSS.escape(state.anchor.key)}"]`,
          `[data-id="${CSS.escape(state.anchor.key)}"]`,
          `[data-item-id="${CSS.escape(state.anchor.key)}"]`,
          `a[href="${CSS.escape(state.anchor.key)}"]`,
          `img[src="${CSS.escape(state.anchor.key)}"]`
        ];
        for (const sel of keys) {
          try { el = document.querySelector(sel); if (el) break; } catch(e){}
        }
      }

      if (!el && state.anchor.hash) {
        const pool = document.querySelectorAll('article,[role="article"],[data-key],[data-id],h1,h2,h3,li,a[href]');
        let best=null, diff=1e9;
        pool.forEach(e=>{
          const h = H((e.textContent||'').trim());
          const d = Math.abs(h - state.anchor.hash);
          if (d < diff) { diff = d; best = e; }
        });
        el = best;
      }

      if (el) el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
    }, 100);

    // 2) 컨테이너 복원 (조금 더 지연)
    setTimeout(() => {
      (state.containers||[]).forEach(c=>{
        const el = c.path ? safeQuery(c.path) : (c.sel ? safeQuery(c.sel) : null);
        if (el && typeof el.scrollTop === 'number') {
          el.scrollTop = c.top||0;
          el.scrollLeft = c.left||0;
        }
      });
    }, 200);

    // 3) 적응 루프: 동적 콘텐츠로 인한 문서 높이 변화 보정
    const wait = ms => new Promise(r=>setTimeout(r, ms));
    await wait(150);
    for (let i=0;i<8;i++){
      await wait(100);
      const vh2 = vvH();
      const max2 = Math.max(0, document.documentElement.scrollHeight - vh2);
      const currentY = window.scrollY || window.pageYOffset || 0;
      const target = Math.max(0, Math.min(max2, targetY));
      const err = Math.abs(currentY - target);
      if (err <= 50) return true;
      window.scrollTo({ top: target, left: targetX, behavior: 'instant' });
    }
    return true; // 부분 성공
  }

  // 이벤트
  window.addEventListener('pageshow', async (e)=>{
    await new Promise(r => setTimeout(r, 50));
    const st = (history.state && history.state.__scroll__) || null;
    if (st) { restoreState(st); }
    else {
      try {
        const backup = sessionStorage.getItem('__scroll_backup__');
        if (backup) {
          const state = JSON.parse(backup);
          if (state && state.url === window.location.href) restoreState(state);
        }
      } catch(e){}
    }
    if (e.persisted && window.webkit?.messageHandlers?.bfcacheRestore) {
      window.webkit.messageHandlers.bfcacheRestore.postMessage({ persisted: true });
    }
  });

  window.addEventListener('pagehide', ()=>{ saveState(); });
  window.addEventListener('beforeunload', ()=>{ saveState(); });

  document.addEventListener('click', (e)=>{
    const target = e.target && (e.target.closest?.('a[href],button[type="submit"],input[type="submit"]'));
    if (target) saveState();
  }, true);

  window.addEventListener('popstate', ()=>{
    setTimeout(()=>{
      const st = (history.state && history.state.__scroll__) || null;
      if (st) restoreState(st);
    }, 100);
  });

  // 전역 API
  window.__saveScrollState = saveState;
  window.__restoreScrollState = restoreState;

  console.log('[SR] dynamic scroll-restore installed');
})();
"""#
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: - 스와이프 발생 시(History 점프 방지)
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지 추가: \(url.absoluteString)")
    }

    // MARK: - 디버그 로깅
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[BFCache] \(msg)")
    }

    // MARK: - 메인스레드 재진입 안전 래퍼
    @inline(__always)
    private func mainSyncOrNow<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync { work() }
    }
}

// MARK: - UIGestureRecognizerDelegate
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
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
            if gesture is UIScreenEdgePanGestureRecognizer { webView.removeGestureRecognizer(gesture) }
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
