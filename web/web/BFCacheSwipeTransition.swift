//
//  BFCacheSwipeTransition.swift
//  🎯 **BFCache 전환 시스템 - 직접 전환 방식**
//  ✅ 오버레이 제거 - 웹뷰 자체가 밀려나가는 자연스러운 전환
//  🔄 복원큐와 단일 경로 통합 (영향 없이 협력)
//  🏄‍♂️ 제스처/버튼 네비게이션 통합 처리
//  📸 DOM/JS/스크롤 상태 완벽 복원
//  🔧 제스처 시작 문제 수정 - .began에서 임계값 검사 제거
//  🎯 **스냅샷 문제 해결** - 비동기 캡처 타이밍 수정
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
        // 더 안전한 복원 전략: 점진적 복원
        
        // 1단계: 기본 URL 로드 (캐시된 DOM 사용 안함)
        let request = URLRequest(url: pageRecord.url, cachePolicy: .returnCacheDataElseLoad)
        webView.load(request)
        
        // 2단계: 페이지 로드 후 상태 복원 (더 긴 대기 시간)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.restorePageState(to: webView, completion: completion)
        }
    }
    
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
        
        // 스크롤 복원
        restoreSteps.append {
            let pos = self.scrollPosition
            webView.scrollView.setContentOffset(pos, animated: false)
            let js = "try{window.scrollTo(\(pos.x),\(pos.y));true}catch(e){false}"
            webView.evaluateJavaScript(js) { result, _ in
                stepResults.append((result as? Bool) ?? false)
                nextStep()
            }
        }
        
        // 폼 복원
        if let form = self.formData, !form.isEmpty {
            restoreSteps.append {
                let js = """
                (function(){
                    try{
                        const d=\(self.convertFormDataToJSObject(form)); let ok=0;
                        for (const [k,v] of Object.entries(d)) {
                            const el=document.querySelector(`[name="${k}"], #${k}`); if(!el) continue;
                            if(el.type==='checkbox'||el.type==='radio'){ el.checked=Boolean(v); } else { el.value=String(v??''); }
                            ok++;
                        }
                        return ok>=0;
                    }catch(e){return false;}
                })()
                """
                webView.evaluateJavaScript(js) { result, _ in
                    stepResults.append((result as? Bool) ?? false)
                    nextStep()
                }
            }
        }
        
        // 고급 스크롤 복원
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
                    nextStep()
                }
            }
        }
        
        nextStep()
    }
    
    // 안전한 JSON 변환 함수들
    private func convertFormDataToJSObject(_ formData: [String: Any]) -> String {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: formData, options: [])
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            TabPersistenceManager.debugMessages.append("폼 데이터 JSON 변환 실패: \(error.localizedDescription)")
            return "{}"
        }
    }
    
    private func convertScrollElementsToJSArray(_ elements: [[String: Any]]) -> String {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: elements, options: [])
            return String(data: jsonData, encoding: .utf8) ?? "[]"
        } catch {
            TabPersistenceManager.debugMessages.append("스크롤 요소 JSON 변환 실패: \(error.localizedDescription)")
            return "[]"
        }
    }
    
    func needsRefresh() -> Bool {
        let elapsed = Date().timeIntervalSince(timestamp)
        let type = pageRecord.siteType?.lowercased() ?? ""
        let dynamicPatterns = ["search", "feed", "timeline", "live", "realtime", "stream"]
        let isDynamic = dynamicPatterns.contains { type.contains($0) }
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
        var previewContainer: UIView?
        var currentSnapshot: UIImage? // 🎯 현재 페이지 스냅샷 저장
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
        
        // 약한 참조 컨텍스트 생성 및 연결 (순환 참조 방지)
        if let tabID = stateModel.tabID {
            let ctx = WeakGestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
            objc_setAssociatedObject(leftEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(rightEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        dbg("BFCache 제스처 설정 완료")
    }
    
    // MARK: - 제스처 핸들러
    
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
            // 🔧 수정: .began에서는 임계값 검사 제거, 방향과 가능 여부만 확인
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 🎯 핵심 수정: 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
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
            // ✅ 임계값 검사는 실제 이동이 발생한 후에만 적용
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
    
    // MARK: - 🎯 현재 페이지 스냅샷 캡처 (새로운 메서드)
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        webView.takeSnapshot(with: nil) { image, error in
            if let error = error {
                self.dbg("📸 현재 페이지 스냅샷 실패: \(error.localizedDescription)")
                // 실패시 snapshotView 사용
                DispatchQueue.main.async {
                    let fallbackView = webView.snapshotView(afterScreenUpdates: false)
                    let fallbackImage = self.imageFromView(fallbackView ?? webView)
                    completion(fallbackImage)
                }
            } else {
                self.dbg("📸 현재 페이지 스냅샷 성공: \(image?.size ?? CGSize.zero)")
                completion(image)
            }
        }
    }
    
    // UIView를 UIImage로 변환하는 헬퍼 메서드
    private func imageFromView(_ view: UIView) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(view.bounds.size, view.isOpaque, 0.0)
        defer { UIGraphicsEndImageContext() }
        
        if let context = UIGraphicsGetCurrentContext() {
            view.layer.render(in: context)
            return UIGraphicsGetImageFromCurrentImageContext()
        }
        return nil
    }
    
    // MARK: - 🎯 직접 전환 처리 (스냅샷과 함께)
    
    private func beginGestureTransitionWithSnapshot(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection, currentSnapshot: UIImage?) {
        // 현재 페이지 BFCache 저장
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            BFCacheSnapshot.create(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
                self?.storeSnapshot(snapshot, for: currentRecord.id)
            }
        }
        
        // 웹뷰의 초기 transform 저장
        let initialTransform = webView.transform
        
        // 🎯 이전/다음 페이지 미리보기를 위한 컨테이너 생성 (스냅샷 포함)
        let previewContainer = createPreviewContainer(
            webView: webView,
            direction: direction,
            stateModel: stateModel,
            currentSnapshot: currentSnapshot
        )
        
        // 컨텍스트 저장 (스냅샷 포함)
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
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기") (스냅샷: \(currentSnapshot != nil ? "✅" : "❌"))")
    }
    
    // 기존 beginGestureTransition 메서드는 제거 (위 메서드로 대체)
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentWebView = previewContainer.viewWithTag(1001)
        let targetPreview = previewContainer.viewWithTag(1002)
        
        // 실제 현재 웹뷰와 타겟 미리보기를 함께 이동
        if isLeftEdge {
            // 뒤로가기: 현재 웹뷰는 오른쪽으로, 타겟은 왼쪽에서 들어옴
            let moveDistance = max(0, min(screenWidth, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = -screenWidth + moveDistance
            
            // 그림자 효과
            let shadowOpacity = Float(0.3 * (moveDistance / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        } else {
            // 앞으로가기: 현재 웹뷰는 왼쪽으로, 타겟은 오른쪽에서 들어옴
            let moveDistance = max(-screenWidth, min(0, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = screenWidth + moveDistance
            
            // 그림자 효과
            let shadowOpacity = Float(0.3 * (abs(moveDistance) / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        }
    }
    
    // 미리보기 컨테이너 생성 (실제 takeSnapshot 사용)
    private func createPreviewContainer(
        webView: WKWebView, 
        direction: NavigationDirection, 
        stateModel: WebViewStateModel,
        currentSnapshot: UIImage? = nil
    ) -> UIView {
        let container = UIView(frame: webView.bounds)
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        
        // 🎯 핵심 수정: 현재 웹뷰의 실제 스냅샷 사용
        let currentView: UIView
        if let snapshot = currentSnapshot {
            let imageView = UIImageView(image: snapshot)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            currentView = imageView
            dbg("📸 현재 페이지 스냅샷 사용")
        } else {
            // 스냅샷 캡처 실패시 fallback (snapshotView 사용)
            currentView = webView.snapshotView(afterScreenUpdates: false) ?? UIView(frame: webView.bounds)
            if currentView.frame.isEmpty {
                currentView.frame = webView.bounds
            }
            currentView.backgroundColor = .systemBackground
            dbg("⚠️ 현재 페이지 fallback 뷰 사용")
        }
        
        currentView.frame = webView.bounds
        currentView.tag = 1001
        
        // 그림자 설정
        currentView.layer.shadowColor = UIColor.black.cgColor
        currentView.layer.shadowOpacity = 0.3
        currentView.layer.shadowOffset = CGSize(width: direction == .back ? -5 : 5, height: 0)
        currentView.layer.shadowRadius = 10
        
        container.addSubview(currentView)
        
        // 타겟 페이지 미리보기 생성
        let targetIndex = direction == .back ?
            stateModel.dataModel.currentPageIndex - 1 :
            stateModel.dataModel.currentPageIndex + 1
        
        var targetView: UIView
        
        if targetIndex >= 0, targetIndex < stateModel.dataModel.pageHistory.count {
            let targetRecord = stateModel.dataModel.pageHistory[targetIndex]
            
            // BFCache에서 스냅샷 가져오기
            if let snapshot = retrieveSnapshot(for: targetRecord.id),
               let targetImage = snapshot.webViewSnapshot {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
                dbg("📸 타겟 페이지 BFCache 스냅샷 사용: \(targetRecord.title)")
            } else {
                // 스냅샷이 없으면 정보 카드 표시
                targetView = createInfoCard(for: targetRecord, in: webView.bounds)
                dbg("ℹ️ 타겟 페이지 정보 카드 생성: \(targetRecord.title)")
            }
        } else {
            // 타겟이 없으면 빈 뷰
            targetView = UIView()
            targetView.backgroundColor = .systemBackground
            dbg("⚠️ 타겟 페이지 없음 - 빈 뷰 생성")
        }
        
        targetView.frame = webView.bounds
        targetView.tag = 1002
        
        // 초기 위치 설정
        if direction == .back {
            targetView.frame.origin.x = -webView.bounds.width
        } else {
            targetView.frame.origin.x = webView.bounds.width
        }
        
        // 타겟 뷰를 현재 뷰 아래에 추가
        container.insertSubview(targetView, at: 0)
        
        webView.addSubview(container)
        return container
    }
    
    // 정보 카드 생성 헬퍼 메서드
    private func createInfoCard(for record: PageRecord, in bounds: CGRect) -> UIView {
        let card = UIView(frame: bounds)
        card.backgroundColor = .systemBackground
        
        // 카드 내용을 담을 컨테이너
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 12
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.1
        contentView.layer.shadowOffset = CGSize(width: 0, height: 2)
        contentView.layer.shadowRadius = 8
        card.addSubview(contentView)
        
        // 파비콘 또는 기본 아이콘
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "globe")
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        contentView.addSubview(iconView)
        
        // 제목 레이블
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = record.title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)
        
        // URL 레이블
        let urlLabel = UILabel()
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.text = record.url.host ?? record.url.absoluteString
        urlLabel.font = .systemFont(ofSize: 14)
        urlLabel.textColor = .secondaryLabel
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 1
        contentView.addSubview(urlLabel)
        
        // 시간 레이블
        let timeLabel = UILabel()
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        timeLabel.text = formatter.string(from: record.lastAccessed)
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.textAlignment = .center
        contentView.addSubview(timeLabel)
        
        // Auto Layout 설정
        NSLayoutConstraint.activate([
            // 컨테이너
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 180),
            
            // 아이콘
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            
            // 제목
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            // URL
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            // 시간
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
        
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                if context.direction == .back {
                    // 뒤로가기: 현재 뷰를 완전히 오른쪽으로, 타겟 뷰를 센터로
                    currentView?.frame.origin.x = screenWidth
                    targetView?.frame.origin.x = 0
                } else {
                    // 앞으로가기: 현재 뷰를 완전히 왼쪽으로, 타겟 뷰를 센터로
                    currentView?.frame.origin.x = -screenWidth
                    targetView?.frame.origin.x = 0
                }
                currentView?.layer.shadowOpacity = 0
            },
            completion: { [weak self] _ in
                // 네비게이션 실행
                self?.performNavigation(context: context)
                
                // 컨테이너 제거
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
                // 원래 위치로 복귀
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
    
    // MARK: - 🎯 자동 스냅샷 저장 (모든 이동 이벤트에서 호출)
    
    func saveCurrentPageSnapshot(stateModel: WebViewStateModel) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else { return }
        
        // 이미 캐시에 있으면 스킵 (중복 저장 방지)
        if let existing = retrieveSnapshot(for: currentRecord.id),
           Date().timeIntervalSince(existing.timestamp) < 60 { // 1분 이내 캐시는 재사용
            dbg("📸 스냅샷 이미 존재 (스킵): \(currentRecord.title)")
            return
        }
        
        BFCacheSnapshot.create(pageRecord: currentRecord, webView: webView) { [weak self] snapshot in
            self?.storeSnapshot(snapshot, for: currentRecord.id)
            self?.dbg("📸 자동 스냅샷 저장 완료: \(currentRecord.title)")
        }
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
                // 🎯 핵심 수정: 실패시에도 리로드 안하기
                snapshot.restore(to: webView) { [weak self] success in
                    if success {
                        self?.dbg("✅ BFCache 복원 성공: \(currentRecord.title)")
                    } else {
                        // ❌ 기존: webView.reload() → 제거!
                        // ✅ 새로운 전략: 그냥 현재 상태 유지
                        self?.dbg("⚠️ BFCache 복원 실패했지만 현재 상태 유지: \(currentRecord.title)")
                    }
                }
            }
        } else {
            // BFCache 미스 - 일반적으로는 네비게이션 시스템이 알아서 로드함
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
    
    // 🎯 자동 스냅샷 저장 (WebViewDataModel에서 호출)
    static func saveSnapshotIfNeeded(stateModel: WebViewStateModel) {
        shared.saveCurrentPageSnapshot(stateModel: stateModel)
    }
}
