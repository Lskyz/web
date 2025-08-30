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
    
    // 정적 팩토리 메서드로 변경
    static func create(pageRecord: PageRecord, webView: WKWebView?, completion: @escaping (BFCacheSnapshot) -> Void) {
        let scrollPosition = webView?.scrollView.contentOffset ?? .zero
        let timestamp = Date()
        
        // 시각적 스냅샷 생성
        var visualSnapshot: UIImage? = nil
        if let webView = webView {
            let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
            visualSnapshot = renderer.image { context in
                webView.layer.render(in: context.cgContext)
            }
        }
        
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
            var snapshot = BFCacheSnapshot(
                pageRecord: pageRecord,
                domSnapshot: tempDom,
                scrollPosition: scrollPosition,
                jsState: tempJs,
                formData: tempForm,
                timestamp: timestamp,
                webViewSnapshot: visualSnapshot
            )
            snapshot.domSnapshot = tempDom
            snapshot.jsState = tempJs
            snapshot.formData = tempForm
            completion(snapshot)
        }
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, formData: [String: Any]? = nil, timestamp: Date, webViewSnapshot: UIImage? = nil) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.formData = formData
        self.timestamp = timestamp
        self.webViewSnapshot = webViewSnapshot
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
            // translation.x 값 그대로 전달 (양수/음수 구분 중요)
            updateGestureProgress(tabID: tabID, progress: progress, translation: translation.x, isLeftEdge: isLeftEdge)
            
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
            BFCacheSnapshot.create(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
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
            dbg("🖼️ 타겟 스냅샷 \(targetSnapshot != nil ? "있음" : "없음"): \(targetRecord.title)")
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
        
        dbg("🎬 제스처 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func updateGestureProgress(tabID: UUID, progress: CGFloat, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = activeTransitions[tabID],
              let containerView = context.overlayView,
              let webView = context.webView else { return }
        
        let screenWidth = webView.bounds.width
        let currentPageView = containerView.viewWithTag(101)
        let targetPageView = containerView.viewWithTag(102)
        
        // 디버그 로그
        dbg("📱 제스처 진행: progress=\(progress), translation=\(translation), leftEdge=\(isLeftEdge)")
        
        if isLeftEdge {
            // 왼쪽 에지에서 시작 (뒤로가기): translation.x는 양수
            let moveDistance = max(0, min(screenWidth, translation))
            currentPageView?.frame.origin.x = moveDistance
            targetPageView?.frame.origin.x = -screenWidth + moveDistance
            dbg("⬅️ 뒤로가기 제스처: current=\(moveDistance), target=\(-screenWidth + moveDistance)")
        } else {
            // 오른쪽 에지에서 시작 (앞으로가기): translation.x는 음수
            let moveDistance = max(-screenWidth, min(0, translation))
            currentPageView?.frame.origin.x = moveDistance
            targetPageView?.frame.origin.x = screenWidth + moveDistance
            dbg("➡️ 앞으로가기 제스처: current=\(moveDistance), target=\(screenWidth + moveDistance)")
        }
        
        // 그림자 투명도 조절
        currentPageView?.layer.shadowOpacity = Float(0.3 * (1 - progress))
    }
    
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let containerView = context.overlayView,
              let webView = context.webView else { return }
        
        let screenWidth = webView.bounds.width
        let currentPageView = containerView.viewWithTag(101)
        let targetPageView = containerView.viewWithTag(102)
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                if context.direction == .back {
                    // 뒤로가기 완료: 현재 페이지는 완전히 오른쪽으로
                    currentPageView?.frame.origin.x = screenWidth
                    targetPageView?.frame.origin.x = 0
                } else {
                    // 앞으로가기 완료: 현재 페이지는 완전히 왼쪽으로
                    currentPageView?.frame.origin.x = -screenWidth
                    targetPageView?.frame.origin.x = 0
                }
                currentPageView?.layer.shadowOpacity = 0
            },
            completion: { [weak self] _ in
                self?.performNavigation(context: context)
                containerView.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: tabID)
            }
        )
    }
    
    private func cancelGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let containerView = context.overlayView,
              let webView = context.webView else { return }
        
        let screenWidth = webView.bounds.width
        let currentPageView = containerView.viewWithTag(101)
        let targetPageView = containerView.viewWithTag(102)
        
        UIView.animate(
            withDuration: 0.25,
            animations: {
                // 원래 위치로 복귀
                currentPageView?.frame.origin.x = 0
                
                if context.direction == .back {
                    targetPageView?.frame.origin.x = -screenWidth
                } else {
                    targetPageView?.frame.origin.x = screenWidth
                }
                
                currentPageView?.layer.shadowOpacity = 0.3
            },
            completion: { _ in
                containerView.removeFromSuperview()
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
            BFCacheSnapshot.create(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
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
            BFCacheSnapshot.create(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
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
        // 오버레이 컨테이너 (전체 화면)
        let containerView = UIView(frame: webView.bounds)
        containerView.backgroundColor = .clear
        containerView.clipsToBounds = true
        
        // 현재 페이지 스크린샷
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        let currentSnapshot = renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
        
        // 현재 페이지 뷰 (밀려나갈 페이지)
        let currentPageView = UIImageView(image: currentSnapshot)
        currentPageView.frame = webView.bounds
        currentPageView.contentMode = .scaleAspectFill
        currentPageView.tag = 101
        containerView.addSubview(currentPageView)
        
        // 타겟 페이지 뷰 (들어올 페이지)
        let targetPageView: UIImageView
        if let targetSnapshot = targetSnapshot {
            targetPageView = UIImageView(image: targetSnapshot)
            dbg("✅ 타겟 스냅샷 적용됨")
        } else {
            // 스냅샷이 없으면 흰색 배경에 로딩 텍스트
            targetPageView = UIImageView()
            targetPageView.backgroundColor = .systemBackground
            
            let label = UILabel()
            label.text = "Loading..."
            label.textAlignment = .center
            label.frame = CGRect(x: 0, y: webView.bounds.height/2 - 20, width: webView.bounds.width, height: 40)
            targetPageView.addSubview(label)
            dbg("⚠️ 타겟 스냅샷 없음 - 기본 배경 사용")
        }
        targetPageView.frame = webView.bounds
        targetPageView.contentMode = .scaleAspectFill
        targetPageView.tag = 102
        
        // 초기 위치 설정
        if direction == .back {
            // 뒤로가기: 타겟 페이지는 왼쪽에서 시작
            targetPageView.frame.origin.x = -webView.bounds.width
            dbg("📍 타겟 페이지 초기 위치: 왼쪽 (-\(webView.bounds.width))")
        } else {
            // 앞으로가기: 타겟 페이지는 오른쪽에서 시작
            targetPageView.frame.origin.x = webView.bounds.width
            dbg("📍 타겟 페이지 초기 위치: 오른쪽 (\(webView.bounds.width))")
        }
        
        // 타겟 페이지를 현재 페이지 아래에 추가
        containerView.insertSubview(targetPageView, at: 0)
        
        // 그림자 효과
        currentPageView.layer.shadowColor = UIColor.black.cgColor
        currentPageView.layer.shadowOpacity = 0.3
        currentPageView.layer.shadowOffset = CGSize(width: -5, height: 0)
        currentPageView.layer.shadowRadius = 10
        
        webView.addSubview(containerView)
        dbg("🎨 오버레이 생성 완료: 현재페이지=tag101, 타겟페이지=tag102")
        return containerView
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
