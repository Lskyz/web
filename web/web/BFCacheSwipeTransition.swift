//
//  BFCacheSwipeTransition.swift
//  🚀 **완전히 리팩토링된 스크롤 복원 시스템**
//  ✅ 올리브영 5가지 시나리오 기반 재설계
//  🎯 단순하고 효과적인 복원 전략
//  ⚡ 빠른 렌더링과 최소 대기시간
//  📱 제스처와 미리보기 유지
//  🔧 직렬화 큐 시스템 유지
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

// MARK: - 🚀 스크롤 복원 전략 열거형
enum ScrollRestorationType {
    case static          // 정적 데이터 - 단순 위치 복원
    case dynamic         // 동적 데이터 - 아이템 기준 복원  
    case lazyLoad        // 레이지 로딩 - 스켈레톤 + 점진 로드
    case cached          // 캐시된 데이터 - 즉시 복원
    case virtualized     // 가상화 리스트 - 인덱스 복원
    
    var maxWaitTime: TimeInterval {
        switch self {
        case .static: return 0.1
        case .dynamic: return 0.3
        case .lazyLoad: return 0.5
        case .cached: return 0.2
        case .virtualized: return 0.2
        }
    }
}

// MARK: - 🎯 향상된 스크롤 상태
struct EnhancedScrollState: Codable {
    let scrollPosition: CGPoint
    let timestamp: Date
    let url: URL
    
    // 스크롤 복원에 필요한 최소 정보만 저장
    var anchorItem: AnchorItem?      // 기준점 아이템
    var contentHeight: CGFloat?       // 전체 콘텐츠 높이
    var visibleRange: VisibleRange?   // 보이는 범위
    var restorationType: String       // 복원 타입 저장
    
    struct AnchorItem: Codable {
        let id: String
        let offsetFromTop: CGFloat
        let selector: String?
    }
    
    struct VisibleRange: Codable {
        let firstVisibleId: String
        let lastVisibleId: String
        let startOffset: CGFloat
    }
}

// MARK: - 📸 간소화된 BFCache 스냅샷
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    let scrollState: EnhancedScrollState
    let imageData: Data?
    let captureQuality: CaptureQuality
    let timestamp: Date
    let version: Int
    
    enum CaptureQuality: String, Codable {
        case high    // 이미지 + 스크롤 데이터
        case medium  // 스크롤 데이터만
        case low     // 기본 위치만
    }
    
    // 스크롤 복원 타입 자동 결정
    var restorationType: ScrollRestorationType {
        // 캐시 수명이 10초 이내면 cached 타입
        if Date().timeIntervalSince(timestamp) < 10 {
            return .cached
        }
        
        // 앵커 아이템이 있으면 dynamic
        if scrollState.anchorItem != nil {
            return .dynamic
        }
        
        // 보이는 범위가 있으면 virtualized
        if scrollState.visibleRange != nil {
            return .virtualized
        }
        
        // 콘텐츠 높이가 크면 lazyLoad
        if let height = scrollState.contentHeight, height > 3000 {
            return .lazyLoad
        }
        
        // 기본은 static
        return .static
    }
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

