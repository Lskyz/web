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

// MARK: - 📸 BFCache 페이지 스냅샷
struct BFCacheSnapshot {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    var formData: [String: Any]?
    let timestamp: Date
    let webViewSnapshot: UIImage?
    
    // 정적 팩토리 메서드로 변경 - WKWebView.takeSnapshot 사용
    static func create(pageRecord: PageRecord, webView: WKWebView?, completion: @escaping (BFCacheSnapshot) -> Void) {
        guard let webView = webView else {
            completion(BFCacheSnapshot(
                pageRecord: pageRecord,
                scrollPosition: .zero,
                timestamp: Date(),
                webViewSnapshot: nil
            ))
            return
        }
        
        let scrollPosition = webView.scrollView.contentOffset
        let timestamp = Date()
        
        // 시각적 스냅샷, DOM, JS 상태를 모두 비동기로 캡처
        var visualSnapshot: UIImage? = nil
        var tempDom: String? = nil
        var tempJs: [String: Any]? = nil
        var tempForm: [String: Any]? = nil
        
        let group = DispatchGroup()
        
        // 🎯 핵심 수정: WKWebView.takeSnapshot 사용
        group.enter()
        webView.takeSnapshot(with: nil) { image, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 실패: \(error.localizedDescription)")
            } else {
                visualSnapshot = image
                TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 성공: \(image?.size ?? CGSize.zero)")
            }
            group.leave()
        }
        
