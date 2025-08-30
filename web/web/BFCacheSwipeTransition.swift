//
//  BFCacheSwipeTransition.swift
//  🎯 **BFCache 전환 시스템 - 단일 파일 책임**
//  ✅ 이 파일이 모든 BFCache 관련 로직 담당
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

// MARK: - 📸 BFCache 페이지 스냅샷
struct BFCacheSnapshot {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    var formData: [String: Any]?
    let timestamp: Date
    let webViewSnapshot: UIImage?
    
    init(pageRecord: PageRecord, webView: WKWebView?, completion: @escaping (BFCacheSnapshot) -> Void) {
        self.pageRecord = pageRecord
        self.scrollPosition = webView?.scrollView.contentOffset ?? .zero
        self.timestamp = Date()
        
        // 시각적 스냅샷 생성
        var visualSnapshot: UIImage? = nil
        if let webView = webView {
            let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
            visualSnapshot = renderer.image { context in
                webView.layer.render(in: context.cgContext)
            }
        }
        self.webViewSnapshot = visualSnapshot
        
        // DOM과 JS 상태 캡처
        var tempDom: String? = nil
        var tempJs: [String: Any]? = nil
        var tempForm: [String: Any]? = nil
        
        let group = DispatchGroup()
        
        group.enter()
        webView?.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            tempDom = result as? String
            group.leave()
        }
        
        group.enter()
        let jsScript = """
        (function() {
            try {
                const formData = {};
                document.querySelectorAll('input, textarea, select').forEach(el => {
                    if (el.name || el.id) {
                        const key = el.name || el.id;
                        if (el.type === 'checkbox' || el.type === 'radio') {
                            formData[key] = el.checked;
                        } else {
                            formData[key] = el.value;
                        }
                    }
                });
                
                const scrollData = {
                    x: window.scrollX,
                    y: window.scrollY,
                    elements: []
                };
                
                document.querySelectorAll('*').forEach((el, idx) => {
                    if (el.scrollTop > 0 || el.scrollLeft > 0) {
                        scrollData.elements.push({
                            index: idx,
                            top: el.scrollTop,
                            left: el.scrollLeft
                        });
                    }
                });
                
                return {
                    forms: formData,
                    scroll: scrollData,
                    href: window.location.href,
                    title: document.title
                };
            } catch(e) { 
                return null; 
            }
        })()
        """
        
        webView?.evaluateJavaScript(jsScript) { result, _ in
            if let data = result as? [String: Any] {
                tempForm = data["forms"] as? [String: Any]
                tempJs = data
            }
            group.leave()
        }
        
        group.notify(queue: .main) {
            var snapshot = self
            snapshot.domSnapshot = tempDom
            snapshot.jsState = tempJs
            snapshot.formData = tempForm
            completion(snapshot)
        }
    }
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        webView.load(URLRequest(url: pageRecord.url))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let formData = self.formData {
                var restoreScript = "(() => {\n"
                for (key, value) in formData {
                    let escapedKey = key.replacingOccurrences(of: "'", with: "\\'")
                    if let boolValue = value as? Bool {
                        restoreScript += "  const el_\(key.hashValue) = document.querySelector('[name=\"\(escapedKey)\"], #\(escapedKey)');\n"
                        restoreScript += "  if (el_\(key.hashValue)) { el_\(key.hashValue).checked = \(boolValue); }\n"
                    } else if let stringValue = value as? String {
                        let escapedValue = stringValue.replacingOccurrences(of: "'", with: "\\'")
                        restoreScript += "  const el_\(key.hashValue) = document.querySelector('[name=\"\(escapedKey)\"], #\(escapedKey)');\n"
                        restoreScript += "  if (el_\(key.hashValue)) { el_\(key.hashValue).value = '\(escapedValue)'; }\n"
                    }
                }
                restoreScript += "})();"
                
                webView.evaluateJavaScript(restoreScript) { _, _ in
                    webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                    completion(true)
                }
            } else {
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                completion(true)
            }
        }
    }
    
    func needsRefresh() -> Bool {
        let elapsed = Date().timeIntervalSince(timestamp)
        let dynamicPatterns = ["search", "feed", "timeline", "live", "realtime", "stream"]
        let isDynamic = dynamicPatterns.contains { pageRecord.siteType?.contains($0) ?? false }
        let isSearch = PageRecord.isSearchURL(pageRecord.url)
        return (isDynamic || isSearch) && elapsed > 300
    }
}