// MARK: - 🎯 **리팩토링된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 직렬화 큐 (유지)
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "bfcache.cache", attributes: .concurrent)
    
    // MARK: - 간소화된 캐시
    private var memoryCache: [UUID: BFCacheSnapshot] = [:]
    private let cacheAccessQueue = DispatchQueue(label: "cache.access", attributes: .concurrent)
    
    // MARK: - 전환 상태 (유지)
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
    
    // MARK: - 🚀 **리팩토링: 간소화된 스냅샷 캡처**
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, tabID: UUID? = nil) {
        guard let webView = webView else { return }
        
        serialQueue.async { [weak self] in
            self?.performSimplifiedCapture(pageRecord: pageRecord, webView: webView, tabID: tabID)
        }
    }
    
    private func performSimplifiedCapture(pageRecord: PageRecord, webView: WKWebView, tabID: UUID?) {
        let pageID = pageRecord.id
        
        // 메인 스레드에서 스크롤 정보 수집
        let scrollData = DispatchQueue.main.sync { () -> (position: CGPoint, height: CGFloat)? in
            guard webView.window != nil, !webView.bounds.isEmpty else { return nil }
            return (webView.scrollView.contentOffset, webView.scrollView.contentSize.height)
        }
        
        guard let data = scrollData else {
            dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵")
            return
        }
        
        // 간단한 스크롤 정보 수집 (최대 0.2초)
        collectScrollInfo(webView: webView, pageRecord: pageRecord, scrollData: data) { [weak self] scrollState in
            
            // 이미지 캡처 (선택적, 최대 0.5초)
            self?.captureVisualSnapshot(webView: webView) { imageData in
                
                let quality: BFCacheSnapshot.CaptureQuality = imageData != nil ? .high : .medium
                
                let snapshot = BFCacheSnapshot(
                    pageRecord: pageRecord,
                    scrollState: scrollState,
                    imageData: imageData,
                    captureQuality: quality,
                    timestamp: Date(),
                    version: 1
                )
                
                // 메모리 캐시에 저장
                self?.cacheQueue.async(flags: .barrier) {
                    self?.memoryCache[pageID] = snapshot
                    self?.dbg("✅ 스냅샷 캐시 저장: \(pageRecord.title)")
                }
            }
        }
    }
    
    // 🎯 **스크롤 정보 수집 - 간소화**
    private func collectScrollInfo(webView: WKWebView, pageRecord: PageRecord, scrollData: (position: CGPoint, height: CGFloat), completion: @escaping (EnhancedScrollState) -> Void) {
        
        // 기본 스크롤 상태
        var scrollState = EnhancedScrollState(
            scrollPosition: scrollData.position,
            timestamp: Date(),
            url: pageRecord.url,
            anchorItem: nil,
            contentHeight: scrollData.height,
            visibleRange: nil,
            restorationType: "static"
        )
        
        // 보이는 아이템 정보 수집 (빠르게, 최대 0.2초)
        let anchorJS = """
        (function() {
            // 현재 보이는 주요 요소 찾기
            const elements = document.querySelectorAll('article, section, [data-id], .item, .card, .post');
            const viewport = window.innerHeight;
            const scrollY = window.scrollY;
            
            for (const el of elements) {
                const rect = el.getBoundingClientRect();
                // 화면 중앙에 가장 가까운 요소 찾기
                if (rect.top <= viewport/2 && rect.bottom >= viewport/2) {
                    return {
                        id: el.id || el.dataset.id || el.className,
                        offsetFromTop: rect.top + scrollY,
                        selector: el.id ? '#' + el.id : null
                    };
                }
            }
            
            // 못 찾으면 첫 번째 보이는 요소
            for (const el of elements) {
                const rect = el.getBoundingClientRect();
                if (rect.top >= 0 && rect.top < viewport) {
                    return {
                        id: el.id || el.dataset.id || el.className,
                        offsetFromTop: rect.top + scrollY,
                        selector: el.id ? '#' + el.id : null
                    };
                }
            }
            
            return null;
        })()
        """
        
        webView.evaluateJavaScript(anchorJS, completionHandler: { result, _ in
            if let anchorData = result as? [String: Any],
               let id = anchorData["id"] as? String {
                scrollState.anchorItem = EnhancedScrollState.AnchorItem(
                    id: id,
                    offsetFromTop: anchorData["offsetFromTop"] as? CGFloat ?? 0,
                    selector: anchorData["selector"] as? String
                )
                scrollState.restorationType = "dynamic"
            }
            
            completion(scrollState)
        })
    }
    
    // 📸 **시각적 스냅샷 캡처 - 간소화**
    private func captureVisualSnapshot(webView: WKWebView, completion: @escaping (Data?) -> Void) {
        DispatchQueue.main.async {
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            config.afterScreenUpdates = false
            
            // 타임아웃 0.5초
            var completed = false
            
            webView.takeSnapshot(with: config) { image, _ in
                guard !completed else { return }
                completed = true
                
                if let image = image {
                    // JPEG 압축 (품질 0.6)
                    let imageData = image.jpegData(compressionQuality: 0.6)
                    completion(imageData)
                } else {
                    completion(nil)
                }
            }
            
            // 타임아웃 처리
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard !completed else { return }
                completed = true
                completion(nil)
            }
        }
    }
    
    // MARK: - 🚀 **리팩토링: 스마트 스크롤 복원**
    
    func restoreScroll(for pageID: UUID, webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 캐시에서 스냅샷 가져오기
        guard let snapshot = retrieveSnapshot(for: pageID) else {
            dbg("❌ 캐시 미스: 스크롤 복원 불가")
            completion(false)
            return
        }
        
        // 복원 타입에 따른 전략 선택
        let restorationType = snapshot.restorationType
        dbg("🎯 스크롤 복원 시작: \(restorationType)")
        
        switch restorationType {
        case .static:
            restoreStaticScroll(snapshot: snapshot, webView: webView, completion: completion)
            
        case .dynamic:
            restoreDynamicScroll(snapshot: snapshot, webView: webView, completion: completion)
            
        case .lazyLoad:
            restoreLazyLoadScroll(snapshot: snapshot, webView: webView, completion: completion)
            
        case .cached:
            restoreCachedScroll(snapshot: snapshot, webView: webView, completion: completion)
            
        case .virtualized:
            restoreVirtualizedScroll(snapshot: snapshot, webView: webView, completion: completion)
        }
    }
    
    // 🎯 **시나리오 1: 정적 스크롤 복원 (즉시)**
    private func restoreStaticScroll(snapshot: BFCacheSnapshot, webView: WKWebView, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            webView.scrollView.setContentOffset(snapshot.scrollState.scrollPosition, animated: false)
            self.dbg("✅ 정적 스크롤 복원: \(snapshot.scrollState.scrollPosition)")
            completion(true)
        }
    }
    
    // 🎯 **시나리오 2: 동적 스크롤 복원 (아이템 기준, 최대 0.3초)**
    private func restoreDynamicScroll(snapshot: BFCacheSnapshot, webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let anchor = snapshot.scrollState.anchorItem else {
            restoreStaticScroll(snapshot: snapshot, webView: webView, completion: completion)
            return
        }
        
        // 앵커 아이템 찾기
        let findAnchorJS = """
        (function() {
            const id = '\(anchor.id)';
            const selector = \(anchor.selector != nil ? "'\(anchor.selector!)'" : "null");
            
            // ID나 selector로 찾기
            let element = null;
            if (selector) {
                element = document.querySelector(selector);
            }
            if (!element) {
                element = document.getElementById(id);
            }
            if (!element) {
                element = document.querySelector('[data-id="' + id + '"]');
            }
            
            if (element) {
                const rect = element.getBoundingClientRect();
                const currentOffset = rect.top + window.scrollY;
                const targetScrollY = currentOffset - \(anchor.offsetFromTop) + \(snapshot.scrollState.scrollPosition.y);
                
                window.scrollTo(0, targetScrollY);
                return true;
            }
            
            return false;
        })()
        """
        
        // 최대 0.3초 대기
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            webView.evaluateJavaScript(findAnchorJS) { result, _ in
                if result as? Bool == true {
                    self.dbg("✅ 동적 스크롤 복원: 앵커 \(anchor.id)")
                } else {
                    // 실패시 정적 복원
                    self.restoreStaticScroll(snapshot: snapshot, webView: webView, completion: { _ in })
                }
                completion(true)
            }
        }
    }
    
    // 🎯 **시나리오 3: 레이지 로드 스크롤 복원 (스켈레톤 UI, 최대 0.5초)**
    private func restoreLazyLoadScroll(snapshot: BFCacheSnapshot, webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let contentHeight = snapshot.scrollState.contentHeight ?? 2000
        let scrollY = snapshot.scrollState.scrollPosition.y
        
        // 1. 스켈레톤 생성 (즉시)
        let skeletonJS = """
        (function() {
            // 스켈레톤 컨테이너 생성
            const skeleton = document.createElement('div');
            skeleton.id = 'bfcache-skeleton';
            skeleton.style.minHeight = '\(contentHeight)px';
            skeleton.style.background = 'linear-gradient(180deg, #f5f5f5 0%, #e0e0e0 100%)';
            skeleton.style.opacity = '0.3';
            skeleton.style.position = 'absolute';
            skeleton.style.width = '100%';
            skeleton.style.top = '0';
            skeleton.style.zIndex = '-1';
            
            document.body.appendChild(skeleton);
            
            // 즉시 스크롤
            window.scrollTo(0, \(scrollY));
            
            // 0.5초 후 제거
            setTimeout(() => {
                skeleton.remove();
            }, 500);
            
            return true;
        })()
        """
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(skeletonJS) { _, _ in
                self.dbg("✅ 레이지 로드 스크롤 복원: 높이 \(contentHeight)")
                completion(true)
            }
        }
    }
    
    // 🎯 **시나리오 4: 캐시된 스크롤 복원 (React Query 스타일, 즉시)**
    private func restoreCachedScroll(snapshot: BFCacheSnapshot, webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 캐시가 신선하면 즉시 복원
        DispatchQueue.main.async {
            // 이미지가 있으면 미리보기로 표시
            if let imageData = snapshot.imageData,
               let image = UIImage(data: imageData) {
                self.showTemporaryPreview(image: image, in: webView, duration: 0.2)
            }
            
            // 스크롤 위치 즉시 복원
            webView.scrollView.setContentOffset(snapshot.scrollState.scrollPosition, animated: false)
            self.dbg("✅ 캐시 스크롤 즉시 복원")
            completion(true)
        }
    }
    
    // 🎯 **시나리오 5: 가상화 스크롤 복원 (인덱스 기반, 최대 0.2초)**
    private func restoreVirtualizedScroll(snapshot: BFCacheSnapshot, webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let range = snapshot.scrollState.visibleRange else {
            restoreStaticScroll(snapshot: snapshot, webView: webView, completion: completion)
            return
        }
        
        let virtualJS = """
        (function() {
            // 가상 스크롤 컨테이너 찾기
            const containers = document.querySelectorAll('[data-virtual], .virtual-list, .infinite-scroll');
            if (containers.length > 0) {
                const firstId = '\(range.firstVisibleId)';
                const element = document.getElementById(firstId) || 
                               document.querySelector('[data-id="' + firstId + '"]');
                
                if (element) {
                    element.scrollIntoView({ behavior: 'instant' });
                    window.scrollBy(0, -\(range.startOffset));
                    return true;
                }
            }
            
            // 실패시 기본 스크롤
            window.scrollTo(0, \(snapshot.scrollState.scrollPosition.y));
            return false;
        })()
        """
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            webView.evaluateJavaScript(virtualJS) { result, _ in
                if result as? Bool == true {
                    self.dbg("✅ 가상화 스크롤 복원: \(range.firstVisibleId)")
                } else {
                    self.dbg("⚠️ 가상화 복원 실패, 기본 복원 사용")
                }
                completion(true)
            }
        }
    }
    
    // 임시 프리뷰 표시
    private func showTemporaryPreview(image: UIImage, in webView: WKWebView, duration: TimeInterval) {
        let imageView = UIImageView(image: image)
        imageView.frame = webView.bounds
        imageView.alpha = 1.0
        webView.addSubview(imageView)
        
        UIView.animate(withDuration: duration, animations: {
            imageView.alpha = 0
        }) { _ in
            imageView.removeFromSuperview()
        }
    }
    
    // MARK: - 캐시 관리
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        return cacheQueue.sync {
            return memoryCache[pageID]
        }
    }
    
    func hasCache(for pageID: UUID) -> Bool {
        return retrieveSnapshot(for: pageID) != nil
    }
    
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        cacheQueue.async(flags: .barrier) {
            for pageID in pageIDs {
                self.memoryCache.removeValue(forKey: pageID)
            }
        }
        dbg("🗑️ 탭 캐시 삭제: \(pageIDs.count)개")
    }
    
    // MARK: - 메모리 관리
    
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
        cacheQueue.async(flags: .barrier) {
            // 오래된 캐시 50% 제거
            let sorted = self.memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            sorted.prefix(removeCount).forEach { item in
                self.memoryCache.removeValue(forKey: item.key)
            }
            self.dbg("⚠️ 메모리 경고 - 캐시 정리: \(removeCount)개 제거")
        }
    }
    
    // MARK: - 🎯 **제스처 시스템 (유지 + 개선)**
    
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
        
        // 약한 참조 컨텍스트 생성
        if let tabID = stateModel.tabID {
            let ctx = WeakGestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
            objc_setAssociatedObject(leftEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(rightEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        dbg("제스처 설정 완료")
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
        
        // 수직 슬롭/부호 반대 방지
        let absX = abs(translation.x), absY = abs(translation.y)
        let horizontalEnough = absX > 8 && absX > absY
        let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
        
        switch gesture.state {
        case .began:
            // 전환 중이면 새 제스처 무시
            guard activeTransitions[tabID] == nil else { 
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 현재 페이지 캡처
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, tabID: tabID)
                }
                
                // 현재 웹뷰 스냅샷 캡처 후 전환 시작
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
        
        var completed = false
        
        webView.takeSnapshot(with: captureConfig) { image, _ in
            guard !completed else { return }
            completed = true
            completion(image)
        }
        
        // 타임아웃 0.3초
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !completed else { return }
            completed = true
            completion(nil)
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
        
        dbg("🎬 전환 시작: \(direction == .back ? "뒤로" : "앞으로")")
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
            
            // 캐시된 이미지 확인
            if let snapshot = retrieveSnapshot(for: targetRecord.id),
               let imageData = snapshot.imageData,
               let targetImage = UIImage(data: imageData) {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
                dbg("📸 캐시된 미리보기 사용: \(targetRecord.title)")
            } else {
                targetView = createInfoCard(for: targetRecord, in: webView.bounds)
                dbg("ℹ️ 정보 카드 생성: \(targetRecord.title)")
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
        
        let titleLabel = UILabel()
        titleLabel.text = record.title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.frame = CGRect(x: 20, y: bounds.height/2 - 30, width: bounds.width - 40, height: 60)
        card.addSubview(titleLabel)
        
        return card
    }
    
    // 🎬 **전환 완료 - 스크롤 복원 통합**
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer,
              let stateModel = context.stateModel else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            usingSpringWithDamping: 0.9,
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
                // 네비게이션 수행
                switch context.direction {
                case .back:
                    stateModel.goBack()
                case .forward:
                    stateModel.goForward()
                }
                
                // 타겟 페이지의 스크롤 복원
                if let targetIndex = (context.direction == .back ? 
                    stateModel.dataModel.currentPageIndex : 
                    stateModel.dataModel.currentPageIndex),
                   targetIndex >= 0,
                   targetIndex < stateModel.dataModel.pageHistory.count {
                    
                    let targetRecord = stateModel.dataModel.pageHistory[targetIndex]
                    
                    self?.restoreScroll(for: targetRecord.id, webView: webView) { success in
                        self?.dbg("스크롤 복원 \(success ? "성공" : "실패")")
                    }
                }
                
                // 미리보기 제거 (0.3초 후)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    previewContainer.removeFromSuperview()
                    self?.activeTransitions.removeValue(forKey: tabID)
                }
            }
        )
    }
    
    private func cancelGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = (context.webView?.bounds.width ?? 0)
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.2,
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
        
        // 현재 페이지 캡처
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, tabID: tabID)
        }
        
        stateModel.goBack()
        
        // 타겟 페이지 스크롤 복원
        if let targetRecord = stateModel.dataModel.currentPageRecord {
            restoreScroll(for: targetRecord.id, webView: webView) { _ in }
        }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 캡처
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, tabID: tabID)
        }
        
        stateModel.goForward()
        
        // 타겟 페이지 스크롤 복원
        if let targetRecord = stateModel.dataModel.currentPageRecord {
            restoreScroll(for: targetRecord.id, webView: webView) { _ in }
        }
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
    
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        shared.setupGestures(for: webView, stateModel: stateModel)
        TabPersistenceManager.debugMessages.append("✅ 리팩토링된 BFCache 시스템 설치 완료")
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
        // 복원 중이면 무시
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        // 새 페이지로 추가
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지 추가: \(url.absoluteString)")
    }
}

