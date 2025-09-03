//
//  BFCacheSwipeTransition.swift
//  🎯 **올바른 점진적 복원 - 올인원 복원 후 데이터 점진적 채움**
//  ✅ 1. 데이터·위치 동시 저장 - scrollY + 아이템 정보 + 시퀀스 통합
//  ✅ 2. 스켈레톤 기반 즉시 채움 - 부족한 영역 스켈레톤으로 확보
//  ✅ 3. 올인원 복원 - 저장된 블록 기반 **즉시 최종 위치 이동**
//  ✅ 4. 스크롤 위치 고정 - 이후 데이터 로딩 시 위치 변동 없음
//  ✅ 5. 비동기 데이터 교체 - 스켈레톤→실제 데이터 깜박임 없이 교체
//  🚫 3단계 복원 제거 → 단일 복원 후 데이터만 점진적 채움
//  ⚡ 사용자 경험: 이미 복원된 상태에서 점차 안정화
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

// MARK: - 📸 **올인원 점진적 복원 스냅샷**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 🎯 **통합 스크롤 상태 블록** - 올인원 복원을 위한 완전한 상태
    let scrollStateBlock: ScrollStateBlock
    
    // 🎯 **스켈레톤 템플릿** - 부족한 데이터 영역 즉시 채움용
    let skeletonTemplate: SkeletonTemplate
    
    // 🎯 **데이터 로딩 가이드** - 복원 후 비동기 데이터 채움 순서
    let dataLoadingGuide: DataLoadingGuide
    
    // 🎯 **통합 스크롤 상태 블록** - 모든 정보를 한 번에 복원
    struct ScrollStateBlock: Codable {
        let finalScrollY: CGFloat          // 최종 복원 위치
        let viewportHeight: CGFloat
        let totalContentHeight: CGFloat
        
        // 앵커 아이템 정보 (스크롤 위치 기준점)
        let anchorItem: AnchorItemInfo
        
        // 가시 영역 아이템들 (즉시 표시용)
        let visibleItems: [VisibleItemInfo]
        
        // 가상화/무한 스크롤 상태
        let virtualizationState: VirtualizationState
        
        // 컨테이너별 스크롤 상태
        let containerScrolls: [String: CGFloat]
        
        // 캐시 키 정보 (React Query 스타일)
        let cacheKeys: [String: String]
        
        struct AnchorItemInfo: Codable {
            let id: String
            let selector: String
            let offsetFromTop: CGFloat     // 뷰포트 상단으로부터 거리
            let elementHeight: CGFloat
            let isSticky: Bool             // sticky 헤더인지 여부
        }
        
        struct VisibleItemInfo: Codable {
            let id: String
            let selector: String
            let offsetTop: CGFloat
            let height: CGFloat
            let content: String?           // 텍스트 콘텐츠 (검증용)
            let hasImage: Bool            // 이미지 포함 여부
            let loadPriority: Int         // 로딩 우선순위 (1=최우선)
        }
        
        struct VirtualizationState: Codable {
            let isVirtual: Bool
            let currentSequence: Int       // 현재 시퀀스 번호
            let visibleStartIndex: Int     // 가시 시작 인덱스
            let visibleEndIndex: Int       // 가시 종료 인덱스
            let totalKnownItems: Int
            let pageInfo: PageInfo?
            
            struct PageInfo: Codable {
                let currentPage: Int
                let pageSize: Int
                let loadedPages: [Int]     // 로딩된 페이지 목록
                let hasNextPage: Bool
            }
        }
    }
    
    // 🎯 **스켈레톤 템플릿** - 즉시 레이아웃 확보
    struct SkeletonTemplate: Codable {
        let averageItemHeight: CGFloat
        let itemsPerScreen: Int
        let totalSkeletonItems: Int       // 생성할 스켈레톤 개수
        let skeletonPattern: String       // 스켈레톤 HTML 패턴
        let placeholderStyles: [String: String] // CSS 스타일 맵
    }
    
    // 🎯 **데이터 로딩 가이드** - 복원 후 비동기 채움 순서
    struct DataLoadingGuide: Codable {
        let loadingSequence: [LoadingStep]
        let backgroundLoadingEnabled: Bool
        let lockScrollDuringLoad: Bool     // 데이터 로딩 중 스크롤 위치 고정
        
        struct LoadingStep: Codable {
            let stepId: String
            let dataSource: String         // API 엔드포인트 또는 캐시 키
            let targetSelectors: [String]  // 교체할 스켈레톤 선택자
            let delayMs: Int              // 로딩 지연 시간
            let priority: Int             // 1=최우선
            let fallbackContent: String?   // 로딩 실패시 대체 콘텐츠
        }
    }
    
    enum CaptureStatus: String, Codable {
        case complete, partial, visualOnly, failed
    }
    
    // MARK: - Codable 구현
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, jsState, timestamp
        case webViewSnapshotPath, captureStatus, version
        case scrollStateBlock, skeletonTemplate, dataLoadingGuide
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
        
        scrollStateBlock = try container.decode(ScrollStateBlock.self, forKey: .scrollStateBlock)
        skeletonTemplate = try container.decode(SkeletonTemplate.self, forKey: .skeletonTemplate)
        dataLoadingGuide = try container.decode(DataLoadingGuide.self, forKey: .dataLoadingGuide)
        
        // JSON decode for [String: Any]
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
        
        try container.encode(scrollStateBlock, forKey: .scrollStateBlock)
        try container.encode(skeletonTemplate, forKey: .skeletonTemplate)
        try container.encode(dataLoadingGuide, forKey: .dataLoadingGuide)
        
        // JSON encode for [String: Any]
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
    }
    
    // 직접 초기화
    init(pageRecord: PageRecord, scrollPosition: CGPoint, jsState: [String: Any]? = nil,
         timestamp: Date = Date(), webViewSnapshotPath: String? = nil, 
         captureStatus: CaptureStatus = .partial, version: Int = 1,
         scrollStateBlock: ScrollStateBlock,
         skeletonTemplate: SkeletonTemplate,
         dataLoadingGuide: DataLoadingGuide) {
        self.pageRecord = pageRecord
        self.domSnapshot = nil
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.scrollStateBlock = scrollStateBlock
        self.skeletonTemplate = skeletonTemplate
        self.dataLoadingGuide = dataLoadingGuide
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🎯 **핵심: 올인원 점진적 복원 - 즉시 최종 위치 이동**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard captureStatus != .failed else {
            completion(false)
            return
        }
        
        TabPersistenceManager.debugMessages.append("🎯 올인원 점진적 복원 시작: 즉시 최종 위치로 이동")
        
        // iOS 웹뷰 특화: history.scrollRestoration 강제 manual
        webView.evaluateJavaScript("if (history.scrollRestoration) { history.scrollRestoration = 'manual'; }") { _, _ in }
        
        performAllInOneRestore(to: webView, completion: completion)
    }
    
    // 🎯 **올인원 복원 + 점진적 데이터 채움 시스템**
   private func performAllInOneRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
    let stateBlock = scrollStateBlock
       
    // **1단계: 스켈레톤으로 전체 레이아웃 즉시 확보**
    createFullSkeleton(to: webView) { skeletonSuccess in
        // **2단계: 저장된 상태 블록 기반으로 즉시 최종 위치 이동 (한 번만!)**
        self.executeOneTimeRestore(to: webView, stateBlock: stateBlock) { restoreSuccess in
            TabPersistenceManager.debugMessages.append("✅ 올인원 복원 완료: \(restoreSuccess ? "성공" : "실패")")
               
            // **3단계: 복원 후 데이터 점진적 채움 (스크롤 위치 고정)**
            if restoreSuccess {
                self.startProgressiveDataFilling(to: webView)
            }
               
            completion(restoreSuccess)
        }
    }
}
    
    // 🎯 **스켈레톤 전체 레이아웃 즉시 확보**
    private func createFullSkeleton(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
    let template = skeletonTemplate
    let totalHeight = max(scrollStateBlock.totalContentHeight, CGFloat(template.totalSkeletonItems) * template.averageItemHeight)
    
    let fullSkeletonJS = """
    (function() {
        try {
            // 기존 스켈레톤 정리
            const existing = document.querySelectorAll('.bfcache-skeleton, .bfcache-skeleton-container');
            existing.forEach(el => el.remove());
            
            // 전체 스켈레톤 컨테이너 생성
            const skeletonContainer = document.createElement('div');
            skeletonContainer.className = 'bfcache-skeleton-container';
            skeletonContainer.style.cssText = `
                position: relative;
                min-height: ${totalHeight}px;
                background: #f8f9fa;
            `;
            
            // 개별 스켈레톤 아이템들 생성
            for (let i = 0; i < \(template.totalSkeletonItems); i++) {
                const skeletonItem = document.createElement('div');
                skeletonItem.className = 'bfcache-skeleton bfcache-skeleton-' + i;
                skeletonItem.style.cssText = `
                    height: \(template.averageItemHeight)px;
                    margin: 8px 16px;
                    background: linear-gradient(90deg, #e2e8f0 25%, #f1f5f9 50%, #e2e8f0 75%);
                    background-size: 200% 100%;
                    animation: bfcache-shimmer 1.8s infinite;
                    border-radius: 8px;
                    position: relative;
                `;
                
                skeletonItem.innerHTML = `\(template.skeletonPattern)`;
                skeletonContainer.appendChild(skeletonItem);
            }
            
            // 스켈레톤 애니메이션 CSS 주입
            if (!document.getElementById('bfcache-skeleton-styles')) {
                const style = document.createElement('style');
                style.id = 'bfcache-skeleton-styles';
                style.textContent = `
                    @keyframes bfcache-shimmer {
                        0% { background-position: -200% 0; }
                        100% { background-position: 200% 0; }
                    }
                    .bfcache-skeleton-container {
                        -webkit-transform: translateZ(0);
                        will-change: auto;
                    }
                `;
                document.head.appendChild(style);
            }
            
            // DOM에 스켈레톤 추가
            const targetContainer = document.body;
            const firstChild = targetContainer.firstChild;
            if (firstChild) {
                targetContainer.insertBefore(skeletonContainer, firstChild);
            } else {
                targetContainer.appendChild(skeletonContainer);
            }
            
            window.__BFCACHE_SKELETON_ACTIVE__ = true;
            return true;
        } catch (e) {
            console.error('스켈레톤 생성 실패:', e);
            return false;
        }
    })()
    """
    
    webView.evaluateJavaScript(fullSkeletonJS) { result, error in
        let success = (result as? Bool) ?? false
        if success {
            TabPersistenceManager.debugMessages.append("📐 스켈레톤 생성 성공: \(template.totalSkeletonItems)개, 높이=\(totalHeight)")
        } else {
            TabPersistenceManager.debugMessages.append("❌ 스켈레톤 생성 실패: \(error?.localizedDescription ?? "unknown")")
        }
        completion(success)
    }
}
    
    // 🎯 **핵심: 단일 올인원 복원 - 스크롤 위치는 한 번만 이동**
    private func executeOneTimeRestore(to webView: WKWebView, stateBlock: ScrollStateBlock, completion: @escaping (Bool) -> Void) {
    let finalScrollY = stateBlock.finalScrollY
    let anchorItem = stateBlock.anchorItem
    
    let oneTimeRestoreJS = """
    (function() {
        try {
            // DOM 준비 확인
            if (document.readyState !== 'complete') {
                console.warn('DOM 미완료 - 스크롤 복원 지연');
                return new Promise(resolve => {
                    document.addEventListener('DOMContentLoaded', () => resolve(true));
                }).then(() => performRestore());
            }
            return performRestore();
            
            function performRestore() {
                // 1. 기본 스크롤 위치 설정
                const targetY = \(finalScrollY);
                window.scrollTo(0, targetY);
                
                // 2. 앵커 아이템 기준 정밀 조정
                const anchorElement = document.querySelector('\(anchorItem.selector)');
                if (!anchorElement) {
                    console.warn('앵커 요소 없음: \(anchorItem.selector)');
                } else {
                    const currentTop = anchorElement.getBoundingClientRect().top;
                    const expectedTop = \(anchorItem.offsetFromTop);
                    const adjustment = expectedTop - currentTop;
                    
                    if (Math.abs(adjustment) > 5) {
                        window.scrollTo(0, targetY + adjustment);
                    }
                }
                
                // 3. 컨테이너별 스크롤 복원
                const containerScrolls = \(jsonString(from: stateBlock.containerScrolls));
                Object.keys(containerScrolls).forEach(selector => {
                    const container = document.querySelector(selector);
                    if (container) {
                        container.scrollTop = containerScrolls[selector];
                    }
                });
                
                // 4. 가상화/무한 스크롤 상태 복원
                if (\(stateBlock.virtualizationState.isVirtual)) {
                    if (window.virtualScroller) {
                        window.virtualScroller.scrollToIndex(\(stateBlock.virtualizationState.visibleStartIndex));
                    }
                    if (window.infiniteScroll) {
                        window.infiniteScroll.setCurrentPage(\(stateBlock.virtualizationState.pageInfo?.currentPage ?? 0));
                    }
                }
                
                // 5. React Query 캐시 적용
                const cacheKeys = \(jsonString(from: stateBlock.cacheKeys));
                if (window.__REACT_QUERY_STATE__ && cacheKeys.reactQuery) {
                    const cachedData = window.__REACT_QUERY_STATE__[cacheKeys.reactQuery];
                    if (cachedData?.data && window.hydrateCachedData) {
                        window.hydrateCachedData(cachedData.data, false);
                    }
                }
                
                // 6. 스크롤 위치 고정 플래그 설정
                window.__BFCACHE_SCROLL_LOCKED__ = true;
                window.__BFCACHE_FINAL_SCROLL_Y__ = window.scrollY;
                
                // 7. 스크롤 이벤트 모니터링
                const scrollLockHandler = () => {
                    if (window.__BFCACHE_SCROLL_LOCKED__ && Math.abs(window.scrollY - window.__BFCACHE_FINAL_SCROLL_Y__) > 5) {
                        console.warn('스크롤 변동 감지, 복원: ', window.scrollY);
                        window.scrollTo(0, window.__BFCACHE_FINAL_SCROLL_Y__);
                    }
                };
                window.addEventListener('scroll', scrollLockHandler, { passive: false });
                
                // 8. 복원 완료 이벤트
                window.dispatchEvent(new CustomEvent('bfcacheRestoreComplete', {
                    detail: {
                        finalScrollY: window.scrollY,
                        restoredFromCache: true,
                        timestamp: Date.now()
                    }
                }));
                
                // 9. 스크롤 위치 검증
                console.log('스크롤 복원 검증: 기대 Y=' + targetY + ', 실제 Y=' + window.scrollY);
                return Math.abs(window.scrollY - targetY) < 5;
            }
        } catch (e) {
            console.error('올인원 복원 실패:', e);
            return false;
        }
    })()
    """
    
    DispatchQueue.main.async {
        // 네이티브 스크롤뷰 먼저 설정
        webView.scrollView.setContentOffset(CGPoint(x: 0, y: finalScrollY), animated: false)
        
        // JavaScript 실행 및 결과 확인
        webView.evaluateJavaScript(oneTimeRestoreJS) { result, error in
            let success = (result as? Bool) ?? false
            if success {
                TabPersistenceManager.debugMessages.append("✅ 올인원 복원 성공: Y=\(finalScrollY)")
            } else {
                TabPersistenceManager.debugMessages.append("❌ 올인원 복원 실패: \(error?.localizedDescription ?? "unknown")")
                // 실제 스크롤 위치 확인
                webView.evaluateJavaScript("window.scrollY") { scrollY, _ in
                    TabPersistenceManager.debugMessages.append("스크롤 검증: 기대 Y=\(finalScrollY), 실제 Y=\(scrollY ?? "unknown")")
                }
            }
            completion(success)
        }
        
        // 추가 검증: 100ms 후 스크롤 위치 재확인
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            webView.evaluateJavaScript("window.scrollY") { scrollY, _ in
                if let currentY = scrollY as? CGFloat, abs(currentY - finalScrollY) > 5 {
                    TabPersistenceManager.debugMessages.append("⚠️ 스크롤 위치 변동: 기대 Y=\(finalScrollY), 실제 Y=\(currentY)")
                    // 보정 시도
                    webView.scrollView.setContentOffset(CGPoint(x: 0, y: finalScrollY), animated: false)
                    webView.evaluateJavaScript("window.scrollTo(0, \(finalScrollY));")
                }
            }
        }
    }
}
    
    // 🎯 **점진적 데이터 채움 - 복원 후 스크롤 위치 고정 상태에서 데이터만 교체**
    private func startProgressiveDataFilling(to webView: WKWebView) {
        let guide = dataLoadingGuide
        
        TabPersistenceManager.debugMessages.append("📊 점진적 데이터 채움 시작: \(guide.loadingSequence.count)단계")
        
        // 로딩 단계를 우선순위 순으로 정렬
        let sortedSteps = guide.loadingSequence.sorted { $0.priority < $1.priority }
        
        executeDataLoadingSteps(to: webView, steps: sortedSteps, currentIndex: 0)
    }
    
    // **재귀적 데이터 로딩 단계 실행** (스크롤 위치는 절대 변경하지 않음)
    private func executeDataLoadingSteps(to webView: WKWebView, steps: [DataLoadingGuide.LoadingStep], currentIndex: Int) {
        guard currentIndex < steps.count else {
            finalizeDataFilling(to: webView)
            return
        }
        
        let step = steps[currentIndex]
        let delay = Double(step.delayMs) / 1000.0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.executeDataLoadingStep(to: webView, step: step) { success in
                TabPersistenceManager.debugMessages.append("📊 \(step.stepId) 로딩: \(success ? "성공" : "실패")")
                
                // 다음 단계로 진행 (성공 여부와 관계없이)
                self.executeDataLoadingSteps(to: webView, steps: steps, currentIndex: currentIndex + 1)
            }
        }
    }
    
    // **개별 데이터 로딩 단계 실행**
    private func executeDataLoadingStep(to webView: WKWebView, step: DataLoadingGuide.LoadingStep, completion: @escaping (Bool) -> Void) {
        let dataFillJS = """
        (function() {
            try {
                // 스크롤 위치 고정 확인
                if (!window.__BFCACHE_SCROLL_LOCKED__) {
                    console.warn('스크롤 고정 상태가 아님 - 데이터 로딩 중단');
                    return false;
                }
                
                const targetSelectors = \(jsonString(from: step.targetSelectors));
                let replacedCount = 0;
                
                // 캐시 또는 API에서 데이터 가져오기
                let data = null;
                
                // React Query 캐시 우선 확인
                if (window.__REACT_QUERY_STATE__ && '\(step.dataSource)'.startsWith('cache:')) {
                    const cacheKey = '\(step.dataSource)'.replace('cache:', '');
                    const cached = window.__REACT_QUERY_STATE__[cacheKey];
                    if (cached?.data) {
                        data = cached.data;
                    }
                }
                
                // 스켈레톤→실제 데이터 교체 (requestAnimationFrame으로 깜박임 방지)
                targetSelectors.forEach(selector => {
                    requestAnimationFrame(() => {
                        const skeletons = document.querySelectorAll(selector);
                        skeletons.forEach((skeleton, index) => {
                            if (data && data[index]) {
                                // 실제 데이터로 교체
                                const realContent = document.createElement('div');
                                realContent.innerHTML = data[index].html || data[index].content || '';
                                realContent.className = skeleton.className.replace('bfcache-skeleton', '');
                                
                                skeleton.parentNode.replaceChild(realContent, skeleton);
                                replacedCount++;
                            } else if ('\(step.fallbackContent ?? "")') {
                                // 폴백 콘텐츠로 교체
                                skeleton.innerHTML = '\(step.fallbackContent ?? "")';
                                skeleton.className = skeleton.className.replace('bfcache-skeleton', 'bfcache-fallback');
                                replacedCount++;
                            }
                        });
                    });
                });
                
                // 스크롤 위치 재고정 (혹시 모를 변동 방지)
                if (window.__BFCACHE_FINAL_SCROLL_Y__ !== undefined) {
                    window.scrollTo(0, window.__BFCACHE_FINAL_SCROLL_Y__);
                }
                
                return replacedCount > 0;
            } catch (e) {
                console.error('데이터 로딩 단계 실패:', e);
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(dataFillJS) { result, error in
            let success = (result as? Bool) ?? false
            completion(success)
        }
    }
    
    // **데이터 채움 완료 처리**
    private func finalizeDataFilling(to webView: WKWebView) {
        let finalizeJS = """
        (function() {
            try {
                // 남은 스켈레톤 제거
                const remainingSkeletons = document.querySelectorAll('.bfcache-skeleton');
                remainingSkeletons.forEach(skeleton => {
                    skeleton.style.display = 'none'; // 즉시 숨김
                    setTimeout(() => skeleton.remove(), 100); // 지연 제거
                });
                
                // 스켈레톤 스타일 정리
                const skeletonStyles = document.getElementById('bfcache-skeleton-styles');
                if (skeletonStyles) {
                    skeletonStyles.remove();
                }
                
                // 스크롤 위치 고정 해제
                window.__BFCACHE_SCROLL_LOCKED__ = false;
                window.__BFCACHE_SKELETON_ACTIVE__ = false;
                delete window.__BFCACHE_FINAL_SCROLL_Y__;
                
                // 점진적 데이터 채움 완료 이벤트
                window.dispatchEvent(new CustomEvent('bfcacheDataFillComplete', {
                    detail: { 
                        finalScrollY: window.scrollY,
                        timestamp: Date.now()
                    }
                }));
                
                return true;
            } catch (e) {
                console.error('데이터 채움 완료 처리 실패:', e);
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(finalizeJS) { result, error in
            TabPersistenceManager.debugMessages.append("🎉 점진적 데이터 채움 완료")
        }
    }
    
    // JSON 문자열 헬퍼
    private func jsonString(from object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

// MARK: - 🎯 **올인원 점진적 복원 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 직렬화 캐시 시스템 (기존 유지)
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // 스레드 안전 캐시 시스템
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
    
    private var diskCacheIndex: [UUID: String] {
        get { cacheAccessQueue.sync { _diskCacheIndex } }
    }
    
    private func setDiskIndex(_ path: String, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._diskCacheIndex[pageID] = path
        }
    }
    
    // MARK: - 📁 파일 시스템 경로 (기존 유지)
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
    
    // MARK: - 전환 상태 (기존 유지)
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
    
    enum CaptureType {
        case immediate
        case background
    }
    
    // MARK: - 🎯 **통합 스크롤 상태 캡처 시스템**
    
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
            self?.performUnifiedCapture(task)
        }
    }
    
    // 🎯 **통합 상태 캡처 - 모든 정보를 한 번에 수집**
    private func performUnifiedCapture(_ task: CaptureTask) {
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
        dbg("🎯 통합 상태 캡처 시작: \(task.pageRecord.title)")
        
        // 메인 스레드에서 기본 데이터 수집
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                isLoading: webView.isLoading,
                url: task.pageRecord.url
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // **통합 상태 블록 생성** - 모든 정보를 한 번에 수집
        let captureResult = createUnifiedScrollStateBlock(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data
        )
        
        // 캐시 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        pendingCaptures.remove(pageID)
        dbg("✅ 통합 상태 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
        let url: URL
    }
    
    // 🎯 **통합 스크롤 상태 블록 생성** - 올인원 복원을 위한 완전한 정보 수집
    private func createUnifiedScrollStateBlock(pageRecord: PageRecord, webView: WKWebView, 
                                             captureData: CaptureData) 
                                             -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        var visualSnapshot: UIImage?
        var scrollStateBlock: BFCacheSnapshot.ScrollStateBlock!
        var skeletonTemplate: BFCacheSnapshot.SkeletonTemplate!
        var dataLoadingGuide: BFCacheSnapshot.DataLoadingGuide!
        
        // 1. 비주얼 스냅샷 캡처
        visualSnapshot = captureVisualSnapshot(webView: webView, bounds: captureData.bounds)
        
        // 2. 통합 스크롤 상태 블록 수집
        let scrollData = executeUnifiedScrollCapture(webView: webView, scrollY: captureData.scrollPosition.y)
        
        // 3. 상태 블록 구성
        scrollStateBlock = BFCacheSnapshot.ScrollStateBlock(
            finalScrollY: captureData.scrollPosition.y,
            viewportHeight: captureData.bounds.height,
            totalContentHeight: scrollData?["contentHeight"] as? CGFloat ?? 0,
            anchorItem: extractAnchorItem(from: scrollData),
            visibleItems: extractVisibleItems(from: scrollData),
            virtualizationState: extractVirtualizationState(from: scrollData),
            containerScrolls: extractContainerScrolls(from: scrollData),
            cacheKeys: extractCacheKeys(from: scrollData)
        )
        
        // 4. 스켈레톤 템플릿 생성
        skeletonTemplate = BFCacheSnapshot.SkeletonTemplate(
            averageItemHeight: scrollData?["averageItemHeight"] as? CGFloat ?? 120,
            itemsPerScreen: Int(captureData.bounds.height / 120),
            totalSkeletonItems: calculateTotalSkeletons(from: scrollData),
            skeletonPattern: createSkeletonPattern(from: scrollData),
            placeholderStyles: [:]
        )
        
        // 5. 데이터 로딩 가이드 생성
        dataLoadingGuide = BFCacheSnapshot.DataLoadingGuide(
            loadingSequence: createLoadingSequence(from: scrollData),
            backgroundLoadingEnabled: true,
            lockScrollDuringLoad: true
        )
        
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && scrollData != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = .visualOnly
        } else {
            captureStatus = .failed
        }
        
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            scrollPosition: captureData.scrollPosition,
            jsState: scrollData,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version,
            scrollStateBlock: scrollStateBlock,
            skeletonTemplate: skeletonTemplate,
            dataLoadingGuide: dataLoadingGuide
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🎯 **통합 스크롤 캡처 JavaScript** - 모든 상황 대응 데이터 수집
    private func executeUnifiedScrollCapture(webView: WKWebView, scrollY: CGFloat) -> [String: Any]? {
        return executeJavaScriptSync(webView: webView, script: """
        (function() {
            try {
                // 기본 스크롤 정보
                const scrollInfo = {
                    scrollY: window.scrollY,
                    scrollX: window.scrollX,
                    viewportHeight: window.innerHeight,
                    viewportWidth: window.innerWidth,
                    contentHeight: document.documentElement.scrollHeight,
                    contentWidth: document.documentElement.scrollWidth
                };
                
                // 가시 영역 아이템들 수집 (모든 패턴 대응)
                const visibleItems = [];
                const commonSelectors = [
                    'article', '.item', '.post', '.card', '.entry', '.content-item',
                    '[data-id]', '[data-item-id]', '[data-index]',
                    '.list-item', '.grid-item', 'li', '.row', '.tile'
                ];
                
                const allElements = [];
                commonSelectors.forEach(selector => {
                    const elements = document.querySelectorAll(selector);
                    elements.forEach(el => allElements.push(el));
                });
                
                // 중복 제거 및 가시성 체크
                const uniqueElements = [...new Set(allElements)];
                uniqueElements.forEach((el, index) => {
                    const rect = el.getBoundingClientRect();
                    const isVisible = rect.top < window.innerHeight && rect.bottom > 0;
                    
                    if (isVisible && visibleItems.length < 20) { // 상위 20개만
                        visibleItems.push({
                            id: el.id || el.dataset.id || el.dataset.itemId || 'item-' + index,
                            selector: el.id ? '#' + el.id : commonSelectors.find(s => el.matches(s)) || '.unknown',
                            offsetTop: el.offsetTop,
                            height: rect.height,
                            content: (el.textContent || '').substr(0, 100),
                            hasImage: el.querySelector('img') !== null,
                            loadPriority: rect.top < window.innerHeight/2 ? 1 : 2
                        });
                    }
                });
                
                // 앵커 아이템 (스크롤 기준점) 찾기
                let anchorItem = null;
                for (const item of visibleItems) {
                    const el = document.querySelector(item.selector);
                    if (el) {
                        const rect = el.getBoundingClientRect();
                        if (rect.top >= 0 && rect.top <= window.innerHeight/3) {
                            anchorItem = {
                                id: item.id,
                                selector: item.selector,
                                offsetFromTop: rect.top,
                                elementHeight: rect.height,
                                isSticky: getComputedStyle(el).position === 'sticky'
                            };
                            break;
                        }
                    }
                }
                
                // 컨테이너별 스크롤 상태 (overflow 있는 요소들)
                const containerScrolls = {};
                const scrollContainers = document.querySelectorAll('[style*="overflow"], .scroll-container, .scrollable');
                scrollContainers.forEach((container, index) => {
                    if (container.scrollTop > 0 || container.scrollLeft > 0) {
                        const selector = container.id ? '#' + container.id : '.scroll-container-' + index;
                        containerScrolls[selector] = container.scrollTop;
                    }
                });
                
                // 가상화/무한 스크롤 상태 감지
                const virtualizationState = {
                    isVirtual: !!(window.virtualScroller || window.VirtualList || window.virtualList),
                    currentSequence: 0,
                    visibleStartIndex: 0,
                    visibleEndIndex: visibleItems.length - 1,
                    totalKnownItems: visibleItems.length,
                    pageInfo: null
                };
                
                // React Virtual, react-window 등 감지
                if (window.virtualScroller) {
                    virtualizationState.currentSequence = window.virtualScroller.getCurrentSequence?.() || 0;
                    virtualizationState.visibleStartIndex = window.virtualScroller.getVisibleStartIndex?.() || 0;
                    virtualizationState.visibleEndIndex = window.virtualScroller.getVisibleEndIndex?.() || 0;
                }
                
                // 무한 스크롤 페이지 정보
                if (window.infiniteScroll || window.__INFINITE_SCROLL_STATE__) {
                    const pageInfo = window.__INFINITE_SCROLL_STATE__ || {};
                    virtualizationState.pageInfo = {
                        currentPage: pageInfo.currentPage || 1,
                        pageSize: pageInfo.pageSize || 20,
                        loadedPages: pageInfo.loadedPages || [1],
                        hasNextPage: pageInfo.hasNextPage !== false
                    };
                }
                
                // React Query 캐시 키 수집
                const cacheKeys = {};
                if (window.__REACT_QUERY_STATE__) {
                    const queryKeys = Object.keys(window.__REACT_QUERY_STATE__);
                    if (queryKeys.length > 0) {
                        cacheKeys.reactQuery = queryKeys[0]; // 첫 번째 활성 쿼리 키
                    }
                }
                
                // 스켈레톤 정보 계산
                const averageItemHeight = visibleItems.length > 0 ? 
                    visibleItems.reduce((sum, item) => sum + item.height, 0) / visibleItems.length : 120;
                
                return {
                    ...scrollInfo,
                    visibleItems,
                    anchorItem,
                    containerScrolls,
                    virtualizationState,
                    cacheKeys,
                    averageItemHeight,
                    timestamp: Date.now()
                };
            } catch (e) {
                console.error('통합 스크롤 캡처 실패:', e);
                return null;
            }
        })()
        """)
    }
    
    // 헬퍼 메서드들
    private func extractAnchorItem(from data: [String: Any]?) -> BFCacheSnapshot.ScrollStateBlock.AnchorItemInfo {
        guard let data = data,
              let anchorData = data["anchorItem"] as? [String: Any],
              let id = anchorData["id"] as? String,
              let selector = anchorData["selector"] as? String else {
            return BFCacheSnapshot.ScrollStateBlock.AnchorItemInfo(
                id: "unknown", selector: "body", offsetFromTop: 0, elementHeight: 100, isSticky: false
            )
        }
        
        return BFCacheSnapshot.ScrollStateBlock.AnchorItemInfo(
            id: id,
            selector: selector,
            offsetFromTop: anchorData["offsetFromTop"] as? CGFloat ?? 0,
            elementHeight: anchorData["elementHeight"] as? CGFloat ?? 100,
            isSticky: anchorData["isSticky"] as? Bool ?? false
        )
    }
    
    private func extractVisibleItems(from data: [String: Any]?) -> [BFCacheSnapshot.ScrollStateBlock.VisibleItemInfo] {
        guard let data = data,
              let itemsData = data["visibleItems"] as? [[String: Any]] else { return [] }
        
        return itemsData.compactMap { itemData in
            guard let id = itemData["id"] as? String,
                  let selector = itemData["selector"] as? String else { return nil }
            
            return BFCacheSnapshot.ScrollStateBlock.VisibleItemInfo(
                id: id,
                selector: selector,
                offsetTop: itemData["offsetTop"] as? CGFloat ?? 0,
                height: itemData["height"] as? CGFloat ?? 100,
                content: itemData["content"] as? String,
                hasImage: itemData["hasImage"] as? Bool ?? false,
                loadPriority: itemData["loadPriority"] as? Int ?? 2
            )
        }
    }
    
    private func extractVirtualizationState(from data: [String: Any]?) -> BFCacheSnapshot.ScrollStateBlock.VirtualizationState {
        guard let data = data,
              let virtData = data["virtualizationState"] as? [String: Any] else {
            return BFCacheSnapshot.ScrollStateBlock.VirtualizationState(
                isVirtual: false, currentSequence: 0, visibleStartIndex: 0, 
                visibleEndIndex: 0, totalKnownItems: 0, pageInfo: nil
            )
        }
        
        var pageInfo: BFCacheSnapshot.ScrollStateBlock.VirtualizationState.PageInfo?
        if let pageData = virtData["pageInfo"] as? [String: Any] {
            pageInfo = BFCacheSnapshot.ScrollStateBlock.VirtualizationState.PageInfo(
                currentPage: pageData["currentPage"] as? Int ?? 1,
                pageSize: pageData["pageSize"] as? Int ?? 20,
                loadedPages: pageData["loadedPages"] as? [Int] ?? [1],
                hasNextPage: pageData["hasNextPage"] as? Bool ?? true
            )
        }
        
        return BFCacheSnapshot.ScrollStateBlock.VirtualizationState(
            isVirtual: virtData["isVirtual"] as? Bool ?? false,
            currentSequence: virtData["currentSequence"] as? Int ?? 0,
            visibleStartIndex: virtData["visibleStartIndex"] as? Int ?? 0,
            visibleEndIndex: virtData["visibleEndIndex"] as? Int ?? 0,
            totalKnownItems: virtData["totalKnownItems"] as? Int ?? 0,
            pageInfo: pageInfo
        )
    }
    
    private func extractContainerScrolls(from data: [String: Any]?) -> [String: CGFloat] {
        guard let data = data,
              let scrolls = data["containerScrolls"] as? [String: Any] else { return [:] }
        
        var result: [String: CGFloat] = [:]
        for (key, value) in scrolls {
            if let scrollValue = value as? CGFloat {
                result[key] = scrollValue
            } else if let scrollValue = value as? Double {
                result[key] = CGFloat(scrollValue)
            }
        }
        return result
    }
    
    private func extractCacheKeys(from data: [String: Any]?) -> [String: String] {
        guard let data = data,
              let cacheKeys = data["cacheKeys"] as? [String: String] else { return [:] }
        return cacheKeys
    }
    
    private func calculateTotalSkeletons(from data: [String: Any]?) -> Int {
        guard let data = data else { return 10 }
        
        let contentHeight = data["contentHeight"] as? CGFloat ?? 1000
        let averageHeight = data["averageItemHeight"] as? CGFloat ?? 120
        let viewportHeight = data["viewportHeight"] as? CGFloat ?? 800
        
        let itemsInViewport = Int(viewportHeight / averageHeight) + 2 // 여유분
        let totalItems = Int(contentHeight / averageHeight)
        
        return min(max(itemsInViewport, 5), max(totalItems, 30)) // 5~30 개 사이
    }
    
    private func createSkeletonPattern(from data: [String: Any]?) -> String {
        // 기본 스켈레톤 HTML 패턴
        return """
        <div style="height: 20px; background: #e2e8f0; margin-bottom: 8px; border-radius: 4px;"></div>
        <div style="height: 16px; background: #f1f5f9; margin-bottom: 12px; border-radius: 4px; width: 80%;"></div>
        """
    }
    
    private func createLoadingSequence(from data: [String: Any]?) -> [BFCacheSnapshot.DataLoadingGuide.LoadingStep] {
        return [
            BFCacheSnapshot.DataLoadingGuide.LoadingStep(
                stepId: "primary_content",
                dataSource: "cache:main_query",
                targetSelectors: [".bfcache-skeleton"],
                delayMs: 50,
                priority: 1,
                fallbackContent: nil
            ),
            BFCacheSnapshot.DataLoadingGuide.LoadingStep(
                stepId: "secondary_content", 
                dataSource: "api:/api/additional",
                targetSelectors: [".bfcache-skeleton:nth-child(n+6)"],
                delayMs: 200,
                priority: 2,
                fallbackContent: "<div>Loading...</div>"
            )
        ]
    }
    
    private func executeJavaScriptSync(webView: WKWebView, script: String) -> [String: Any]? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script) { jsResult, _ in
                result = jsResult as? [String: Any]
                semaphore.signal()
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 2.0)
        return result
    }
    
    private func captureVisualSnapshot(webView: WKWebView, bounds: CGRect) -> UIImage? {
        let semaphore = DispatchSemaphore(value: 0)
        var image: UIImage?
        
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { result, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    image = self.renderWebViewToImage(webView)
                } else {
                    image = result
                }
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃")
            image = renderWebViewToImage(webView)
        }
        
        return image
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 디스크 저장 시스템 (기존 유지)
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // 이미지 저장
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    do {
                        try jpegData.write(to: imagePath)
                        finalSnapshot.webViewSnapshotPath = imagePath.path
                    } catch {
                        self.dbg("❌ 이미지 저장 실패: \(error.localizedDescription)")
                    }
                }
            }
            
            // 상태 데이터 저장
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                do {
                    try stateData.write(to: statePath)
                } catch {
                    self.dbg("❌ 상태 저장 실패: \(error.localizedDescription)")
                }
            }
            
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            self.dbg("💾 통합 상태 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
        }
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
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
    
    // MARK: - 디스크 캐시 로딩 (기존 유지)
    
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
                                let metadataPath = pageDir.appendingPathComponent("metadata.json")
                                if let data = try? Data(contentsOf: metadataPath),
                                   let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) {
                                    
                                    self.setDiskIndex(pageDir.path, for: metadata.pageID)
                                    self.cacheAccessQueue.async(flags: .barrier) {
                                        self._cacheVersion[metadata.pageID] = metadata.version
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
    
    private struct CacheMetadata: Codable {
        let pageID: UUID
        let tabID: UUID
        let version: Int
        let timestamp: Date
        let url: String
        let title: String
    }
    
    // MARK: - 스냅샷 조회 시스템 (기존 유지)
    
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
    
    func hasCache(for pageID: UUID) -> Bool {
        if cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) != nil {
            return true
        }
        
        if cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) != nil {
            return true
        }
        
        return false
    }
    
    private func storeInMemory(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        setMemoryCache(snapshot, for: pageID)
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)]")
    }
    
    // MARK: - 캐시 정리 (기존 유지)
    
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
            do {
                try FileManager.default.removeItem(at: tabDir)
                self.dbg("🗑️ 탭 캐시 완전 삭제: \(tabID.uuidString)")
            } catch {
                self.dbg("⚠️ 탭 캐시 삭제 실패: \(error)")
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
    
    // MARK: - 🎯 제스처 시스템 (기존 유지하되 올인원 복원 호출)
    
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
        
        dbg("올인원 점진적 복원 제스처 설정 완료")
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
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                if let existing = activeTransitions[tabID] {
                    existing.previewContainer?.removeFromSuperview()
                    activeTransitions.removeValue(forKey: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
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
    
    // MARK: - 제스처 전환 로직 (기존 유지)
    
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
        activeTransitions[tabID] = context
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
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
    
    // 🎯 **올인원 점진적 복원 적용 전환 완료**
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
                self?.performAllInOneNavigation(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🎯 **올인원 점진적 복원 네비게이션 수행**
    private func performAllInOneNavigation(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 앞으로가기 완료")
        }
        
        // 🎯 **올인원 점진적 복원 적용**
        tryAllInOneBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - 올인원 복원 \(success ? "성공" : "실패")")
            }
        }
        
        // 안전장치: 최대 1초 후 강제 정리 (올인원 복원은 더 빠름)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (1초 타임아웃)")
            }
        }
    }
    
    // 🎯 **올인원 점진적 BFCache 복원**
    private func tryAllInOneBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // 🎯 **핵심: 올인원 점진적 복원 호출**
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ 올인원 점진적 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ 올인원 점진적 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 기본 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                completion(false)
            }
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
    
    // MARK: - 버튼 네비게이션 (올인원 점진적 복원 적용)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryAllInOneBFCacheRestore(stateModel: stateModel, direction: .back) { _ in }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        tryAllInOneBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in }
    }
    
    // MARK: - 스와이프 제스처 감지 처리
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가: \(url.absoluteString)")
    }
    
    // MARK: - 🌐 JavaScript 스크립트 (올인원 점진적 복원용)
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        // 🎯 올인원 점진적 복원 지원 스크립트
        (function() {
            'use strict';
            
            // iOS 웹뷰 특화: 강제 manual 스크롤 복원
            if (history.scrollRestoration) {
                history.scrollRestoration = 'manual';
            }
            
            // 페이지 보기/숨김 이벤트
            window.addEventListener('pageshow', function(event) {
                if (event.persisted) {
                    console.log('🔄 BFCache 페이지 복원 - 올인원 점진적 시스템 활성');
                    
                    // React Query 캐시 상태 확인
                    if (window.__REACT_QUERY_STATE__) {
                        console.log('💾 React Query 캐시 감지됨');
                    }
                    
                    // 가상화 스크롤러 상태 확인
                    if (window.virtualScroller || window.infiniteScroll) {
                        console.log('🔄 가상화 스크롤 감지됨');
                    }
                    
                    // 올인원 복원 준비 완료 이벤트
                    window.dispatchEvent(new CustomEvent('bfcacheReadyForRestore', {
                        detail: { timestamp: Date.now() }
                    }));
                }
            });
            
            window.addEventListener('pagehide', function(event) {
                if (event.persisted) {
                    console.log('📸 BFCache 페이지 저장 - 통합 상태 수집');
                }
            });
            
            // 스크롤 위치 고정 헬퍼 함수들
            window.lockScrollPosition = function(lockY) {
                window.__BFCACHE_SCROLL_LOCKED__ = true;
                window.__BFCACHE_FINAL_SCROLL_Y__ = lockY;
                
                // 스크롤 이벤트 리스너로 위치 강제 유지
                const scrollLockHandler = () => {
                    if (window.__BFCACHE_SCROLL_LOCKED__ && window.scrollY !== lockY) {
                        window.scrollTo(0, lockY);
                    }
                };
                
                window.addEventListener('scroll', scrollLockHandler, { passive: false });
                
                // 잠금 해제 함수 반환
                return () => {
                    window.__BFCACHE_SCROLL_LOCKED__ = false;
                    window.removeEventListener('scroll', scrollLockHandler);
                    delete window.__BFCACHE_FINAL_SCROLL_Y__;
                };
            };
            
            // React Query 스타일 캐시 데이터 즉시 하이드레이션
            window.hydrateCachedData = function(data, allowScrollChange = false) {
                try {
                    if (!allowScrollChange && window.__BFCACHE_SCROLL_LOCKED__) {
                        // 스크롤 위치 고정 상태에서는 데이터만 교체
                        requestAnimationFrame(() => {
                            // DOM 업데이트 후 스크롤 위치 재확인
                            if (window.__BFCACHE_FINAL_SCROLL_Y__ !== undefined) {
                                window.scrollTo(0, window.__BFCACHE_FINAL_SCROLL_Y__);
                            }
                        });
                    }
                    
                    // 실제 데이터 렌더링 로직은 앱별로 구현 필요
                    console.log('💧 캐시 데이터 하이드레이션:', data.length || 'unknown size');
                    return true;
                } catch (e) {
                    console.error('하이드레이션 실패:', e);
                    return false;
                }
            };
            
            console.log('✅ 올인원 점진적 복원 스크립트 로드 완료');
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[올인원점진복원] \(msg)")
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
        TabPersistenceManager.debugMessages.append("✅ 올인원 점진적 복원 시스템 설치 완료")
    }
    
    static func uninstall(from webView: WKWebView) {
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        TabPersistenceManager.debugMessages.append("🧹 올인원 점진적 복원 시스템 제거 완료")
    }
    
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
}

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출
extension BFCacheTransitionSystem {

    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📸 통합 상태 캡처 시작: \(rec.title)")
    }

    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 상태 캡처 시작: \(rec.title)")
        
        // 이전 페이지들도 메타데이터 확인
        if stateModel.dataModel.currentPageIndex > 0 {
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                if !hasCache(for: previousRecord.id) {
                    // 기본 스냅샷 생성 (통합 데이터는 없지만 메타데이터는 저장)
                    let basicStateBlock = BFCacheSnapshot.ScrollStateBlock(
                        finalScrollY: 0,
                        viewportHeight: 800,
                        totalContentHeight: 1000,
                        anchorItem: BFCacheSnapshot.ScrollStateBlock.AnchorItemInfo(
                            id: "unknown", selector: "body", offsetFromTop: 0, elementHeight: 100, isSticky: false
                        ),
                        visibleItems: [],
                        virtualizationState: BFCacheSnapshot.ScrollStateBlock.VirtualizationState(
                            isVirtual: false, currentSequence: 0, visibleStartIndex: 0,
                            visibleEndIndex: 0, totalKnownItems: 0, pageInfo: nil
                        ),
                        containerScrolls: [:],
                        cacheKeys: [:]
                    )
                    
                    let basicSkeleton = BFCacheSnapshot.SkeletonTemplate(
                        averageItemHeight: 120,
                        itemsPerScreen: 7,
                        totalSkeletonItems: 10,
                        skeletonPattern: "<div>Loading...</div>",
                        placeholderStyles: [:]
                    )
                    
                    let basicGuide = BFCacheSnapshot.DataLoadingGuide(
                        loadingSequence: [],
                        backgroundLoadingEnabled: true,
                        lockScrollDuringLoad: true
                    )
                    
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollPosition: .zero,
                        timestamp: Date(),
                        captureStatus: .failed,
                        version: 1,
                        scrollStateBlock: basicStateBlock,
                        skeletonTemplate: basicSkeleton,
                        dataLoadingGuide: basicGuide
                    )
                    
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