// MARK: - 🎯 BFCache 전환 시스템 (모든 기능 통합)
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
    }
    
    // MARK: - 캐시 저장소
    private var cache: [UUID: BFCacheSnapshot] = [:]
    private let maxCacheSize = 20
    private let cacheQueue = DispatchQueue(label: "bfcache", attributes: .concurrent)
    
    // MARK: - 전환 상태
    private var activeTransitions: [UUID: TransitionContext] = [:]
    
    // 전환 컨텍스트
    private struct TransitionContext {
        let tabID: UUID
        weak var webView: WKWebView?
        weak var stateModel: WebViewStateModel?
        var overlayView: UIView?
        var isGesture: Bool
        var direction: NavigationDirection
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    // MARK: - 캐시 관리
    
    private func storeSnapshot(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        cacheQueue.async(flags: .barrier) {
            self.cache[pageID] = snapshot
            
            if self.cache.count > self.maxCacheSize {
                let sorted = self.cache.sorted { $0.value.timestamp < $1.value.timestamp }
                if let oldest = sorted.first {
                    self.cache.removeValue(forKey: oldest.key)
                    self.dbg("🗑️ BFCache 오래된 항목 제거: \(String(oldest.key.uuidString.prefix(8)))")
                }
            }
        }
        dbg("📸 BFCache 저장: \(String(pageID.uuidString.prefix(8))) - \(snapshot.pageRecord.title)")
    }
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        cacheQueue.sync {
            cache[pageID]
        }
    }
    
    // MARK: - 제스처 설정 (CustomWebView에서 호출)
    
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
        
        // 컨텍스트 저장
        if let tabID = stateModel.tabID {
            objc_setAssociatedObject(leftEdge, "context", (tabID, webView, stateModel), .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(rightEdge, "context", (tabID, webView, stateModel), .OBJC_ASSOCIATION_RETAIN)
        }
        
        dbg("🎯 BFCache 제스처 설정 완료")
    }
    
    // MARK: - 제스처 핸들러
    
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let (tabID, webView, stateModel) = objc_getAssociatedObject(gesture, "context") as? (UUID, WKWebView, WebViewStateModel) else { return }
        
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        let progress = abs(translation.x) / (gesture.view?.bounds.width ?? 1)
        
        switch gesture.state {
        case .began:
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                beginGestureTransition(tabID: tabID, webView: webView, stateModel: stateModel, direction: direction)
            } else {
                gesture.state = .cancelled
            }
            
        case .changed:
            updateGestureProgress(tabID: tabID, progress: progress, translation: translation.x)
            
        case .ended:
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
    
    // MARK: - 제스처 전환 처리
    
    private func beginGestureTransition(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection) {
        // 현재 페이지 BFCache 저장
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            _ = BFCacheSnapshot(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
                self?.storeSnapshot(snapshot, for: currentRecord.id)
            }
        }
        
        // 타겟 페이지 스냅샷 가져오기
        let targetIndex = direction == .back ? 
            stateModel.dataModel.currentPageIndex - 1 :
            stateModel.dataModel.currentPageIndex + 1
            
        var targetSnapshot: UIImage? = nil
        if targetIndex >= 0, targetIndex < stateModel.dataModel.pageHistory.count {
            let targetRecord = stateModel.dataModel.pageHistory[targetIndex]
            targetSnapshot = retrieveSnapshot(for: targetRecord.id)?.webViewSnapshot
        }
        
        // 오버레이 생성
        let overlayView = createTransitionOverlay(webView: webView, direction: direction, targetSnapshot: targetSnapshot)
        
        // 컨텍스트 저장
        let context = TransitionContext(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            overlayView: overlayView,
            isGesture: true,
            direction: direction
        )
        activeTransitions[tabID] = context
    }
    
    private func updateGestureProgress(tabID: UUID, progress: CGFloat, translation: CGFloat) {
        guard let context = activeTransitions[tabID],
              let overlayView = context.overlayView,
              let webView = context.webView else { return }
        
        let screenWidth = webView.bounds.width
        let isLeftEdge = context.direction == .back
        
        if isLeftEdge {
            let translateX = max(-screenWidth, -screenWidth + translation)
            overlayView.transform = CGAffineTransform(translationX: translateX, y: 0)
        } else {
            let translateX = min(screenWidth, screenWidth + translation)
            overlayView.transform = CGAffineTransform(translationX: translateX, y: 0)
        }
        
        overlayView.alpha = 0.3 + (progress * 0.7)
    }
    
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let overlayView = context.overlayView else { return }
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                overlayView.transform = .identity
                overlayView.alpha = 1.0
            },
            completion: { [weak self] _ in
                self?.performNavigation(context: context)
                overlayView.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: tabID)
            }
        )
    }
    
    private func cancelGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let overlayView = context.overlayView,
              let webView = context.webView else { return }
        
        let screenWidth = webView.bounds.width
        let cancelX: CGFloat = overlayView.transform.tx > 0 ? screenWidth : -screenWidth
        
        UIView.animate(
            withDuration: 0.25,
            animations: {
                overlayView.transform = CGAffineTransform(translationX: cancelX, y: 0)
                overlayView.alpha = 0.0
            },
            completion: { _ in
                overlayView.removeFromSuperview()
                self.activeTransitions.removeValue(forKey: tabID)
            }
        )
    }
    
    // MARK: - 버튼 네비게이션 (즉시 전환)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let _ = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 BFCache 저장
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            _ = BFCacheSnapshot(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
                self?.storeSnapshot(snapshot, for: currentRecord.id)
            }
        }
        
        // 즉시 네비게이션 (복원큐 사용)
        stateModel.goBack()
        tryBFCacheRestore(stateModel: stateModel, direction: .back)
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let _ = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 BFCache 저장
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            _ = BFCacheSnapshot(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
                self?.storeSnapshot(snapshot, for: currentRecord.id)
            }
        }
        
        // 즉시 네비게이션 (복원큐 사용)
        stateModel.goForward()
        tryBFCacheRestore(stateModel: stateModel, direction: .forward)
    }
    
    // MARK: - 네비게이션 실행 (복원큐와 통합)
    
    private func performNavigation(context: TransitionContext) {
        guard let stateModel = context.stateModel else { return }
        
        // 복원큐 시스템 사용 (safariStyle 메서드 대체)
        switch context.direction {
        case .back:
            // 기존 safariStyleGoBack 로직 흡수
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            // 기존 safariStyleGoForward 로직 흡수
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // BFCache 복원 시도
        tryBFCacheRestore(stateModel: stateModel, direction: context.direction)
    }
    
    private func tryBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else { return }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            if snapshot.needsRefresh() {
                // 동적 페이지는 리로드
                webView.reload()
                dbg("🔄 동적 페이지 리로드: \(currentRecord.title)")
            } else {
                // 정적 페이지는 BFCache 복원
                snapshot.restore(to: webView) { [weak self] success in
                    if success {
                        self?.dbg("✅ BFCache 복원 성공: \(currentRecord.title)")
                    } else {
                        webView.reload()
                        self?.dbg("⚠️ BFCache 복원 실패, 리로드: \(currentRecord.title)")
                    }
                }
            }
        } else {
            // BFCache 미스 - 일반 로드
            dbg("❌ BFCache 미스: \(currentRecord.title)")
        }
    }
    
    // MARK: - 오버레이 생성
    
    private func createTransitionOverlay(webView: WKWebView, direction: NavigationDirection, targetSnapshot: UIImage?) -> UIView {
        // 현재 페이지 스크린샷
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        let currentSnapshot = renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
        
        // 오버레이 컨테이너
        let overlayView = UIView(frame: webView.bounds)
        overlayView.backgroundColor = .systemBackground
        
        // 현재 페이지 이미지
        let currentImageView = UIImageView(image: currentSnapshot)
        currentImageView.frame = webView.bounds
        overlayView.addSubview(currentImageView)
        
        // 타겟 페이지 이미지 (있다면)
        if let targetSnapshot = targetSnapshot {
            let targetImageView = UIImageView(image: targetSnapshot)
            targetImageView.frame = webView.bounds
            overlayView.insertSubview(targetImageView, at: 0)
        }
        
        // 그림자
        let shadowView = UIView()
        shadowView.backgroundColor = .black
        shadowView.alpha = 0.2
        shadowView.frame = CGRect(x: direction == .back ? -10 : webView.bounds.width + 10, y: 0, width: 10, height: webView.bounds.height)
        overlayView.addSubview(shadowView)
        
        // 초기 위치
        let initialX: CGFloat = direction == .back ? -webView.bounds.width : webView.bounds.width
        overlayView.transform = CGAffineTransform(translationX: initialX, y: 0)
        
        webView.addSubview(overlayView)
        return overlayView
    }
    
    // MARK: - 스와이프 제스처 감지 처리 (DataModel에서 이관)
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        // 기존 DataModel.handleSwipeGestureDetected 로직 흡수
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
    
    // MARK: - pageshow/pagehide 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔄 BFCache 페이지 복원');
                
                // 동적 콘텐츠 새로고침
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
        TabPersistenceManager.debugMessages.append("[\(ts())][BFCache] \(msg)")
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
        
        TabPersistenceManager.debugMessages.append("✅ BFCache 시스템 설치 완료")
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