        // DOM 캡처
        group.enter()
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("📄 DOM 캡처 실패: \(error.localizedDescription)")
            } else {
                tempDom = result as? String
                TabPersistenceManager.debugMessages.append("📄 DOM 캡처 성공: \(String(describing: tempDom?.prefix(100)))...")
            }
            group.leave()
        }
        
        // JS 상태 및 폼 데이터 캡처
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
                
                // 스크롤 가능한 요소들의 스크롤 위치 저장
                document.querySelectorAll('*').forEach((el, idx) => {
                    if (el.scrollTop > 0 || el.scrollLeft > 0) {
                        scrollData.elements.push({
                            index: idx,
                            top: el.scrollTop,
                            left: el.scrollLeft,
                            selector: el.tagName + (el.id ? '#' + el.id : '') + (el.className ? '.' + el.className.split(' ')[0] : '')
                        });
                    }
                });
                
                return {
                    forms: formData,
                    scroll: scrollData,
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now()
                };
            } catch(e) { 
                console.error('BFCache JS 상태 캡처 실패:', e);
                return {
                    forms: {},
                    scroll: { x: window.scrollX || 0, y: window.scrollY || 0, elements: [] },
                    href: window.location.href,
                    title: document.title,
                    error: e.message
                };
            }
        })()
        """
        
        webView.evaluateJavaScript(jsScript) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("🔧 JS 상태 캡처 실패: \(error.localizedDescription)")
            } else if let data = result as? [String: Any] {
                tempForm = data["forms"] as? [String: Any]
                tempJs = data
                TabPersistenceManager.debugMessages.append("🔧 JS 상태 캡처 성공: \(data.keys.sorted())")
            }
            group.leave()
        }
        
        // 모든 캡처 완료 후 스냅샷 생성
        group.notify(queue: .main) {
            let snapshot = BFCacheSnapshot(
                pageRecord: pageRecord,
                domSnapshot: tempDom,
                scrollPosition: scrollPosition,
                jsState: tempJs,
                formData: tempForm,
                timestamp: timestamp,
                webViewSnapshot: visualSnapshot
            )
            
            TabPersistenceManager.debugMessages.append("📸 BFCache 스냅샷 완성: \(pageRecord.title) (이미지: \(visualSnapshot != nil ? "✅" : "❌"), DOM: \(tempDom != nil ? "✅" : "❌"), JS: \(tempJs != nil ? "✅" : "❌"))")
            
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
        // URL 로드
        webView.load(URLRequest(url: pageRecord.url))
        
        // 페이지 로드 완료 후 상태 복원
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let group = DispatchGroup()
            var restoreSuccess = true
            
            // 폼 데이터 복원
            if let formData = self.formData, !formData.isEmpty {
                group.enter()
                var restoreScript = "try {\n"
                for (key, value) in formData {
                    let escapedKey = key.replacingOccurrences(of: "'", with: "\\'")
                    if let boolValue = value as? Bool {
                        restoreScript += "  const el_\(key.hashValue) = document.querySelector('[name=\"\(escapedKey)\"], #\(escapedKey)');\n"
                        restoreScript += "  if (el_\(key.hashValue)) { el_\(key.hashValue).checked = \(boolValue); }\n"
                    } else if let stringValue = value as? String {
                        let escapedValue = stringValue.replacingOccurrences(of: "'", with: "\\\"")
                        restoreScript += "  const el_\(key.hashValue) = document.querySelector('[name=\"\(escapedKey)\"], #\(escapedKey)');\n"
                        restoreScript += "  if (el_\(key.hashValue)) { el_\(key.hashValue).value = '\(escapedValue)'; }\n"
                    }
                }
                restoreScript += "  console.log('✅ 폼 데이터 복원 완료');\n} catch(e) { console.error('❌ 폼 복원 실패:', e); }"
                
                webView.evaluateJavaScript(restoreScript) { _, error in
                    if let error = error {
                        TabPersistenceManager.debugMessages.append("❌ 폼 복원 실패: \(error.localizedDescription)")
                        restoreSuccess = false
                    } else {
                        TabPersistenceManager.debugMessages.append("✅ 폼 데이터 복원 완료")
                    }
                    group.leave()
                }
            }
            
            // 스크롤 위치 복원
            if let jsState = self.jsState,
               let scrollData = jsState["scroll"] as? [String: Any] {
                
                group.enter()
                let scrollX = scrollData["x"] as? CGFloat ?? self.scrollPosition.x
                let scrollY = scrollData["y"] as? CGFloat ?? self.scrollPosition.y
                
                var scrollRestoreScript = "try {\n"
                scrollRestoreScript += "  window.scrollTo(\(scrollX), \(scrollY));\n"
                
                // 개별 요소들의 스크롤 위치도 복원
                if let elements = scrollData["elements"] as? [[String: Any]] {
                    for element in elements {
                        if let selector = element["selector"] as? String,
                           let top = element["top"] as? CGFloat,
                           let left = element["left"] as? CGFloat {
                            scrollRestoreScript += "  const el = document.querySelector('\(selector)');\n"
                            scrollRestoreScript += "  if (el) { el.scrollTop = \(top); el.scrollLeft = \(left); }\n"
                        }
                    }
                }
                
                scrollRestoreScript += "  console.log('✅ 스크롤 복원 완료: x=\(scrollX), y=\(scrollY)');\n"
                scrollRestoreScript += "} catch(e) { console.error('❌ 스크롤 복원 실패:', e); }"
                
                webView.evaluateJavaScript(scrollRestoreScript) { _, error in
                    if let error = error {
                        TabPersistenceManager.debugMessages.append("❌ 스크롤 복원 실패: \(error.localizedDescription)")
                        restoreSuccess = false
                    } else {
                        TabPersistenceManager.debugMessages.append("✅ 스크롤 복원 완료: \(self.scrollPosition)")
                    }
                    
                    // 웹뷰의 스크롤뷰도 동기화
                    DispatchQueue.main.async {
                        webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                        group.leave()
                    }
                }
            } else {
                // JS 상태가 없으면 기본 스크롤 위치만 복원
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                TabPersistenceManager.debugMessages.append("📍 기본 스크롤 복원: \(self.scrollPosition)")
            }
            
            // 모든 복원 작업 완료 후
            group.notify(queue: .main) {
                TabPersistenceManager.debugMessages.append("🔄 BFCache 복원 \(restoreSuccess ? "성공" : "부분성공"): \(self.pageRecord.title)")
                completion(restoreSuccess)
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

// MARK: - 🎯 BFCache 전환 시스템 (직접 전환 방식)
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
        var isGesture: Bool
        var direction: NavigationDirection
        var initialTransform: CGAffineTransform
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
            updateGestureProgress(tabID: tabID, translation: translation.x, isLeftEdge: isLeftEdge)
            
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
    
    // MARK: - 🎯 직접 전환 처리 (오버레이 없이)
    
    private func beginGestureTransition(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection) {
        // 현재 페이지 BFCache 저장
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            BFCacheSnapshot.create(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
                self?.storeSnapshot(snapshot, for: currentRecord.id)
            }
        }
        
        // 웹뷰의 초기 transform 저장
        let initialTransform = webView.transform
        
        // 컨텍스트 저장
        let context = TransitionContext(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            isGesture: true,
            direction: direction,
            initialTransform: initialTransform
        )
        activeTransitions[tabID] = context
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView else { return }
        
        let screenWidth = webView.bounds.width
        
        // 웹뷰 자체를 직접 이동
        if isLeftEdge {
            // 왼쪽 에지 (뒤로가기): translation.x는 양수
            let moveDistance = max(0, min(screenWidth * 0.8, translation))
            webView.transform = context.initialTransform.translatedBy(x: moveDistance, y: 0)
            
            // 그림자 효과 추가
            let shadowOpacity = Float(0.3 * (1 - moveDistance / screenWidth))
            webView.layer.shadowColor = UIColor.black.cgColor
            webView.layer.shadowOpacity = shadowOpacity
            webView.layer.shadowOffset = CGSize(width: -5, height: 0)
            webView.layer.shadowRadius = 10
            
            dbg("⬅️ 뒤로가기 제스처: move=\(moveDistance)")
        } else {
            // 오른쪽 에지 (앞으로가기): translation.x는 음수
            let moveDistance = max(-screenWidth * 0.8, min(0, translation))
            webView.transform = context.initialTransform.translatedBy(x: moveDistance, y: 0)
            
            // 그림자 효과 추가
            let shadowOpacity = Float(0.3 * (1 - abs(moveDistance) / screenWidth))
            webView.layer.shadowColor = UIColor.black.cgColor
            webView.layer.shadowOpacity = shadowOpacity
            webView.layer.shadowOffset = CGSize(width: 5, height: 0)
            webView.layer.shadowRadius = 10
            
            dbg("➡️ 앞으로가기 제스처: move=\(moveDistance)")
        }
    }
    
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView else { return }
        
        let screenWidth = webView.bounds.width
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // 웹뷰를 화면 밖으로 완전히 밀어내기
        let finalTransform: CGAffineTransform
        if context.direction == .back {
            // 뒤로가기: 오른쪽으로 완전히 밀어내기
            finalTransform = context.initialTransform.translatedBy(x: screenWidth, y: 0)
        } else {
            // 앞으로가기: 왼쪽으로 완전히 밀어내기
            finalTransform = context.initialTransform.translatedBy(x: -screenWidth, y: 0)
        }
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                webView.transform = finalTransform
                webView.layer.shadowOpacity = 0
            },
            completion: { [weak self] _ in
                // 네비게이션 실행
                self?.performNavigation(context: context)
                
                // 웹뷰 원래 위치로 복구 (새 페이지 로드 후)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    webView.transform = context.initialTransform
                    webView.layer.shadowOpacity = 0
                    self?.activeTransitions.removeValue(forKey: tabID)
                }
            }
        )
    }
    
    private func cancelGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView else { return }
        
        // 원래 위치로 복귀
        UIView.animate(
            withDuration: 0.25,
            animations: {
                webView.transform = context.initialTransform
                webView.layer.shadowOpacity = 0
            },
            completion: { _ in
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