// MARK: - 퍼블릭 래퍼
extension BFCacheTransitionSystem {
    
    /// 사용자가 링크/폼으로 떠나기 직전 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, tabID: tabID)
        dbg("📸 떠나기 스냅샷 캡처: \(rec.title)")
    }

    /// 페이지 로드 완료 후 자동 캐시 강화
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처: \(rec.title)")
        
        // 이전 페이지들 메타데이터 확인 (최대 3개)
        if stateModel.dataModel.currentPageIndex > 0 {
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                if !hasCache(for: previousRecord.id) {
                    // 간단한 스크롤 상태만 저장
                    let basicScrollState = EnhancedScrollState(
                        scrollPosition: .zero,
                        timestamp: Date(),
                        url: previousRecord.url,
                        anchorItem: nil,
                        contentHeight: nil,
                        visibleRange: nil,
                        restorationType: "static"
                    )
                    
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollState: basicScrollState,
                        imageData: nil,
                        captureQuality: .low,
                        timestamp: Date(),
                        version: 1
                    )
                    
                    cacheQueue.async(flags: .barrier) {
                        self.memoryCache[previousRecord.id] = metadataSnapshot
                    }
                    
                    dbg("📝 이전 페이지 메타데이터 저장: \(previousRecord.title)")
                }
            }
        }
    }
}
