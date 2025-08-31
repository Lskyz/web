//
//  BFCacheSwipeTransition.swift
//  🎯 **BFCache 전환 시스템 - 스냅샷 미스 문제 해결**
//  ✅ 리다이렉트 전용 캡처 로직 추가
//  🔧 디바운스 시간 조건부 적용 (리다이렉트는 즉시)
//  🛡️ pendingCaptures 자동 정리 메커니즘
//  🔄 캡처 실패 시 재시도 로직
//  📸 캡처 상태 추적 개선
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
    let captureStatus: CaptureStatus
    
    enum CaptureStatus {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed        // 캡처 실패
    }
    
    // ✅ 개선된 정적 팩토리 메서드 - 더 안정적인 캡처
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
        
        // ✅ 웹뷰가 화면에 보이는지 확인
        guard webView.window != nil, !webView.bounds.isEmpty else {
            TabPersistenceManager.debugMessages.append("⚠️ 웹뷰가 화면에 없거나 크기가 0 - 스냅샷 스킵")
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
        
        // 시각적 스냅샷, DOM, JS 상태를 모두 비동기로 캡처
        var visualSnapshot: UIImage? = nil
        var tempDom: String? = nil
        var tempJs: [String: Any]? = nil
        var tempForm: [String: Any]? = nil
        var captureResults: [Bool] = []
        
        let group = DispatchGroup()
        
        // 🎯 핵심 수정: WKWebView.takeSnapshot 사용 + 타임아웃
        group.enter()
        var snapshotCompleted = false
        
        // ✅ 타임아웃 설정 (2초)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !snapshotCompleted {
                TabPersistenceManager.debugMessages.append("⏱️ 스냅샷 타임아웃 - fallback 사용")
                // Fallback to layer rendering
                visualSnapshot = captureWebViewAsImage(webView)
                captureResults.append(visualSnapshot != nil)
                group.leave()
            }
        }
        
        webView.takeSnapshot(with: nil) { image, error in
            snapshotCompleted = true
            if let error = error {
                TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 실패: \(error.localizedDescription)")
                // ✅ Fallback 시도
                visualSnapshot = captureWebViewAsImage(webView)
                captureResults.append(visualSnapshot != nil)
            } else {
                visualSnapshot = image
                captureResults.append(true)
                TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 성공: \(image?.size ?? CGSize.zero)")
            }
            group.leave()
        }
        
        // ✅ DOM 캡처 개선 - 안전한 캡처
        group.enter()
        let domScript = """
        (function() {
            try {
                // 페이지가 충분히 로드되었는지 확인
                if (document.readyState !== 'complete') {
                    return null;
                }
                // DOM이 너무 크면 일부만 캡처
                const html = document.documentElement.outerHTML;
                if (html.length > 500000) { // 500KB 제한
                    return html.substring(0, 500000) + '<!-- truncated -->';
                }
                return html;
            } catch(e) {
                return null;
            }
        })()
        """
        
        webView.evaluateJavaScript(domScript) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("📄 DOM 캡처 실패: \(error.localizedDescription)")
                captureResults.append(false)
            } else {
                tempDom = result as? String
                captureResults.append(tempDom != nil)
                if let dom = tempDom {
                    TabPersistenceManager.debugMessages.append("📄 DOM 캡처 성공: \(dom.prefix(100))...")
                }
            }
            group.leave()
        }
        
        // ✅ JS 상태 및 폼 데이터 캡처 개선
        group.enter()
        let jsScript = """
        (function() {
            try {
                // 페이지 준비 상태 확인
                if (typeof document === 'undefined') return null;
                
                const formData = {};
                // ✅ 더 안전한 폼 데이터 수집
                const inputs = document.querySelectorAll('input:not([type="password"]), textarea, select');
                for (let i = 0; i < Math.min(inputs.length, 100); i++) { // 최대 100개 제한
                    const el = inputs[i];
                    if (el.name || el.id) {
                        const key = el.name || el.id;
                        if (el.type === 'checkbox' || el.type === 'radio') {
                            formData[key] = el.checked;
                        } else if (el.value && el.value.length < 1000) { // 긴 값 제외
                            formData[key] = el.value;
                        }
                    }
                }
                
                const scrollData = {
                    x: window.scrollX || 0,
                    y: window.scrollY || 0,
                    elements: []
                };
                
                // ✅ 스크롤 요소 제한 (최대 20개)
                const scrollableElements = document.querySelectorAll('*');
                let scrollCount = 0;
                for (let i = 0; i < scrollableElements.length && scrollCount < 20; i++) {
                    const el = scrollableElements[i];
                    if (el.scrollTop > 0 || el.scrollLeft > 0) {
                        scrollData.elements.push({
                            index: i,
                            top: el.scrollTop,
                            left: el.scrollLeft,
                            selector: el.tagName + (el.id ? '#' + el.id : '')
                        });
                        scrollCount++;
                    }
                }
                
                return {
                    forms: formData,
                    scroll: scrollData,
                    href: window.location.href,
                    title: document.title || '',
                    timestamp: Date.now(),
                    ready: document.readyState
                };
            } catch(e) { 
                console.error('BFCache JS 상태 캡처 실패:', e);
                return {
                    forms: {},
                    scroll: { x: 0, y: 0, elements: [] },
                    error: e.message
                };
            }
        })()
        """
        
        webView.evaluateJavaScript(jsScript) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("🔧 JS 상태 캡처 실패: \(error.localizedDescription)")
                captureResults.append(false)
            } else if let data = result as? [String: Any] {
                tempForm = data["forms"] as? [String: Any]
                tempJs = data
                captureResults.append(true)
                TabPersistenceManager.debugMessages.append("🔧 JS 상태 캡처 성공: \(data.keys.sorted())")
            } else {
                captureResults.append(false)
            }
            group.leave()
        }
        
        // ✅ 모든 캡처 완료 후 스냅샷 생성
        group.notify(queue: .main) {
            // 캡처 상태 결정
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
                "📸 BFCache 스냅샷 완성: \(pageRecord.title) " +
                "[상태: \(captureStatus)] " +
                "(이미지: \(visualSnapshot != nil ? "✅" : "❌"), " +
                "DOM: \(tempDom != nil ? "✅" : "❌"), " +
                "JS: \(tempJs != nil ? "✅" : "❌"))"
            )
            
            completion(snapshot)
        }
    }
    
    // ✅ Layer 렌더링을 사용한 fallback 캡처
    private static func captureWebViewAsImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // 직접 초기화용 init
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
    
    // ✅ 개선된 복원 메서드
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 캡처 상태에 따른 복원 전략
        switch captureStatus {
        case .failed:
            // 캡처 실패 시 단순 URL 로드만
            webView.load(URLRequest(url: pageRecord.url))
            completion(false)
            return
            
        case .visualOnly:
            // 이미지만 있으면 URL 로드 후 스크롤 위치만 복원
            webView.load(URLRequest(url: pageRecord.url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                completion(true)
            }
            return
            
        case .partial, .complete:
            // 정상적인 복원 진행
            break
        }
        
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

// MARK: - 🎯 BFCache 전환 시스템 (개선된 버전)
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 🔧 pendingCaptures 자동 정리 타이머 시작
        startCleanupTimer()
    }
    
    // MARK: - 캐시 저장소
    private var cache: [UUID: BFCacheSnapshot] = [:]
    private let maxCacheSize = 30
    private let cacheQueue = DispatchQueue(label: "bfcache", attributes: .concurrent)
    
    // 🔧 개선된 추적 시스템
    private var lastArrivalStoreAt: [UUID: Date] = [:]
    private var lastLeavingStoreAt: [UUID: Date] = [:]
    private var pendingCaptures: [UUID: Date] = [:] // Set → Dictionary로 변경 (시간 추적)
    private var failedCaptures: Set<UUID> = [] // 실패한 캡처 추적
    private var cleanupTimer: Timer?
    
    // 🎯 캡처 컨텍스트 (리다이렉트 감지용)
    private struct CaptureContext {
        let pageID: UUID
        let isRedirect: Bool
        let urgency: CaptureUrgency
        let timestamp: Date
        
        enum CaptureUrgency {
            case immediate   // 즉시 캡처 (리다이렉트)
            case normal      // 일반 디바운스 적용
            case delayed     // 지연 캡처
        }
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
    
    // MARK: - 🔧 자동 정리 시스템
    
    private func startCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.cleanupStalePendingCaptures()
        }
    }
    
    private func cleanupStalePendingCaptures() {
        cacheQueue.async(flags: .barrier) {
            let now = Date()
            let staleThreshold: TimeInterval = 10.0 // 10초 이상 지난 캡처는 정리
            
            var toRemove: [UUID] = []
            for (id, timestamp) in self.pendingCaptures {
                if now.timeIntervalSince(timestamp) > staleThreshold {
                    toRemove.append(id)
                    self.dbg("🧹 오래된 pending 캡처 정리: \(String(id.uuidString.prefix(8)))")
                }
            }
            
            toRemove.forEach { self.pendingCaptures.removeValue(forKey: $0) }
            
            // 실패한 캡처도 주기적으로 정리
            if self.failedCaptures.count > 50 {
                self.failedCaptures.removeAll()
                self.dbg("🧹 실패 캡처 목록 리셋")
            }
        }
    }
    
    // MARK: - 캐시 관리 (개선)
    
    private func storeSnapshot(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        cacheQueue.async(flags: .barrier) {
            self.cache[pageID] = snapshot
            self.pendingCaptures.removeValue(forKey: pageID) // Dictionary에서 제거
            self.failedCaptures.remove(pageID) // 성공했으므로 실패 목록에서 제거
            
            // LRU 방식으로 캐시 관리
            if self.cache.count > self.maxCacheSize {
                let sorted = self.cache.sorted { $0.value.timestamp < $1.value.timestamp }
                if let oldest = sorted.first {
                    self.cache.removeValue(forKey: oldest.key)
                    self.dbg("🗑️ BFCache 오래된 항목 제거: \(String(oldest.key.uuidString.prefix(8)))")
                }
            }
        }
        dbg("📸 BFCache 저장: \(String(pageID.uuidString.prefix(8))) - \(snapshot.pageRecord.title) [상태: \(snapshot.captureStatus)]")
    }
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        cacheQueue.sync {
            cache[pageID]
        }
    }
    
    // 🔧 개선된 캡처 진행 확인
    private func isCaptureInProgress(for pageID: UUID) -> Bool {
        cacheQueue.sync {
            pendingCaptures[pageID] != nil
        }
    }
    
    // 🔧 캡처 실패 여부 확인
    private func hasCaptureFailedRecently(for pageID: UUID) -> Bool {
        cacheQueue.sync {
            failedCaptures.contains(pageID)
        }
    }
    
    // 🔧 캡처 시작 마킹
    private func markCaptureStarted(for pageID: UUID) {
        cacheQueue.async(flags: .barrier) {
            self.pendingCaptures[pageID] = Date()
        }
    }
    
    // 🔧 캡처 실패 마킹
    private func markCaptureFailed(for pageID: UUID) {
        cacheQueue.async(flags: .barrier) {
            self.pendingCaptures.removeValue(forKey: pageID)
            self.failedCaptures.insert(pageID)
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
    
    // MARK: - 제스처 핸들러 (변경 없음)
    
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
    
    // MARK: - 현재 페이지 스냅샷 캡처
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let captureConfig = WKSnapshotConfiguration()
        captureConfig.rect = webView.bounds
        captureConfig.afterScreenUpdates = false
        
        webView.takeSnapshot(with: captureConfig) { image, error in
            if let error = error {
                self.dbg("📸 현재 페이지 스냅샷 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let fallbackImage = self.imageFromView(webView)
                    completion(fallbackImage)
                }
            } else {
                self.dbg("📸 현재 페이지 스냅샷 성공: \(image?.size ?? CGSize.zero)")
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
    
    // MARK: - 직접 전환 처리 (변경 없음)
    
    private func beginGestureTransitionWithSnapshot(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection, currentSnapshot: UIImage?) {
        // 🔧 개선: 컨텍스트 기반 캡처
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            let context = CaptureContext(
                pageID: currentRecord.id,
                isRedirect: false,
                urgency: .normal,
                timestamp: Date()
            )
            captureWithContext(context: context, webView: webView, record: currentRecord)
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
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기") (스냅샷: \(currentSnapshot != nil ? "✅" : "❌"))")
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
    
    // MARK: - 미리보기 컨테이너 생성 (변경 없음)
    
    private func createPreviewContainer(
        webView: WKWebView, 
        direction: NavigationDirection, 
        stateModel: WebViewStateModel,
        currentSnapshot: UIImage? = nil
    ) -> UIView {
        let container = UIView(frame: webView.bounds)
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        
        let currentView: UIView
        if let snapshot = currentSnapshot {
            let imageView = UIImageView(image: snapshot)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            currentView = imageView
            dbg("📸 현재 페이지 스냅샷 사용")
        } else {
            if let fallbackImage = imageFromView(webView) {
                let imageView = UIImageView(image: fallbackImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                currentView = imageView
            } else {
                currentView = UIView(frame: webView.bounds)
                currentView.backgroundColor = .systemBackground
            }
            dbg("⚠️ 현재 페이지 fallback 뷰 사용")
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
                dbg("📸 타겟 페이지 BFCache 스냅샷 사용: \(targetRecord.title) [상태: \(snapshot.captureStatus)]")
            } else {
                targetView = createInfoCard(for: targetRecord, in: webView.bounds)
                dbg("ℹ️ 타겟 페이지 정보 카드 생성: \(targetRecord.title)")
            }
        } else {
            targetView = UIView()
            targetView.backgroundColor = .systemBackground
            dbg("⚠️ 타겟 페이지 없음 - 빈 뷰 생성")
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
    
    // MARK: - 정보 카드 생성 (변경 없음)
    
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
    
    // MARK: - 전환 완료/취소 (변경 없음)
    
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
    
    // MARK: - 버튼 네비게이션 (개선)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let _ = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🔧 개선: 컨텍스트 기반 캡처
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            let context = CaptureContext(
                pageID: currentRecord.id,
                isRedirect: false,
                urgency: .normal,
                timestamp: Date()
            )
            captureWithContext(context: context, webView: webView, record: currentRecord)
        }
        
        stateModel.goBack()
        tryBFCacheRestore(stateModel: stateModel, direction: .back)
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let _ = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🔧 개선: 컨텍스트 기반 캡처
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            let context = CaptureContext(
                pageID: currentRecord.id,
                isRedirect: false,
                urgency: .normal,
                timestamp: Date()
            )
            captureWithContext(context: context, webView: webView, record: currentRecord)
        }
        
        stateModel.goForward()
        tryBFCacheRestore(stateModel: stateModel, direction: .forward)
    }
    
    // MARK: - 네비게이션 실행 (변경 없음)
    
    private func performNavigation(context: TransitionContext) {
        guard let stateModel = context.stateModel else { return }
        
        switch context.direction {
        case .back:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        tryBFCacheRestore(stateModel: stateModel, direction: context.direction)
    }
    
    private func tryBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else { return }
        
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            if snapshot.needsRefresh() {
                webView.reload()
                dbg("🔄 동적 페이지 리로드: \(currentRecord.title)")
            } else {
                snapshot.restore(to: webView) { [weak self] success in
                    if success {
                        self?.dbg("✅ BFCache 복원 성공: \(currentRecord.title) [상태: \(snapshot.captureStatus)]")
                    } else {
                        self?.dbg("⚠️ BFCache 복원 실패했지만 현재 상태 유지: \(currentRecord.title)")
                    }
                }
            }
        } else {
            dbg("❌ BFCache 미스: \(currentRecord.title)")
        }
    }
    
    // MARK: - pageshow/pagehide 스크립트 (변경 없음)
    
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
    
    // MARK: - 디버그
    
private func dbg(_ msg: String) {
    TabPersistenceManager.debugMessages.append("[BFCache] \(msg)")
}

deinit {
    cleanupTimer?.invalidate()
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
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가 (과거 점프 방지): \(url.absoluteString)")
    }
}

// MARK: - 🎯 개선된 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출
extension BFCacheTransitionSystem {
    
    // 🔧 개선된 컨텍스트 기반 캡처
    private func captureWithContext(context: CaptureContext, webView: WKWebView, record: PageRecord) {
        let now = Date()
        
        // 긴급도에 따른 디바운스 적용
        let debounceTime: TimeInterval
        switch context.urgency {
        case .immediate:
            debounceTime = 0 // 즉시 캡처
        case .normal:
            debounceTime = 0.3 // 짧은 디바운스
        case .delayed:
            debounceTime = 1.0 // 긴 디바운스
        }
        
        // 디바운스 체크 (immediate는 무시)
        if context.urgency != .immediate {
            if let lastTime = lastLeavingStoreAt[context.pageID],
               now.timeIntervalSince(lastTime) < debounceTime {
                dbg("⏳ 디바운스로 캡처 스킵: \(record.title) (남은 시간: \(String(format: "%.2f", debounceTime - now.timeIntervalSince(lastTime)))초)")
                return
            }
        }
        
        // 이미 캡처 중이면 스킵
        if isCaptureInProgress(for: context.pageID) {
            dbg("⏳ 이미 캡처 진행 중 - 스킵: \(record.title)")
            return
        }
        
        // 최근 실패한 캡처면 재시도 제한
        if hasCaptureFailedRecently(for: context.pageID) && context.urgency != .immediate {
            dbg("❌ 최근 캡처 실패 - 재시도 제한: \(record.title)")
            return
        }
        
        // 이미 캐시에 있고 성공 상태면 스킵
        if let existing = retrieveSnapshot(for: context.pageID),
           existing.captureStatus != .failed {
            dbg("✅ 이미 캐시에 존재 - 스킵: \(record.title) [상태: \(existing.captureStatus)]")
            return
        }
        
        lastLeavingStoreAt[context.pageID] = now
        markCaptureStarted(for: context.pageID)
        
        BFCacheSnapshot.create(pageRecord: record, webView: webView) { [weak self] snapshot in
            if snapshot.captureStatus == .failed {
                self?.markCaptureFailed(for: context.pageID)
                self?.dbg("❌ 캡처 실패 마킹: \(record.title)")
            } else {
                self?.storeSnapshot(snapshot, for: context.pageID)
            }
        }
    }
    
    /// 리다이렉트 감지 시 즉시 캡처
    func storeRedirectSnapshot(webView: WKWebView, record: PageRecord) {
        let context = CaptureContext(
            pageID: record.id,
            isRedirect: true,
            urgency: .immediate,
            timestamp: Date()
        )
        
        dbg("🔄 리다이렉트 스냅샷 즉시 캡처: \(record.title)")
        captureWithContext(context: context, webView: webView, record: record)
    }

    /// 사용자가 링크/폼으로 떠나기 직전 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord else { return }
        
        // 리다이렉트 체인이 있으면 즉시 캡처
        let urgency: CaptureContext.CaptureUrgency = (rec.redirectChain != nil) ? .immediate : .normal
        
        let context = CaptureContext(
            pageID: rec.id,
            isRedirect: rec.redirectChain != nil,
            urgency: urgency,
            timestamp: Date()
        )
        
        captureWithContext(context: context, webView: webView, record: rec)
    }

    /// 문서 로드 완료 후 도착 페이지를 저장
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord else { return }
        
        // 도착 페이지는 안정화 후 캡처
        captureWhenFullyStable(webView) { [weak self] in
            let context = CaptureContext(
                pageID: rec.id,
                isRedirect: false,
                urgency: .delayed,
                timestamp: Date()
            )
            
            self?.captureWithContext(context: context, webView: webView, record: rec)
        }
    }

    /// 안정화 대기 - 이미지 로드까지 고려
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
            const videos = Array.from(document.querySelectorAll('video')).slice(0, 5);
            const videosReady = videos.length === 0 || videos.every(v => v.readyState >= 2);
            const hasPendingFetch = window.performance && window.performance
                .getEntriesByType('resource')
                .filter(e => e.name.includes('api') || e.name.includes('ajax'))
                .some(e => e.responseEnd === 0);
            
            return {
                ready: docReady && imagesLoaded && videosReady && !hasPendingFetch,
                details: {
                    doc: docReady,
                    img: imagesLoaded,
                    vid: videosReady,
                    ajax: !hasPendingFetch
                }
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
                        self?.dbg("⏳ 페이지 안정화 대기 중: doc=\(details["doc"] ?? false), img=\(details["img"] ?? false), vid=\(details["vid"] ?? false), ajax=\(details["ajax"] ?? false)")
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
    
    // 캐시 정리 메서드
    func clearCacheForTab(_ tabID: UUID) {
        cacheQueue.async(flags: .barrier) {
            let keysToRemove = self.cache.keys.filter { _ in true }
            keysToRemove.forEach { self.cache.removeValue(forKey: $0) }
            self.pendingCaptures.removeAll()
            self.failedCaptures.removeAll()
            self.dbg("🗑️ 탭 캐시 정리: \(keysToRemove.count)개 항목 제거")
        }
    }
    
    // 메모리 경고 처리
    func handleMemoryWarning() {
        cacheQueue.async(flags: .barrier) {
            let sorted = self.cache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            
            sorted.prefix(removeCount).forEach { item in
                self.cache.removeValue(forKey: item.key)
            }
            
            self.pendingCaptures.removeAll()
            self.failedCaptures.removeAll()
            
            self.dbg("⚠️ 메모리 경고 - 캐시 \(removeCount)개 제거")
        }
    }
    
    
}
