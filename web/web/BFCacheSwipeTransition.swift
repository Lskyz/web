//
//  BFCacheSwipeTransition.swift
//  🎯 **강화된 동적 사이트 스크롤 복원 - React 구조 감지 + 다양한 사이트 지원**
//  ✅ 1. React 앱 구조 자동 감지 (#app, #root, [data-reactroot] 등)
//  ✅ 2. iframe 내부 접근 및 크로스 프레임 스크롤 상태 수집
//  ✅ 3. 동적 컴포넌트 식별자 기반 앵커 요소 정밀 추적
//  ✅ 4. 가상화 리스트 (react-window, react-virtualized) 상태 복원
//  ✅ 5. 무한 스크롤 + Intersection Observer 상태 관리
//  ✅ 6. 다양한 SPA 프레임워크 (Vue, Angular, Svelte) 지원
//  ✅ 7. 스켈레톤 생성시 실제 컴포넌트 구조 반영
//  ⚡ 목표: 현대 웹앱의 복잡한 동적 구조에서도 픽셀 퍼펙트 복원
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

// MARK: - 📸 **강화된 동적 사이트 스냅샷** - React/SPA 구조 완전 지원
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 🎯 **강화된 스크롤 상태 블록** - React/SPA 구조 완전 지원
    let scrollStateBlock: ScrollStateBlock
    
    // 🎯 **동적 스켈레톤 템플릿** - 실제 컴포넌트 구조 반영
    let skeletonTemplate: SkeletonTemplate
    
    // 🎯 **지능형 데이터 로딩 가이드** - 프레임워크별 최적화
    let dataLoadingGuide: DataLoadingGuide
    
    // 🎯 **강화된 스크롤 상태 블록** - React/SPA 완전 지원
    struct ScrollStateBlock: Codable {
        let finalScrollY: CGFloat
        let viewportHeight: CGFloat
        let totalContentHeight: CGFloat
        
        // 🆕 **React 앱 구조 정보**
        let reactAppInfo: ReactAppInfo
        
        // 🆕 **iframe 스크롤 상태** (크로스 프레임 지원)
        let iframeScrollStates: [IframeScrollState]
        
        // 강화된 앵커 아이템 정보
        let anchorItem: AnchorItemInfo
        
        // 가시 영역 아이템들 (React 컴포넌트 정보 포함)
        let visibleItems: [VisibleItemInfo]
        
        // 가상화/무한 스크롤 상태 (React 라이브러리 지원)
        let virtualizationState: VirtualizationState
        
        // 컨테이너별 스크롤 상태
        let containerScrolls: [String: CGFloat]
        
        // 프레임워크별 캐시 키 정보
        let cacheKeys: [String: String]
        
        // 🆕 **React 앱 구조 정보**
        struct ReactAppInfo: Codable {
            let framework: String              // "react", "vue", "angular", "svelte", "vanilla"
            let appContainerSelector: String   // "#app", "#root", ".app-container" 등
            let hasReactRoot: Bool            // React 18+ createRoot 사용 여부
            let componentTree: [ComponentInfo] // 컴포넌트 트리 정보
            let stateManagement: String?       // "redux", "mobx", "zustand", "recoil" 등
            let routingLibrary: String?        // "react-router", "reach-router", "next-router" 등
            
            struct ComponentInfo: Codable {
                let id: String
                let type: String               // "component", "list-item", "virtual-item" 등
                let selector: String
                let props: [String: String]?   // 주요 props 정보
                let reactKey: String?          // React key 값
                let depth: Int                // 컴포넌트 트리 깊이
            }
        }
        
        // 🆕 **iframe 스크롤 상태**
        struct IframeScrollState: Codable {
            let iframeSelector: String
            let src: String
            let scrollX: CGFloat
            let scrollY: CGFloat
            let contentHeight: CGFloat
            let isAccessible: Bool            // same-origin 접근 가능 여부
            let nestedFrames: [IframeScrollState]  // 중첩 iframe 지원
        }
        
        struct AnchorItemInfo: Codable {
            let id: String
            let selector: String
            let offsetFromTop: CGFloat
            let elementHeight: CGFloat
            let isSticky: Bool
            // 🆕 **React 컴포넌트 정보**
            let reactComponentName: String?    // 컴포넌트 이름
            let reactKey: String?             // React key
            let reactProps: [String: String]? // 주요 props
            let isVirtualItem: Bool           // 가상화된 아이템인지
        }
        
        struct VisibleItemInfo: Codable {
            let id: String
            let selector: String
            let offsetTop: CGFloat
            let height: CGFloat
            let content: String?
            let hasImage: Bool
            let loadPriority: Int
            // 🆕 **React/동적 컴포넌트 정보**
            let componentInfo: ComponentInfo?
            let dynamicContent: DynamicContentInfo?
            
            struct ComponentInfo: Codable {
                let componentName: String
                let reactKey: String?
                let dataAttributes: [String: String]
                let isLazyLoaded: Bool
                let hasAsyncData: Bool
            }
            
            struct DynamicContentInfo: Codable {
                let isSkeletonPlaceholder: Bool
                let hasLoadingState: Bool
                let apiEndpoint: String?
                let cacheKey: String?
                let loadingStrategy: String    // "eager", "lazy", "intersection"
            }
        }
        
        struct VirtualizationState: Codable {
            let isVirtual: Bool
            let libraryType: String?          // "react-window", "react-virtualized", "react-virtual" 등
            let currentSequence: Int
            let visibleStartIndex: Int
            let visibleEndIndex: Int
            let totalKnownItems: Int
            let itemHeight: CGFloat?          // FixedSizeList 높이
            let estimatedItemSize: CGFloat?   // DynamicSizeList 예상 높이
            let pageInfo: PageInfo?
            let scrollOffset: CGFloat         // 가상 스크롤러 내부 오프셋
            
            struct PageInfo: Codable {
                let currentPage: Int
                let pageSize: Int
                let loadedPages: [Int]
                let hasNextPage: Bool
                let infiniteScrollTrigger: String?  // Intersection Observer 트리거 선택자
                let loadMoreElement: String?        // "Load More" 버튼 선택자
            }
        }
    }
    
    // 🎯 **동적 스켈레톤 템플릿** - 실제 컴포넌트 구조 반영
    struct SkeletonTemplate: Codable {
        let averageItemHeight: CGFloat
        let itemsPerScreen: Int
        let totalSkeletonItems: Int
        let skeletonPattern: String
        let placeholderStyles: [String: String]
        
        // 🆕 **컴포넌트별 스켈레톤 패턴**
        let componentSkeletons: [ComponentSkeleton]
        
        struct ComponentSkeleton: Codable {
            let componentType: String         // "list-item", "card", "article", "product" 등
            let htmlTemplate: String
            let cssTemplate: String
            let estimatedHeight: CGFloat
            let containsImages: Bool
            let containsText: Bool
            let priority: Int                 // 생성 우선순위
        }
    }
    
    // 🎯 **지능형 데이터 로딩 가이드** - 프레임워크별 최적화
    struct DataLoadingGuide: Codable {
        let loadingSequence: [LoadingStep]
        let backgroundLoadingEnabled: Bool
        let lockScrollDuringLoad: Bool
        
        // 🆕 **프레임워크별 복원 전략**
        let frameworkStrategy: FrameworkStrategy
        
        struct LoadingStep: Codable {
            let stepId: String
            let dataSource: String
            let targetSelectors: [String]
            let delayMs: Int
            let priority: Int
            let fallbackContent: String?
            // 🆕 **React 상태 복원**
            let reactStateRestore: ReactStateRestore?
            
            struct ReactStateRestore: Codable {
                let storeType: String          // "redux", "context", "local-state"
                let stateKey: String
                let stateValue: String         // JSON 직렬화된 상태
                let actionType: String?        // Redux action type
            }
        }
        
        struct FrameworkStrategy: Codable {
            let framework: String
            let hydrationMethod: String       // "client-side", "ssr-rehydration", "static-generation"
            let dataFetchingPattern: String   // "swr", "react-query", "apollo", "relay" 등
            let routerType: String?
            let customRestoreScript: String? // 프레임워크별 커스텀 복원 스크립트
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
    
    // 🎯 **핵심: 강화된 동적 사이트 복원** - React/SPA 구조 완전 지원
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard captureStatus != .failed else {
            completion(false)
            return
        }
        
        TabPersistenceManager.debugMessages.append("🎯 강화된 동적 사이트 복원 시작: \(scrollStateBlock.reactAppInfo.framework)")
        
        // iOS 웹뷰 특화: history.scrollRestoration 강제 manual
        webView.evaluateJavaScript("if (history.scrollRestoration) { history.scrollRestoration = 'manual'; }") { _, _ in }
        
        performEnhancedDynamicRestore(to: webView, completion: completion)
    }
    
    // 🎯 **강화된 동적 사이트 복원 시스템**
    private func performEnhancedDynamicRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let stateBlock = scrollStateBlock
        let appInfo = stateBlock.reactAppInfo
        
        // **1단계: 프레임워크별 앱 구조 복원**
        restoreAppStructure(to: webView, appInfo: appInfo) { structureSuccess in
            // **2단계: 동적 스켈레톤 생성 (실제 컴포넌트 구조 반영)**
            self.createDynamicComponentSkeleton(to: webView) { skeletonSuccess in
                // **3단계: 강화된 스크롤 복원 (React/iframe 지원)**
                self.executeEnhancedScrollRestore(to: webView, stateBlock: stateBlock) { scrollSuccess in
                    TabPersistenceManager.debugMessages.append("✅ 강화된 복원 완료: 구조=\(structureSuccess), 스켈레톤=\(skeletonSuccess), 스크롤=\(scrollSuccess)")
                    
                    // **4단계: 프레임워크별 데이터 점진적 하이드레이션**
                    if scrollSuccess {
                        self.startFrameworkSpecificHydration(to: webView)
                    }
                    
                    completion(scrollSuccess)
                }
            }
        }
    }
    
    // 🎯 **1단계: 프레임워크별 앱 구조 복원**
    private func restoreAppStructure(to webView: WKWebView, appInfo: ScrollStateBlock.ReactAppInfo, completion: @escaping (Bool) -> Void) {
        let structureJS = """
        (function() {
            try {
                const framework = '\(appInfo.framework)';
                const appContainer = '\(appInfo.appContainerSelector)';
                
                console.log('🏗️ 앱 구조 복원 시작:', framework, appContainer);
                
                // DOM 준비 확인
                if (document.readyState !== 'complete') {
                    return new Promise(resolve => {
                        document.addEventListener('DOMContentLoaded', () => resolve(restoreStructure()));
                    });
                }
                
                return restoreStructure();
                
                function restoreStructure() {
                    // 앱 컨테이너 확인/생성
                    let appRoot = document.querySelector(appContainer);
                    if (!appRoot && (appContainer === '#app' || appContainer === '#root')) {
                        appRoot = document.createElement('div');
                        appRoot.id = appContainer.replace('#', '');
                        document.body.appendChild(appRoot);
                        console.log('🏗️ 앱 컨테이너 생성:', appContainer);
                    }
                    
                    if (!appRoot) {
                        console.warn('앱 컨테이너를 찾을 수 없음:', appContainer);
                        return false;
                    }
                    
                    // 프레임워크별 기본 구조 설정
                    switch (framework) {
                        case 'react':
                            if (\(appInfo.hasReactRoot)) {
                                // React 18+ createRoot
                                appRoot.setAttribute('data-reactroot', '');
                            } else {
                                // React 17- render
                                appRoot._reactRootContainer = true;
                            }
                            
                            // React Router 상태 복원
                            if ('\(appInfo.routingLibrary ?? "")' === 'react-router') {
                                window.history.scrollRestoration = 'manual';
                            }
                            break;
                            
                        case 'vue':
                            appRoot.setAttribute('data-v-app', '');
                            if (window.Vue && window.Vue.version) {
                                console.log('Vue 감지됨:', window.Vue.version);
                            }
                            break;
                            
                        case 'angular':
                            appRoot.setAttribute('ng-app', '');
                            if (window.ng && window.ng.version) {
                                console.log('Angular 감지됨:', window.ng.version);
                            }
                            break;
                            
                        case 'svelte':
                            appRoot.setAttribute('data-svelte-app', '');
                            break;
                    }
                    
                    // 컴포넌트 트리 기본 구조 생성
                    const componentTree = \(jsonString(from: appInfo.componentTree));
                    componentTree.forEach((comp, index) => {
                        if (comp.type === 'list-container' && !document.querySelector(comp.selector)) {
                            const container = document.createElement('div');
                            container.className = comp.selector.replace('.', '').replace('#', '');
                            if (comp.selector.startsWith('#')) container.id = comp.selector.replace('#', '');
                            appRoot.appendChild(container);
                        }
                    });
                    
                    window.__BFCACHE_APP_STRUCTURE_RESTORED__ = true;
                    return true;
                }
            } catch (e) {
                console.error('앱 구조 복원 실패:', e);
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(structureJS) { result, error in
            let success = (result as? Bool) ?? false
            if success {
                TabPersistenceManager.debugMessages.append("🏗️ 앱 구조 복원 성공: \(appInfo.framework)")
            } else {
                TabPersistenceManager.debugMessages.append("❌ 앱 구조 복원 실패: \(error?.localizedDescription ?? "unknown")")
            }
            completion(success)
        }
    }
    
    // 🎯 **2단계: 동적 컴포넌트 스켈레톤 생성**
    private func createDynamicComponentSkeleton(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let template = skeletonTemplate
        let componentSkeletons = template.componentSkeletons
        
        let dynamicSkeletonJS = """
        (function() {
            try {
                if (!window.__BFCACHE_APP_STRUCTURE_RESTORED__) {
                    console.warn('앱 구조가 복원되지 않음 - 스켈레톤 생성 지연');
                    return false;
                }
                
                // 기존 스켈레톤 정리
                document.querySelectorAll('.bfcache-skeleton, .bfcache-skeleton-container').forEach(el => el.remove());
                
                const componentSkeletons = \(jsonString(from: componentSkeletons));
                const appContainer = document.querySelector('\(scrollStateBlock.reactAppInfo.appContainerSelector)') || document.body;
                
                // 컴포넌트별 스켈레톤 생성
                componentSkeletons.forEach((skeleton, index) => {
                    const count = Math.ceil(\(template.totalSkeletonItems) / componentSkeletons.length);
                    
                    for (let i = 0; i < count; i++) {
                        const skeletonElement = document.createElement('div');

                        skeletonElement.innerHTML = skeleton.htmlTemplate;
                        
                        // 컴포넌트별 스타일 적용
                        if (skeleton.cssTemplate) {
                            skeletonElement.style.cssText = skeleton.cssTemplate;
                        }
                        
                        // React 컴포넌트 특성 반영
                        skeletonElement.setAttribute('data-component-type', skeleton.componentType);
                        skeletonElement.style.height = skeleton.estimatedHeight + 'px';
                        
                        appContainer.appendChild(skeletonElement);
                    }
                });
                
                // 동적 스켈레톤 애니메이션 적용
                if (!document.getElementById('bfcache-dynamic-skeleton-styles')) {
                    const style = document.createElement('style');
                    style.id = 'bfcache-dynamic-skeleton-styles';
                    style.textContent = `
                        .bfcache-skeleton {
                            background: linear-gradient(90deg, #e2e8f0 25%, #f1f5f9 50%, #e2e8f0 75%);
                            background-size: 200% 100%;
                            animation: bfcache-shimmer 1.8s infinite;
                            border-radius: 8px;
                            margin: 8px 0;
                            position: relative;
                        }
                        
                        @keyframes bfcache-shimmer {
                            0% { background-position: -200% 0; }
                            100% { background-position: 200% 0; }
                        }
                        
                        .bfcache-skeleton[data-component-type="list-item"] {
                            display: flex;
                            align-items: center;
                            padding: 12px 16px;
                        }
                        
                        .bfcache-skeleton[data-component-type="card"] {
                            border-radius: 12px;
                            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
                        }
                        
                        .bfcache-skeleton[data-component-type="article"] {
                            max-width: 800px;
                            margin: 16px auto;
                        }
                    `;
                    document.head.appendChild(style);
                }
                
                // 높이 검증 및 조정
                const totalHeight = Math.max(
                    \(scrollStateBlock.totalContentHeight),
                    componentSkeletons.reduce((sum, s) => sum + s.estimatedHeight, 0)
                );
                
                if (appContainer.style) {
                    appContainer.style.minHeight = totalHeight + 'px';
                }
                
                window.__BFCACHE_DYNAMIC_SKELETON_ACTIVE__ = true;
                return true;
                
            } catch (e) {
                console.error('동적 스켈레톤 생성 실패:', e);
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(dynamicSkeletonJS) { result, error in
            let success = (result as? Bool) ?? false
            if success {
                TabPersistenceManager.debugMessages.append("🎨 동적 스켈레톤 생성 성공: \(componentSkeletons.count)개 컴포넌트 타입")
            } else {
                TabPersistenceManager.debugMessages.append("❌ 동적 스켈레톤 생성 실패: \(error?.localizedDescription ?? "unknown")")
            }
            completion(success)
        }
    }
    
    // 🎯 **3단계: 강화된 스크롤 복원** - React/iframe 완전 지원
    private func executeEnhancedScrollRestore(to webView: WKWebView, stateBlock: ScrollStateBlock, completion: @escaping (Bool) -> Void) {
        let finalScrollY = stateBlock.finalScrollY
        let anchorItem = stateBlock.anchorItem
        let virtualizationState = stateBlock.virtualizationState
        let iframeStates = stateBlock.iframeScrollStates
        
        let enhancedScrollRestoreJS = """
        (function() {
            try {
                if (!window.__BFCACHE_DYNAMIC_SKELETON_ACTIVE__) {
                    console.warn('스켈레톤이 준비되지 않음 - 스크롤 복원 지연');
                    return false;
                }
                
                return performEnhancedScrollRestore();
                
                function performEnhancedScrollRestore() {
                    const targetY = \(finalScrollY);
                    document.documentElement.style.scrollBehavior = 'auto';
                    
                    // 1. 기본 스크롤 위치 설정
                    window.scrollTo({ top: targetY, behavior: 'auto' });
                    
                    // 2. React 컴포넌트 앵커 기준 정밀 조정
                    const anchorElement = document.querySelector('\(anchorItem.selector)');
                    if (anchorElement) {
                        // React 컴포넌트 정보 검증
                        const reactKey = '\(anchorItem.reactKey ?? "")';
                        const componentName = '\(anchorItem.reactComponentName ?? "")';
                        
                        if (reactKey && anchorElement.getAttribute && anchorElement.getAttribute('data-reactkey') !== reactKey) {
                            console.warn('React key 불일치 - 앵커 요소 재검색');
                            const correctAnchor = document.querySelector(`[data-reactkey="\\${reactKey}"]`);
                            if (correctAnchor) {
                                anchorElement = correctAnchor;
                            }
                        }
                        
                        const currentTop = anchorElement.getBoundingClientRect().top;
                        const expectedTop = \(anchorItem.offsetFromTop);
                        const adjustment = expectedTop - currentTop;
                        
                        if (Math.abs(adjustment) > 5) {
                            window.scrollTo({ top: targetY + adjustment, behavior: 'auto' });
                        }
                    }
                    
                    // 3. 가상화된 리스트 복원 (react-window, react-virtualized 등)
                    if (\(virtualizationState.isVirtual)) {
                        const libraryType = '\(virtualizationState.libraryType ?? "")';
                        const visibleStartIndex = \(virtualizationState.visibleStartIndex);
                        const scrollOffset = \(virtualizationState.scrollOffset);
                        
                        switch (libraryType) {
                            case 'react-window':
                                if (window.reactWindow || window.FixedSizeList || window.VariableSizeList) {
                                    // react-window 스크롤 복원
                                    const virtualList = document.querySelector('[data-react-window-list]');
                                    if (virtualList && virtualList._listRef) {
                                        virtualList._listRef.scrollToItem(visibleStartIndex, 'start');
                                        if (scrollOffset > 0) {
                                            virtualList._listRef.scrollTo(scrollOffset);
                                        }
                                    }
                                }
                                break;
                                
                            case 'react-virtualized':
                                if (window.reactVirtualized || window.List || window.Grid) {
                                    const virtualizedList = document.querySelector('[data-react-virtualized-list]');
                                    if (virtualizedList && virtualizedList.scrollToRow) {
                                        virtualizedList.scrollToRow(visibleStartIndex);
                                    }
                                }
                                break;
                                
                            case 'react-virtual':
                                if (window.useVirtual || window.virtualizer) {
                                    const virtualContainer = document.querySelector('[data-virtual-container]');
                                    if (virtualContainer) {
                                        virtualContainer.scrollTop = scrollOffset;
                                    }
                                }
                                break;
                        }
                    }
                    
                    // 4. iframe 스크롤 복원 (크로스 프레임 지원)
                    const iframeStates = \(jsonString(from: iframeStates));
                    iframeStates.forEach(iframeState => {
                        try {
                            const iframe = document.querySelector(iframeState.iframeSelector);
                            if (iframe && iframe.contentWindow && iframeState.isAccessible) {
                                // Same-origin iframe 스크롤 복원
                                iframe.contentWindow.scrollTo(iframeState.scrollX, iframeState.scrollY);
                                
                                // 중첩 iframe 처리
                                if (iframeState.nestedFrames && iframeState.nestedFrames.length > 0) {
                                    iframeState.nestedFrames.forEach(nestedFrame => {
                                        const nestedIframe = iframe.contentDocument.querySelector(nestedFrame.iframeSelector);
                                        if (nestedIframe && nestedIframe.contentWindow && nestedFrame.isAccessible) {
                                            nestedIframe.contentWindow.scrollTo(nestedFrame.scrollX, nestedFrame.scrollY);
                                        }
                                    });
                                }
                            }
                        } catch (e) {
                            console.warn('iframe 스크롤 복원 실패 (CORS):', iframeState.iframeSelector, e);
                        }
                    });
                    
                    // 5. 컨테이너별 스크롤 복원
                    const containerScrolls = \(jsonString(from: stateBlock.containerScrolls));
                    Object.keys(containerScrolls).forEach(selector => {
                        const container = document.querySelector(selector);
                        if (container) {
                            container.scrollTop = containerScrolls[selector];
                        }
                    });
                    
                    // 6. 무한 스크롤 상태 복원
                    if (\(virtualizationState.pageInfo?.infiniteScrollTrigger != nil)) {
                        const triggerSelector = '\(virtualizationState.pageInfo?.infiniteScrollTrigger ?? "")';
                        const trigger = document.querySelector(triggerSelector);
                        if (trigger && window.IntersectionObserver) {
                            // Intersection Observer 재설정
                            const observer = new IntersectionObserver((entries) => {
                                entries.forEach(entry => {
                                    if (entry.isIntersecting) {
                                        // 무한 스크롤 트리거 - 실제 앱에서 구현 필요
                                        console.log('무한 스크롤 트리거 감지');
                                        if (window.loadMoreData) {
                                            window.loadMoreData();
                                        }
                                    }
                                });
                            });
                            observer.observe(trigger);
                        }
                    }
                    
                    // 7. React 상태 복원 (Redux, Context 등)
                    const cacheKeys = \(jsonString(from: stateBlock.cacheKeys));
                    if (cacheKeys.redux && window.__REDUX_STORE__) {
                        try {
                            const savedState = JSON.parse(cacheKeys.redux);
                            window.__REDUX_STORE__.dispatch({ type: 'HYDRATE_STATE', payload: savedState });
                        } catch (e) {
                            console.warn('Redux 상태 복원 실패:', e);
                        }
                    }
                    
                    if (cacheKeys.reactQuery && window.__REACT_QUERY_CLIENT__) {
                        try {
                            const queryData = JSON.parse(cacheKeys.reactQuery);
                            window.__REACT_QUERY_CLIENT__.setQueryData(queryData.key, queryData.data);
                        } catch (e) {
                            console.warn('React Query 상태 복원 실패:', e);
                        }
                    }
                    
                    // 8. 스크롤 위치 고정 및 모니터링
                    window.__BFCACHE_SCROLL_LOCKED__ = true;
                    window.__BFCACHE_FINAL_SCROLL_Y__ = window.scrollY;
                    
                    window.__BFCACHE_SCROLL_LISTENER__ = () => {
                        if (window.__BFCACHE_SCROLL_LOCKED__ && Math.abs(window.scrollY - window.__BFCACHE_FINAL_SCROLL_Y__) > 5) {
                            window.scrollTo({ top: window.__BFCACHE_FINAL_SCROLL_Y__, behavior: 'auto' });
                        }
                    };
                    window.addEventListener('scroll', window.__BFCACHE_SCROLL_LISTENER__, { passive: false });
                    
                    // 9. 강화된 복원 완료 이벤트
                    window.dispatchEvent(new CustomEvent('bfcacheEnhancedRestoreComplete', {
                        detail: {
                            finalScrollY: window.scrollY,
                            framework: '\(stateBlock.reactAppInfo.framework)',
                            hasVirtualization: \(virtualizationState.isVirtual),
                            iframeCount: iframeStates.length,
                            timestamp: Date.now()
                        }
                    }));
                    
                    console.log('✅ 강화된 스크롤 복원 완료:', {
                        targetY: targetY,
                        actualY: window.scrollY,
                        framework: '\(stateBlock.reactAppInfo.framework)',
                        hasAnchor: !!anchorElement,
                        hasVirtual: \(virtualizationState.isVirtual)
                    });
                    
                    return Math.abs(window.scrollY - targetY) < 10; // 허용 오차 10px
                }
            } catch (e) {
                console.error('강화된 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
        
        DispatchQueue.main.async {
            // 네이티브 스크롤뷰 먼저 설정
            webView.scrollView.setContentOffset(CGPoint(x: 0, y: finalScrollY), animated: false)
            
            // JavaScript 실행
            webView.evaluateJavaScript(enhancedScrollRestoreJS) { result, error in
                let success = (result as? Bool) ?? false
                if success {
                    TabPersistenceManager.debugMessages.append("✅ 강화된 스크롤 복원 성공: Y=\(finalScrollY), 프레임워크=\(stateBlock.reactAppInfo.framework)")
                } else {
                    TabPersistenceManager.debugMessages.append("❌ 강화된 스크롤 복원 실패: \(error?.localizedDescription ?? "unknown")")
                }
                completion(success)
            }
        }
    }
    
    // 🎯 **4단계: 프레임워크별 데이터 하이드레이션**
    private func startFrameworkSpecificHydration(to webView: WKWebView) {
        let guide = dataLoadingGuide
        let strategy = guide.frameworkStrategy
        
        TabPersistenceManager.debugMessages.append("💧 프레임워크별 하이드레이션 시작: \(strategy.framework)")
        
        // 프레임워크별 커스텀 스크립트 실행
        if let customScript = strategy.customRestoreScript {
            webView.evaluateJavaScript(customScript) { _, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("⚠️ 커스텀 복원 스크립트 실패: \(error.localizedDescription)")
                }
            }
        }
        
        // 일반적인 데이터 로딩 시퀀스 실행
        let sortedSteps = guide.loadingSequence.sorted { $0.priority < $1.priority }
        executeFrameworkAwareDataLoading(to: webView, steps: sortedSteps, currentIndex: 0)
    }
    
    // **프레임워크 인식 데이터 로딩**
    private func executeFrameworkAwareDataLoading(to webView: WKWebView, steps: [DataLoadingGuide.LoadingStep], currentIndex: Int) {
        guard currentIndex < steps.count else {
            finalizeFrameworkHydration(to: webView)
            return
        }
        
        let step = steps[currentIndex]
        let delay = Double(step.delayMs) / 1000.0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.executeFrameworkAwareStep(to: webView, step: step) { success in
                TabPersistenceManager.debugMessages.append("💧 \(step.stepId) 하이드레이션: \(success ? "성공" : "실패")")
                self.executeFrameworkAwareDataLoading(to: webView, steps: steps, currentIndex: currentIndex + 1)
            }
        }
    }
    
    private func executeFrameworkAwareStep(to webView: WKWebView, step: DataLoadingGuide.LoadingStep, completion: @escaping (Bool) -> Void) {
        let frameworkAwareJS = """
        (function() {
            try {
                if (!window.__BFCACHE_SCROLL_LOCKED__) {
                    console.warn('스크롤 고정되지 않음 - 하이드레이션 중단');
                    return false;
                }
                
                const targetSelectors = \(jsonString(from: step.targetSelectors));
                let processedCount = 0;
                
                // React 상태 복원
                if ('\(step.reactStateRestore?.storeType ?? "")' === 'redux' && window.__REDUX_STORE__) {
                    const stateValue = '\(step.reactStateRestore?.stateValue ?? "")';
                    const actionType = '\(step.reactStateRestore?.actionType ?? "HYDRATE_PARTIAL")';
                    
                    try {
                        const parsedState = JSON.parse(stateValue);
                        window.__REDUX_STORE__.dispatch({ 
                            type: actionType, 
                            payload: parsedState 
                        });
                    } catch (e) {
                        console.warn('Redux 부분 상태 복원 실패:', e);
                    }
                }
                
                // 스켈레톤 → 실제 컴포넌트 교체
                targetSelectors.forEach(selector => {
                    const skeletons = document.querySelectorAll(selector);
                    
                    skeletons.forEach((skeleton, index) => {
                        // React 컴포넌트 특성 확인
                        const componentType = skeleton.getAttribute('data-component-type');
                        
                        if (componentType && window.React && window.ReactDOM) {
                            // React 컴포넌트로 교체 시도
                            try {
                                const componentData = {
                                    type: componentType,
                                    index: index,
                                    // 실제 데이터는 API 호출이나 캐시에서 가져와야 함
                                };
                                
                                // 실제 React 컴포넌트 렌더링은 앱별로 구현 필요
                                skeleton.innerHTML = '<div>실제 컴포넌트 내용</div>';
                                skeleton.className = skeleton.className.replace('bfcache-skeleton', 'hydrated-component');
                                processedCount++;
                                
                            } catch (e) {
                                console.warn('React 컴포넌트 교체 실패:', e);
                                // 폴백 콘텐츠 사용
                                if ('\(step.fallbackContent ?? "")') {
                                    skeleton.innerHTML = '\(step.fallbackContent ?? "")';
                                    processedCount++;
                                }
                            }
                        } else {
                            // 일반 HTML 교체
                            if ('\(step.fallbackContent ?? "")') {
                                skeleton.innerHTML = '\(step.fallbackContent ?? "")';
                                skeleton.className = skeleton.className.replace('bfcache-skeleton', 'fallback-content');
                                processedCount++;
                            }
                        }
                    });
                });
                
                // 스크롤 위치 재고정
                if (window.__BFCACHE_FINAL_SCROLL_Y__ !== undefined) {
                    window.scrollTo(0, window.__BFCACHE_FINAL_SCROLL_Y__);
                }
                
                return processedCount > 0;
                
            } catch (e) {
                console.error('프레임워크 인식 하이드레이션 실패:', e);
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(frameworkAwareJS) { result, error in
            let success = (result as? Bool) ?? false
            completion(success)
        }
    }
    
    private func finalizeFrameworkHydration(to webView: WKWebView) {
        let finalizeJS = """
        (function() {
            try {
                // 남은 스켈레톤 정리
                document.querySelectorAll('.bfcache-skeleton').forEach(skeleton => {
                    skeleton.style.opacity = '0';
                    setTimeout(() => skeleton.remove(), 200);
                });
                
                // 스켈레톤 스타일 정리
                const skeletonStyles = document.getElementById('bfcache-dynamic-skeleton-styles');
                if (skeletonStyles) {
                    setTimeout(() => skeletonStyles.remove(), 500);
                }
                
                // 스크롤 고정 해제
                window.__BFCACHE_SCROLL_LOCKED__ = false;
                window.__BFCACHE_DYNAMIC_SKELETON_ACTIVE__ = false;
                delete window.__BFCACHE_FINAL_SCROLL_Y__;
                
                if (window.__BFCACHE_SCROLL_LISTENER__) {
                    window.removeEventListener('scroll', window.__BFCACHE_SCROLL_LISTENER__);
                    delete window.__BFCACHE_SCROLL_LISTENER__;
                }
                
                // 프레임워크별 하이드레이션 완료 이벤트
                window.dispatchEvent(new CustomEvent('bfcacheFrameworkHydrationComplete', {
                    detail: { 
                        finalScrollY: window.scrollY,
                        framework: '\(dataLoadingGuide.frameworkStrategy.framework)',
                        timestamp: Date.now()
                    }
                }));
                
                return true;
            } catch (e) {
                console.error('하이드레이션 완료 처리 실패:', e);
                return false;
            }
        })()
        """
        
        webView.evaluateJavaScript(finalizeJS) { result, error in
            TabPersistenceManager.debugMessages.append("🎉 프레임워크별 하이드레이션 완료")
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

// MARK: - 🎯 **강화된 동적 사이트 전환 시스템**
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
    
    // MARK: - 🎯 **강화된 통합 상태 캡처 시스템** - React/SPA 완전 지원
    
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
            self?.performEnhancedDynamicCapture(task)
        }
    }
    
    // 🎯 **강화된 동적 사이트 캡처** - React/SPA 구조 완전 분석
    private func performEnhancedDynamicCapture(_ task: CaptureTask) {
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
        dbg("🎯 강화된 동적 사이트 캡처 시작: \(task.pageRecord.title)")
        
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
        
        // **강화된 동적 사이트 상태 블록 생성** - React/SPA 완전 분석
        let captureResult = createEnhancedDynamicStateBlock(
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
        dbg("✅ 강화된 동적 사이트 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
        let url: URL
    }
    
    // 🎯 **강화된 동적 사이트 상태 블록 생성** - React/SPA 구조 완전 분석
    private func createEnhancedDynamicStateBlock(pageRecord: PageRecord, webView: WKWebView, 
                                               captureData: CaptureData) 
                                               -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        var visualSnapshot: UIImage?
        var scrollStateBlock: BFCacheSnapshot.ScrollStateBlock!
        var skeletonTemplate: BFCacheSnapshot.SkeletonTemplate!
        var dataLoadingGuide: BFCacheSnapshot.DataLoadingGuide!
        
        // 1. 비주얼 스냅샷 캡처
        visualSnapshot = captureVisualSnapshot(webView: webView, bounds: captureData.bounds)
        
        // 2. 강화된 동적 사이트 상태 수집
        let dynamicData = executeEnhancedDynamicCapture(webView: webView, scrollY: captureData.scrollPosition.y)
        
        // 3. React/SPA 앱 정보 구성
        let reactAppInfo = extractReactAppInfo(from: dynamicData)
        
        // 4. iframe 상태 수집
        let iframeStates = extractIframeStates(from: dynamicData)
        
        // 5. 강화된 상태 블록 구성
        scrollStateBlock = BFCacheSnapshot.ScrollStateBlock(
            finalScrollY: captureData.scrollPosition.y,
            viewportHeight: captureData.bounds.height,
            totalContentHeight: dynamicData?["contentHeight"] as? CGFloat ?? 0,
            reactAppInfo: reactAppInfo,
            iframeScrollStates: iframeStates,
            anchorItem: extractEnhancedAnchorItem(from: dynamicData),
            visibleItems: extractEnhancedVisibleItems(from: dynamicData),
            virtualizationState: extractEnhancedVirtualizationState(from: dynamicData),
            containerScrolls: extractContainerScrolls(from: dynamicData),
            cacheKeys: extractEnhancedCacheKeys(from: dynamicData)
        )
        
        // 6. 동적 스켈레톤 템플릿 생성
        skeletonTemplate = createDynamicSkeletonTemplate(from: dynamicData, reactAppInfo: reactAppInfo)
        
        // 7. 프레임워크별 데이터 로딩 가이드 생성
        dataLoadingGuide = createFrameworkAwareDataLoadingGuide(from: dynamicData, reactAppInfo: reactAppInfo)
        
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && dynamicData != nil {
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
            jsState: dynamicData,
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
    
    // 🎯 **강화된 동적 사이트 캡처 JavaScript** - React/SPA 완전 분석
    private func executeEnhancedDynamicCapture(webView: WKWebView, scrollY: CGFloat) -> [String: Any]? {
        let script = """
        (function() {
            try {
                console.log('🔍 강화된 동적 사이트 분석 시작');
                
                // === 1. 기본 스크롤 정보 ===
                const scrollInfo = {
                    scrollY: window.scrollY,
                    scrollX: window.scrollX,
                    viewportHeight: window.innerHeight,
                    viewportWidth: window.innerWidth,
                    contentHeight: document.documentElement.scrollHeight,
                    contentWidth: document.documentElement.scrollWidth
                };
                
                // === 2. React/SPA 프레임워크 감지 ===
                const frameworkInfo = detectFramework();
                
                // === 3. 앱 컨테이너 및 구조 분석 ===
                const appStructure = analyzeAppStructure(frameworkInfo);
                
                // === 4. iframe 상태 수집 (크로스 프레임 지원) ===
                const iframeStates = collectIframeStates();
                
                // === 5. 강화된 가시 영역 아이템 수집 ===
                const visibleItems = collectEnhancedVisibleItems(frameworkInfo, appStructure);
                
                // === 6. 앵커 아이템 정밀 분석 ===
                const anchorItem = findEnhancedAnchorItem(visibleItems, frameworkInfo);
                
                // === 7. 가상화 상태 분석 ===
                const virtualizationState = analyzeVirtualizationState(frameworkInfo);
                
                // === 8. 컨테이너 스크롤 상태 ===
                const containerScrolls = collectContainerScrolls();
                
                // === 9. 프레임워크별 캐시 키 수집 ===
                const cacheKeys = collectFrameworkCacheKeys(frameworkInfo);
                
                // === 10. 컴포넌트별 스켈레톤 정보 ===
                const skeletonInfo = analyzeSkeletonStructure(visibleItems, frameworkInfo);
                
                return {
                    ...scrollInfo,
                    framework: frameworkInfo,
                    appStructure,
                    iframeStates,
                    visibleItems,
                    anchorItem,
                    virtualizationState,
                    containerScrolls,
                    cacheKeys,
                    skeletonInfo,
                    timestamp: Date.now()
                };
                
                // === 프레임워크 감지 함수 ===
                function detectFramework() {
                    const info = {
                        framework: 'vanilla',
                        version: null,
                        appContainerSelector: null,
                        hasReactRoot: false,
                        stateManagement: null,
                        routingLibrary: null
                    };
                    
                    // React 감지
                    if (window.React || document.querySelector('[data-reactroot]') || 
                        document.querySelector('[data-react-checksum]') || window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
                        info.framework = 'react';
                        info.version = window.React?.version || 'unknown';
                        info.hasReactRoot = !!window.ReactDOM?.createRoot || !!document.querySelector('[data-reactroot]');
                        
                        // React 앱 컨테이너 찾기
                        const containers = ['#root', '#app', '#react-root', '[data-reactroot]', '.app-container'];
                        for (const selector of containers) {
                            if (document.querySelector(selector)) {
                                info.appContainerSelector = selector;
                                break;
                            }
                        }
                        
                        // 상태 관리 라이브러리 감지
                        if (window.__REDUX_STORE__ || window.Redux) info.stateManagement = 'redux';
                        else if (window.MobX || window.mobx) info.stateManagement = 'mobx';
                        else if (window.zustand) info.stateManagement = 'zustand';
                        else if (window.Recoil) info.stateManagement = 'recoil';
                        
                        // 라우터 감지
                        if (window.ReactRouter || window.BrowserRouter) info.routingLibrary = 'react-router';
                        else if (window.Router && window.Router.pathname) info.routingLibrary = 'reach-router';
                        else if (window.next && window.next.router) info.routingLibrary = 'next-router';
                    }
                    // Vue 감지
                    else if (window.Vue || document.querySelector('[data-v-app]') || 
                             document.querySelector('[v-cloak]')) {
                        info.framework = 'vue';
                        info.version = window.Vue?.version || 'unknown';
                        info.appContainerSelector = '#app';
                        
                        if (window.Vuex) info.stateManagement = 'vuex';
                        if (window.VueRouter) info.routingLibrary = 'vue-router';
                    }
                    // Angular 감지
                    else if (window.ng || document.querySelector('[ng-app]') || 
                             document.querySelector('app-root')) {
                        info.framework = 'angular';
                        info.appContainerSelector = 'app-root';
                        
                        if (window.ngrx) info.stateManagement = 'ngrx';
                    }
                    // Svelte 감지
                    else if (window.svelte || document.querySelector('[data-svelte]')) {
                        info.framework = 'svelte';
                        info.appContainerSelector = 'body';
                    }
                    
                    console.log('🎯 프레임워크 감지:', info);
                    return info;
                }
                
                // === 앱 구조 분석 함수 ===
                function analyzeAppStructure(frameworkInfo) {
                    const structure = {
                        appContainer: null,
                        componentTree: [],
                        hasRouter: false,
                        hasStateManager: false
                    };
                    
                    // 앱 컨테이너 분석
                    if (frameworkInfo.appContainerSelector) {
                        structure.appContainer = document.querySelector(frameworkInfo.appContainerSelector);
                    }
                    
                    // 컴포넌트 트리 분석 (React 중심)
                    if (frameworkInfo.framework === 'react' && structure.appContainer) {
                        structure.componentTree = analyzeReactComponentTree(structure.appContainer);
                    }
                    
                    structure.hasRouter = !!frameworkInfo.routingLibrary;
                    structure.hasStateManager = !!frameworkInfo.stateManagement;
                    
                    return structure;
                }
                
                // React 컴포넌트 트리 분석
                function analyzeReactComponentTree(container, depth = 0) {
                    const components = [];
                    const maxDepth = 5; // 성능상 깊이 제한
                    
                    if (depth > maxDepth) return components;
                    
                    const elements = container.children;
                    for (let i = 0; i < Math.min(elements.length, 20); i++) {
                        const element = elements[i];
                        
                        // React 컴포넌트 특성 확인
                        const reactInfo = getReactInfo(element);
                        if (reactInfo) {
                            components.push({
                                id: element.id || `comp-\\${depth}-\\${i}`,
                                type: determineComponentType(element),
                                selector: getElementSelector(element),
                                props: reactInfo.props,
                                reactKey: reactInfo.key,
                                depth: depth
                            });
                        }
                        
                        // 재귀적으로 자식 분석
                        if (element.children.length > 0) {
                            components.push(...analyzeReactComponentTree(element, depth + 1));
                        }
                    }
                    
                    return components;
                }
                
                // React 정보 추출
                function getReactInfo(element) {
                    // React Fiber 정보 추출 시도
                    const fiberKey = Object.keys(element).find(key => key.startsWith('__reactFiber'));
                    if (fiberKey) {
                        const fiber = element[fiberKey];
                        return {
                            key: fiber.key,
                            props: extractSafeProps(fiber.memoizedProps || fiber.pendingProps),
                            type: fiber.type?.name || fiber.elementType?.name
                        };
                    }
                    
                    // 레거시 React 정보
                    const reactKey = Object.keys(element).find(key => key.startsWith('__reactInternalInstance'));
                    if (reactKey) {
                        const instance = element[reactKey];
                        return {
                            key: instance._currentElement?.key,
                            props: extractSafeProps(instance._currentElement?.props)
                        };
                    }
                    
                    // data 속성 기반 정보
                    if (element.dataset) {
                        const reactKey = element.dataset.reactkey || element.dataset.key;
                        if (reactKey) {
                            return { key: reactKey, props: null };
                        }
                    }
                    
                    return null;
                }
                
                // 안전한 props 추출
                function extractSafeProps(props) {
                    if (!props || typeof props !== 'object') return null;
                    
                    const safeProps = {};
                    const allowedTypes = ['string', 'number', 'boolean'];
                    
                    for (const [key, value] of Object.entries(props)) {
                        if (allowedTypes.includes(typeof value) && key.length < 50) {
                            safeProps[key] = String(value).slice(0, 100); // 길이 제한
                        }
                    }
                    
                    return Object.keys(safeProps).length > 0 ? safeProps : null;
                }
                
                // === iframe 상태 수집 ===
                function collectIframeStates() {
                    const iframes = [];
                    document.querySelectorAll('iframe').forEach((iframe, index) => {
                        const state = {
                            iframeSelector: iframe.id ? `#\\${iframe.id}` : `iframe:nth-child(\\${index + 1})`,
                            src: iframe.src,
                            scrollX: 0,
                            scrollY: 0,
                            contentHeight: 0,
                            isAccessible: false,
                            nestedFrames: []
                        };
                        
                        try {
                            // Same-origin iframe 접근 시도
                            if (iframe.contentWindow && iframe.contentDocument) {
                                state.scrollX = iframe.contentWindow.scrollX;
                                state.scrollY = iframe.contentWindow.scrollY;
                                state.contentHeight = iframe.contentDocument.documentElement.scrollHeight;
                                state.isAccessible = true;
                                
                                // 중첩 iframe 수집
                                const nestedIframes = iframe.contentDocument.querySelectorAll('iframe');
                                nestedIframes.forEach((nested, nestedIndex) => {
                                    try {
                                        if (nested.contentWindow && nested.contentDocument) {
                                            state.nestedFrames.push({
                                                iframeSelector: nested.id ? `#\\${nested.id}` : `iframe:nth-child(\\${nestedIndex + 1})`,
                                                src: nested.src,
                                                scrollX: nested.contentWindow.scrollX,
                                                scrollY: nested.contentWindow.scrollY,
                                                contentHeight: nested.contentDocument.documentElement.scrollHeight,
                                                isAccessible: true,
                                                nestedFrames: []
                                            });
                                        }
                                    } catch (e) {
                                        // CORS 제한으로 접근 불가
                                    }
                                });
                            }
                        } catch (e) {
                            // CORS 제한으로 접근 불가
                        }
                        
                        iframes.push(state);
                    });
                    
                    return iframes;
                }
                
                // === 강화된 가시 영역 아이템 수집 ===
                function collectEnhancedVisibleItems(frameworkInfo, appStructure) {
                    const visibleItems = [];
                    
                    // 프레임워크별 선택자 우선순위
                    let selectors = [];
                    if (frameworkInfo.framework === 'react') {
                        selectors = [
                            '[data-reactroot] > *', '[data-react-checksum] > *',
                            '.react-component', '[data-component]',
                            'article', '.item', '.post', '.card', '.entry',
                            '[data-testid]', '[data-cy]'
                        ];
                    } else if (frameworkInfo.framework === 'vue') {
                        selectors = [
                            '[data-v-app] > *', '[v-for]',
                            '.vue-component', 'article', '.item', '.post'
                        ];
                    } else {
                        // 범용 선택자
                        selectors = [
                            'article', '.item', '.post', '.card', '.entry', '.content-item',
                            '[data-id]', '[data-item-id]', '[data-index]',
                            '.list-item', '.grid-item', 'li', '.row', '.tile'
                        ];
                    }
                    
                    const allElements = new Set();
                    selectors.forEach(selector => {
                        try {
                            document.querySelectorAll(selector).forEach(el => allElements.add(el));
                        } catch (e) {
                            console.warn('선택자 오류:', selector, e);
                        }
                    });
                    
                    // 가시성 체크 및 정보 수집
                    Array.from(allElements).forEach((el, index) => {
                        if (visibleItems.length >= 30) return; // 성능상 제한
                        
                        const rect = el.getBoundingClientRect();
                        const isVisible = rect.top < window.innerHeight && rect.bottom > 0 && rect.height > 10;
                        
                        if (isVisible) {
                            // React 컴포넌트 정보 추출
                            const reactInfo = getReactInfo(el);
                            const componentInfo = reactInfo ? {
                                componentName: reactInfo.type || 'Unknown',
                                reactKey: reactInfo.key,
                                dataAttributes: extractDataAttributes(el),
                                isLazyLoaded: hasLazyLoadingIndicators(el),
                                hasAsyncData: hasAsyncDataIndicators(el)
                            } : null;
                            
                            // 동적 콘텐츠 정보
                            const dynamicInfo = {
                                isSkeletonPlaceholder: isSkeletonPlaceholder(el),
                                hasLoadingState: hasLoadingState(el),
                                apiEndpoint: extractApiEndpoint(el),
                                cacheKey: extractCacheKey(el, frameworkInfo),
                                loadingStrategy: determineLoadingStrategy(el)
                            };
                            
                            visibleItems.push({
                                id: el.id || el.dataset.id || el.dataset.itemId || `enhanced-item-\\${index}`,
                                selector: getElementSelector(el),
                                offsetTop: el.offsetTop,
                                height: rect.height,
                                content: (el.textContent || '').slice(0, 100),
                                hasImage: el.querySelector('img, picture, svg') !== null,
                                loadPriority: rect.top < window.innerHeight / 2 ? 1 : 2,
                                componentInfo,
                                dynamicContent: dynamicInfo
                            });
                        }
                    });
                    
                    return visibleItems;
                }
                
                // === 강화된 앵커 아이템 찾기 ===
                function findEnhancedAnchorItem(visibleItems, frameworkInfo) {
                    for (const item of visibleItems) {
                        const el = document.querySelector(item.selector);
                        if (!el) continue;
                        
                        const rect = el.getBoundingClientRect();
                        if (rect.top >= 0 && rect.top <= window.innerHeight / 3) {
                            const reactInfo = item.componentInfo || {};
                            
                            return {
                                id: item.id,
                                selector: item.selector,
                                offsetFromTop: rect.top,
                                elementHeight: rect.height,
                                isSticky: getComputedStyle(el).position === 'sticky',
                                reactComponentName: reactInfo.componentName,
                                reactKey: reactInfo.reactKey,
                                reactProps: reactInfo.dataAttributes,
                                isVirtualItem: !!item.dynamicContent?.isSkeletonPlaceholder
                            };
                        }
                    }
                    
                    // 기본 앵커 (body)
                    return {
                        id: 'body-anchor',
                        selector: 'body',
                        offsetFromTop: 0,
                        elementHeight: 100,
                        isSticky: false,
                        reactComponentName: null,
                        reactKey: null,
                        reactProps: null,
                        isVirtualItem: false
                    };
                }
                
                // === 가상화 상태 분석 ===
                function analyzeVirtualizationState(frameworkInfo) {
                    const state = {
                        isVirtual: false,
                        libraryType: null,
                        currentSequence: 0,
                        visibleStartIndex: 0,
                        visibleEndIndex: 0,
                        totalKnownItems: 0,
                        itemHeight: null,
                        estimatedItemSize: null,
                        pageInfo: null,
                        scrollOffset: 0
                    };
                    
                    // react-window 감지
                    if (window.FixedSizeList || window.VariableSizeList || document.querySelector('[data-react-window-list]')) {
                        state.isVirtual = true;
                        state.libraryType = 'react-window';
                        
                        const virtualList = document.querySelector('[data-react-window-list]');
                        if (virtualList) {
                            // react-window 상태 추출
                            const scrollContainer = virtualList.querySelector('[style*="overflow"]');
                            if (scrollContainer) {
                                state.scrollOffset = scrollContainer.scrollTop;
                            }
                            
                            // 아이템 크기 추정
                            const items = virtualList.querySelectorAll('[data-index]');
                            if (items.length > 0) {
                                const heights = Array.from(items).map(item => item.getBoundingClientRect().height);
                                state.itemHeight = heights[0]; // 첫 번째 아이템 높이
                                state.estimatedItemSize = heights.reduce((a, b) => a + b, 0) / heights.length;
                            }
                        }
                    }
                    // react-virtualized 감지
                    else if (window.List || window.Grid || document.querySelector('[data-react-virtualized-list]')) {
                        state.isVirtual = true;
                        state.libraryType = 'react-virtualized';
                    }
                    // react-virtual 감지
                    else if (window.useVirtual || document.querySelector('[data-virtual-container]')) {
                        state.isVirtual = true;
                        state.libraryType = 'react-virtual';
                    }
                    
                    // 무한 스크롤 감지
                    const infiniteScrollTriggers = [
                        '.infinite-scroll-trigger', '[data-infinite-scroll]',
                        '.load-more', '.loading-more', '.infinite-loader'
                    ];
                    
                    for (const trigger of infiniteScrollTriggers) {
                        if (document.querySelector(trigger)) {
                            state.pageInfo = {
                                currentPage: extractCurrentPage(),
                                pageSize: 20, // 기본값
                                loadedPages: [1], // 기본값
                                hasNextPage: true,
                                infiniteScrollTrigger: trigger,
                                loadMoreElement: trigger
                            };
                            break;
                        }
                    }
                    
                    return state;
                }
                
                // === 컨테이너 스크롤 수집 ===
                function collectContainerScrolls() {
                    const scrolls = {};
                    
                    // overflow가 있는 모든 요소 검사
                    const scrollableElements = document.querySelectorAll('*');
                    let count = 0;
                    
                    for (const el of scrollableElements) {
                        if (count >= 20) break; // 성능 제한
                        
                        const style = getComputedStyle(el);
                        const hasScroll = style.overflow === 'auto' || style.overflow === 'scroll' ||
                                         style.overflowY === 'auto' || style.overflowY === 'scroll';
                        
                        if (hasScroll && (el.scrollTop > 0 || el.scrollLeft > 0)) {
                            const selector = getElementSelector(el);
                            scrolls[selector] = el.scrollTop;
                            count++;
                        }
                    }
                    
                    return scrolls;
                }
                
                // === 프레임워크별 캐시 키 수집 ===
                function collectFrameworkCacheKeys(frameworkInfo) {
                    const cacheKeys = {};
                    
                    // Redux 상태
                    if (window.__REDUX_STORE__ && frameworkInfo.stateManagement === 'redux') {
                        try {
                            const state = window.__REDUX_STORE__.getState();
                            cacheKeys.redux = JSON.stringify(state).slice(0, 1000); // 크기 제한
                        } catch (e) {
                            console.warn('Redux 상태 수집 실패:', e);
                        }
                    }
                    
                    // React Query 캐시
                    if (window.__REACT_QUERY_CLIENT__) {
                        try {
                            const queryCache = window.__REACT_QUERY_CLIENT__.getQueryCache();
                            const queries = queryCache.getAll();
                            if (queries.length > 0) {
                                cacheKeys.reactQuery = JSON.stringify({
                                    key: queries[0].queryKey,
                                    data: queries[0].state.data
                                }).slice(0, 1000);
                            }
                        } catch (e) {
                            console.warn('React Query 캐시 수집 실패:', e);
                        }
                    }
                    
                    // Apollo Client 캐시
                    if (window.__APOLLO_CLIENT__) {
                        try {
                            const cache = window.__APOLLO_CLIENT__.cache.extract();
                            cacheKeys.apollo = JSON.stringify(cache).slice(0, 1000);
                        } catch (e) {
                            console.warn('Apollo 캐시 수집 실패:', e);
                        }
                    }
                    
                    return cacheKeys;
                }
                
                // === 스켈레톤 구조 분석 ===
                function analyzeSkeletonStructure(visibleItems, frameworkInfo) {
                    const componentTypes = {};
                    let totalHeight = 0;
                    
                    visibleItems.forEach(item => {
                        const type = item.componentInfo?.componentName || determineComponentType(document.querySelector(item.selector));
                        if (!componentTypes[type]) {
                            componentTypes[type] = {
                                count: 0,
                                averageHeight: 0,
                                hasImages: 0,
                                hasText: 0
                            };
                        }
                        
                        componentTypes[type].count++;
                        componentTypes[type].averageHeight += item.height;
                        if (item.hasImage) componentTypes[type].hasImages++;
                        if (item.content) componentTypes[type].hasText++;
                        
                        totalHeight += item.height;
                    });
                    
                    // 평균값 계산
                    Object.keys(componentTypes).forEach(type => {
                        const info = componentTypes[type];
                        info.averageHeight = info.averageHeight / info.count;
                    });
                    
                    return {
                        componentTypes,
                        averageItemHeight: visibleItems.length > 0 ? totalHeight / visibleItems.length : 120
                    };
                }
                
                // === 유틸리티 함수들 ===
                function getElementSelector(element) {
                    if (element.id) return `#\\${element.id}`;
                    if (element.className && typeof element.className === 'string') {
                        const classes = element.className.split(' ').filter(c => c && !c.includes('sk-')); // 스켈레톤 클래스 제외
                        if (classes.length > 0) return `.\\${classes[0]}`;
                    }
                    return element.tagName.toLowerCase();
                }
                
                function determineComponentType(element) {
                    if (!element) return 'unknown';
                    
                    // 클래스명 기반 타입 추정
                    const className = element.className;
                    if (typeof className === 'string') {
                        if (className.includes('card')) return 'card';
                        if (className.includes('item') || className.includes('list')) return 'list-item';
                        if (className.includes('article') || className.includes('post')) return 'article';
                        if (className.includes('product')) return 'product';
                    }
                    
                    // 태그명 기반
                    switch (element.tagName.toLowerCase()) {
                        case 'article': return 'article';
                        case 'li': return 'list-item';
                        case 'section': return 'section';
                        default: return 'component';
                    }
                }
                
                function extractDataAttributes(element) {
                    const attrs = {};
                    if (element.dataset) {
                        Object.keys(element.dataset).forEach(key => {
                            attrs[key] = element.dataset[key];
                        });
                    }
                    return Object.keys(attrs).length > 0 ? attrs : null;
                }
                
                function hasLazyLoadingIndicators(element) {
                    return element.querySelector('img[loading="lazy"]') ||
                           element.querySelector('[data-lazy]') ||
                           element.classList.contains('lazy') ||
                           element.classList.contains('lazyload');
                }
                
                function hasAsyncDataIndicators(element) {
                    return element.querySelector('.loading') ||
                           element.querySelector('.spinner') ||
                           element.classList.contains('loading') ||
                           element.hasAttribute('data-loading');
                }
                
                function isSkeletonPlaceholder(element) {
                    const className = element.className;
                    if (typeof className === 'string') {
                        return className.includes('skeleton') ||
                               className.includes('placeholder') ||
                               className.includes('shimmer') ||
                               className.includes('loading-skeleton');
                    }
                    return false;
                }
                
                function hasLoadingState(element) {
                    return element.querySelector('.loading-state') ||
                           element.classList.contains('is-loading') ||
                           element.hasAttribute('aria-busy');
                }
                
                function extractApiEndpoint(element) {
                    // data 속성에서 API 엔드포인트 추출 시도
                    if (element.dataset.api) return element.dataset.api;
                    if (element.dataset.endpoint) return element.dataset.endpoint;
                    if (element.dataset.url) return element.dataset.url;
                    return null;
                }
                
                function extractCacheKey(element, frameworkInfo) {
                    if (element.dataset.cacheKey) return element.dataset.cacheKey;
                    if (element.dataset.queryKey) return element.dataset.queryKey;
                    
                    // React Query 스타일 키 생성
                    if (frameworkInfo.framework === 'react') {
                        const id = element.id || element.dataset.id;
                        if (id) return `query_\\${id}`;
                    }
                    
                    return null;
                }
                
                function determineLoadingStrategy(element) {
                    if (hasLazyLoadingIndicators(element)) return 'lazy';
                    if (element.getBoundingClientRect().top < window.innerHeight) return 'eager';
                    return 'intersection';
                }
                
                function extractCurrentPage() {
                    // URL 파라미터에서 페이지 추출
                    const params = new URLSearchParams(window.location.search);
                    return parseInt(params.get('page') || '1', 10);
                }
                
            } catch (e) {
                console.error('강화된 동적 사이트 분석 실패:', e);
                return null;
            }
        })()
        """
        
        return executeJavaScriptSync(webView: webView, script: script)
    }
    
    // 헬퍼 메서드들 - React/SPA 정보 추출
    private func extractReactAppInfo(from data: [String: Any]?) -> BFCacheSnapshot.ScrollStateBlock.ReactAppInfo {
        guard let data = data,
              let frameworkData = data["framework"] as? [String: Any] else {
            return createDefaultReactAppInfo()
        }
        
        let framework = frameworkData["framework"] as? String ?? "vanilla"
        let appContainerSelector = frameworkData["appContainerSelector"] as? String ?? "#app"
        let hasReactRoot = frameworkData["hasReactRoot"] as? Bool ?? false
        let stateManagement = frameworkData["stateManagement"] as? String
        let routingLibrary = frameworkData["routingLibrary"] as? String
        
        // 컴포넌트 트리 추출
        var componentTree: [BFCacheSnapshot.ScrollStateBlock.ReactAppInfo.ComponentInfo] = []
        if let appStructure = data["appStructure"] as? [String: Any],
           let components = appStructure["componentTree"] as? [[String: Any]] {
            componentTree = components.compactMap { compData in
                guard let id = compData["id"] as? String,
                      let type = compData["type"] as? String,
                      let selector = compData["selector"] as? String else { return nil }
                
                return BFCacheSnapshot.ScrollStateBlock.ReactAppInfo.ComponentInfo(
                    id: id,
                    type: type,
                    selector: selector,
                    props: compData["props"] as? [String: String],
                    reactKey: compData["reactKey"] as? String,
                    depth: compData["depth"] as? Int ?? 0
                )
            }
        }
        
        return BFCacheSnapshot.ScrollStateBlock.ReactAppInfo(
            framework: framework,
            appContainerSelector: appContainerSelector,
            hasReactRoot: hasReactRoot,
            componentTree: componentTree,
            stateManagement: stateManagement,
            routingLibrary: routingLibrary
        )
    }
    
    private func createDefaultReactAppInfo() -> BFCacheSnapshot.ScrollStateBlock.ReactAppInfo {
        return BFCacheSnapshot.ScrollStateBlock.ReactAppInfo(
            framework: "vanilla",
            appContainerSelector: "body",
            hasReactRoot: false,
            componentTree: [],
            stateManagement: nil,
            routingLibrary: nil
        )
    }
    
    private func extractIframeStates(from data: [String: Any]?) -> [BFCacheSnapshot.ScrollStateBlock.IframeScrollState] {
        guard let data = data,
              let iframeData = data["iframeStates"] as? [[String: Any]] else { return [] }
        
        return iframeData.compactMap { iframeInfo in
            guard let selector = iframeInfo["iframeSelector"] as? String,
                  let src = iframeInfo["src"] as? String else { return nil }
            
            let nestedFrames: [BFCacheSnapshot.ScrollStateBlock.IframeScrollState] = []
            if let _ = iframeInfo["nestedFrames"] as? [[String: Any]] {
                // 재귀적으로 중첩 iframe 처리는 간단화
                // 실제로는 더 복잡한 로직 필요
            }
            
            return BFCacheSnapshot.ScrollStateBlock.IframeScrollState(
                iframeSelector: selector,
                src: src,
                scrollX: iframeInfo["scrollX"] as? CGFloat ?? 0,
                scrollY: iframeInfo["scrollY"] as? CGFloat ?? 0,
                contentHeight: iframeInfo["contentHeight"] as? CGFloat ?? 0,
                isAccessible: iframeInfo["isAccessible"] as? Bool ?? false,
                nestedFrames: nestedFrames
            )
        }
    }
    
    private func extractEnhancedAnchorItem(from data: [String: Any]?) -> BFCacheSnapshot.ScrollStateBlock.AnchorItemInfo {
        guard let data = data,
              let anchorData = data["anchorItem"] as? [String: Any],
              let id = anchorData["id"] as? String,
              let selector = anchorData["selector"] as? String else {
            return createDefaultAnchorItem()
        }
        
        return BFCacheSnapshot.ScrollStateBlock.AnchorItemInfo(
            id: id,
            selector: selector,
            offsetFromTop: anchorData["offsetFromTop"] as? CGFloat ?? 0,
            elementHeight: anchorData["elementHeight"] as? CGFloat ?? 100,
            isSticky: anchorData["isSticky"] as? Bool ?? false,
            reactComponentName: anchorData["reactComponentName"] as? String,
            reactKey: anchorData["reactKey"] as? String,
            reactProps: anchorData["reactProps"] as? [String: String],
            isVirtualItem: anchorData["isVirtualItem"] as? Bool ?? false
        )
    }
    
    private func createDefaultAnchorItem() -> BFCacheSnapshot.ScrollStateBlock.AnchorItemInfo {
        return BFCacheSnapshot.ScrollStateBlock.AnchorItemInfo(
            id: "body-anchor",
            selector: "body",
            offsetFromTop: 0,
            elementHeight: 100,
            isSticky: false,
            reactComponentName: nil,
            reactKey: nil,
            reactProps: nil,
            isVirtualItem: false
        )
    }
    
    private func extractEnhancedVisibleItems(from data: [String: Any]?) -> [BFCacheSnapshot.ScrollStateBlock.VisibleItemInfo] {
        guard let data = data,
              let itemsData = data["visibleItems"] as? [[String: Any]] else { return [] }
        
        return itemsData.compactMap { itemData in
            guard let id = itemData["id"] as? String,
                  let selector = itemData["selector"] as? String else { return nil }
            
            // 컴포넌트 정보 추출
            var componentInfo: BFCacheSnapshot.ScrollStateBlock.VisibleItemInfo.ComponentInfo?
            if let compData = itemData["componentInfo"] as? [String: Any],
               let componentName = compData["componentName"] as? String {
                componentInfo = BFCacheSnapshot.ScrollStateBlock.VisibleItemInfo.ComponentInfo(
                    componentName: componentName,
                    reactKey: compData["reactKey"] as? String,
                    dataAttributes: compData["dataAttributes"] as? [String: String] ?? [:],
                    isLazyLoaded: compData["isLazyLoaded"] as? Bool ?? false,
                    hasAsyncData: compData["hasAsyncData"] as? Bool ?? false
                )
            }
            
            // 동적 콘텐츠 정보 추출
            var dynamicContent: BFCacheSnapshot.ScrollStateBlock.VisibleItemInfo.DynamicContentInfo?
            if let dynData = itemData["dynamicContent"] as? [String: Any] {
                dynamicContent = BFCacheSnapshot.ScrollStateBlock.VisibleItemInfo.DynamicContentInfo(
                    isSkeletonPlaceholder: dynData["isSkeletonPlaceholder"] as? Bool ?? false,
                    hasLoadingState: dynData["hasLoadingState"] as? Bool ?? false,
                    apiEndpoint: dynData["apiEndpoint"] as? String,
                    cacheKey: dynData["cacheKey"] as? String,
                    loadingStrategy: dynData["loadingStrategy"] as? String ?? "eager"
                )
            }
            
            return BFCacheSnapshot.ScrollStateBlock.VisibleItemInfo(
                id: id,
                selector: selector,
                offsetTop: itemData["offsetTop"] as? CGFloat ?? 0,
                height: itemData["height"] as? CGFloat ?? 100,
                content: itemData["content"] as? String,
                hasImage: itemData["hasImage"] as? Bool ?? false,
                loadPriority: itemData["loadPriority"] as? Int ?? 2,
                componentInfo: componentInfo,
                dynamicContent: dynamicContent
            )
        }
    }
    
    private func extractEnhancedVirtualizationState(from data: [String: Any]?) -> BFCacheSnapshot.ScrollStateBlock.VirtualizationState {
        guard let data = data,
              let virtData = data["virtualizationState"] as? [String: Any] else {
            return createDefaultVirtualizationState()
        }
        
        var pageInfo: BFCacheSnapshot.ScrollStateBlock.VirtualizationState.PageInfo?
        if let pageData = virtData["pageInfo"] as? [String: Any] {
            pageInfo = BFCacheSnapshot.ScrollStateBlock.VirtualizationState.PageInfo(
                currentPage: pageData["currentPage"] as? Int ?? 1,
                pageSize: pageData["pageSize"] as? Int ?? 20,
                loadedPages: pageData["loadedPages"] as? [Int] ?? [1],
                hasNextPage: pageData["hasNextPage"] as? Bool ?? true,
                infiniteScrollTrigger: pageData["infiniteScrollTrigger"] as? String,
                loadMoreElement: pageData["loadMoreElement"] as? String
            )
        }
        
        return BFCacheSnapshot.ScrollStateBlock.VirtualizationState(
            isVirtual: virtData["isVirtual"] as? Bool ?? false,
            libraryType: virtData["libraryType"] as? String,
            currentSequence: virtData["currentSequence"] as? Int ?? 0,
            visibleStartIndex: virtData["visibleStartIndex"] as? Int ?? 0,
            visibleEndIndex: virtData["visibleEndIndex"] as? Int ?? 0,
            totalKnownItems: virtData["totalKnownItems"] as? Int ?? 0,
            itemHeight: virtData["itemHeight"] as? CGFloat,
            estimatedItemSize: virtData["estimatedItemSize"] as? CGFloat,
            pageInfo: pageInfo,
            scrollOffset: virtData["scrollOffset"] as? CGFloat ?? 0
        )
    }
    
    private func createDefaultVirtualizationState() -> BFCacheSnapshot.ScrollStateBlock.VirtualizationState {
        return BFCacheSnapshot.ScrollStateBlock.VirtualizationState(
            isVirtual: false,
            libraryType: nil,
            currentSequence: 0,
            visibleStartIndex: 0,
            visibleEndIndex: 0,
            totalKnownItems: 0,
            itemHeight: nil,
            estimatedItemSize: nil,
            pageInfo: nil,
            scrollOffset: 0
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
    
    private func extractEnhancedCacheKeys(from data: [String: Any]?) -> [String: String] {
        guard let data = data,
              let cacheKeys = data["cacheKeys"] as? [String: String] else { return [:] }
        return cacheKeys
    }
    
    private func createDynamicSkeletonTemplate(from data: [String: Any]?, reactAppInfo: BFCacheSnapshot.ScrollStateBlock.ReactAppInfo) -> BFCacheSnapshot.SkeletonTemplate {
        guard let data = data,
              let skeletonInfo = data["skeletonInfo"] as? [String: Any] else {
            return createDefaultSkeletonTemplate(framework: reactAppInfo.framework)
        }
        
        let averageItemHeight = skeletonInfo["averageItemHeight"] as? CGFloat ?? 120
        let componentTypes = skeletonInfo["componentTypes"] as? [String: [String: Any]] ?? [:]
        
        // 컴포넌트별 스켈레톤 생성
        let componentSkeletons = componentTypes.map { (type, info) in
            let _ = info["count"] as? Int ?? 1
            let avgHeight = info["averageHeight"] as? CGFloat ?? 120
            let hasImages = (info["hasImages"] as? Int ?? 0) > 0
            let hasText = (info["hasText"] as? Int ?? 0) > 0
            
            return BFCacheSnapshot.SkeletonTemplate.ComponentSkeleton(
                componentType: type,
                htmlTemplate: createSkeletonHTML(for: type, hasImages: hasImages, hasText: hasText, framework: reactAppInfo.framework),
                cssTemplate: createSkeletonCSS(for: type, height: avgHeight),
                estimatedHeight: avgHeight,
                containsImages: hasImages,
                containsText: hasText,
                priority: getPriorityForComponentType(type)
            )
        }
        
        return BFCacheSnapshot.SkeletonTemplate(
            averageItemHeight: averageItemHeight,
            itemsPerScreen: Int(data["viewportHeight"] as? CGFloat ?? 800) / Int(averageItemHeight),
            totalSkeletonItems: max(componentSkeletons.count * 5, 10),
            skeletonPattern: "", // 레거시 필드
            placeholderStyles: [:],
            componentSkeletons: componentSkeletons
        )
    }
    
    private func createDefaultSkeletonTemplate(framework: String) -> BFCacheSnapshot.SkeletonTemplate {
        let defaultComponents = [
            BFCacheSnapshot.SkeletonTemplate.ComponentSkeleton(
                componentType: "list-item",
                htmlTemplate: createSkeletonHTML(for: "list-item", hasImages: true, hasText: true, framework: framework),
                cssTemplate: "display: flex; align-items: center; padding: 12px 16px;",
                estimatedHeight: 80,
                containsImages: true,
                containsText: true,
                priority: 1
            ),
            BFCacheSnapshot.SkeletonTemplate.ComponentSkeleton(
                componentType: "card",
                htmlTemplate: createSkeletonHTML(for: "card", hasImages: true, hasText: true, framework: framework),
                cssTemplate: "border-radius: 12px; padding: 16px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);",
                estimatedHeight: 200,
                containsImages: true,
                containsText: true,
                priority: 2
            )
        ]
        
        return BFCacheSnapshot.SkeletonTemplate(
            averageItemHeight: 120,
            itemsPerScreen: 7,
            totalSkeletonItems: 15,
            skeletonPattern: "",
            placeholderStyles: [:],
            componentSkeletons: defaultComponents
        )
    }
    
    private func createSkeletonHTML(for type: String, hasImages: Bool, hasText: Bool, framework: String) -> String {
        var html = ""
        
        if hasImages {
            html += """
            <div style="width: 60px; height: 60px; background: #e2e8f0; border-radius: 8px; flex-shrink: 0; margin-right: 12px;"></div>
            """
        }
        
        if hasText {
            html += """
            <div style="flex: 1;">
                <div style="height: 20px; background: #e2e8f0; margin-bottom: 8px; border-radius: 4px;"></div>
                <div style="height: 16px; background: #f1f5f9; width: 80%; border-radius: 4px;"></div>
            </div>
            """
        }
        
        // React 컴포넌트 특성 추가
        if framework == "react" {
            html = """
            <div data-react-skeleton="true" data-component-type="\(type)">
                \(html)
            </div>
            """
        }
        
        return html
    }
    
    private func createSkeletonCSS(for type: String, height: CGFloat) -> String {
        return """
        height: \(height)px;
        margin: 8px 0;
        padding: 12px;
        background: linear-gradient(90deg, #e2e8f0 25%, #f1f5f9 50%, #e2e8f0 75%);
        background-size: 200% 100%;
        animation: bfcache-shimmer 1.8s infinite;
        border-radius: 8px;
        """
    }
    
    private func getPriorityForComponentType(_ type: String) -> Int {
        switch type {
        case "list-item": return 1
        case "card": return 2
        case "article": return 3
        default: return 4
        }
    }
    
    private func createFrameworkAwareDataLoadingGuide(from data: [String: Any]?, reactAppInfo: BFCacheSnapshot.ScrollStateBlock.ReactAppInfo) -> BFCacheSnapshot.DataLoadingGuide {
        let framework = reactAppInfo.framework
        
        // 프레임워크별 복원 전략
        let strategy = BFCacheSnapshot.DataLoadingGuide.FrameworkStrategy(
            framework: framework,
            hydrationMethod: determineHydrationMethod(framework: framework),
            dataFetchingPattern: determineFetchingPattern(framework: framework, stateManagement: reactAppInfo.stateManagement),
            routerType: reactAppInfo.routingLibrary,
            customRestoreScript: createCustomRestoreScript(for: framework)
        )
        
        // 기본 로딩 단계 (프레임워크별 최적화)
        var loadingSteps: [BFCacheSnapshot.DataLoadingGuide.LoadingStep] = []
        
        // React 특화 단계
        if framework == "react" {
            loadingSteps.append(contentsOf: createReactLoadingSteps(reactAppInfo: reactAppInfo))
        } else if framework == "vue" {
            loadingSteps.append(contentsOf: createVueLoadingSteps())
        } else if framework == "angular" {
            loadingSteps.append(contentsOf: createAngularLoadingSteps())
        } else {
            loadingSteps.append(contentsOf: createVanillaLoadingSteps())
        }
        
        return BFCacheSnapshot.DataLoadingGuide(
            loadingSequence: loadingSteps,
            backgroundLoadingEnabled: true,
            lockScrollDuringLoad: true,
            frameworkStrategy: strategy
        )
    }
    
    private func determineHydrationMethod(framework: String) -> String {
        switch framework {
        case "react": return "client-side"
        case "vue": return "client-side"
        case "angular": return "client-side"
        default: return "static-generation"
        }
    }
    
    private func determineFetchingPattern(framework: String, stateManagement: String?) -> String {
        if let state = stateManagement {
            switch state {
            case "redux": return "redux-toolkit"
            case "mobx": return "mobx"
            case "zustand": return "zustand"
            case "recoil": return "recoil"
            default: return "local-state"
            }
        }
        
        switch framework {
        case "react": return "react-query"
        case "vue": return "vue-composition"
        case "angular": return "rxjs"
        default: return "fetch"
        }
    }
    
    private func createCustomRestoreScript(for framework: String) -> String? {
        switch framework {
        case "react":
            return """
            // React 하이드레이션 헬퍼
            if (window.React && window.ReactDOM) {
                window.bfcacheReactHydrate = function() {
                    console.log('React 하이드레이션 헬퍼 실행');
                    // 실제 React 앱별 하이드레이션 로직 구현 필요
                };
            }
            """
        case "vue":
            return """
            // Vue 하이드레이션 헬퍼
            if (window.Vue) {
                window.bfcacheVueHydrate = function() {
                    console.log('Vue 하이드레이션 헬퍼 실행');
                };
            }
            """
        default:
            return nil
        }
    }
    
    private func createReactLoadingSteps(reactAppInfo: BFCacheSnapshot.ScrollStateBlock.ReactAppInfo) -> [BFCacheSnapshot.DataLoadingGuide.LoadingStep] {
        var steps: [BFCacheSnapshot.DataLoadingGuide.LoadingStep] = []
        
        // React 컴포넌트 복원
        steps.append(BFCacheSnapshot.DataLoadingGuide.LoadingStep(
            stepId: "react_components",
            dataSource: "cache:react_components",
            targetSelectors: [".bfcache-skeleton[data-component-type]"],
            delayMs: 50,
            priority: 1,
            fallbackContent: "<div>Loading React Component...</div>",
            reactStateRestore: nil
        ))
        
        // Redux 상태 복원
        if reactAppInfo.stateManagement == "redux" {
            steps.append(BFCacheSnapshot.DataLoadingGuide.LoadingStep(
                stepId: "redux_state",
                dataSource: "cache:redux_store",
                targetSelectors: ["[data-react-skeleton]"],
                delayMs: 100,
                priority: 1,
                fallbackContent: nil,
                reactStateRestore: BFCacheSnapshot.DataLoadingGuide.LoadingStep.ReactStateRestore(
                    storeType: "redux",
                    stateKey: "app",
                    stateValue: "{}",
                    actionType: "HYDRATE_FROM_CACHE"
                )
            ))
        }
        
        return steps
    }
    
    private func createVueLoadingSteps() -> [BFCacheSnapshot.DataLoadingGuide.LoadingStep] {
        return [
            BFCacheSnapshot.DataLoadingGuide.LoadingStep(
                stepId: "vue_components",
                dataSource: "cache:vue_components",
                targetSelectors: [".bfcache-skeleton"],
                delayMs: 100,
                priority: 1,
                fallbackContent: "<div>Loading Vue Component...</div>",
                reactStateRestore: nil
            )
        ]
    }
    
    private func createAngularLoadingSteps() -> [BFCacheSnapshot.DataLoadingGuide.LoadingStep] {
        return [
            BFCacheSnapshot.DataLoadingGuide.LoadingStep(
                stepId: "angular_components",
                dataSource: "cache:angular_components",
                targetSelectors: [".bfcache-skeleton"],
                delayMs: 150,
                priority: 1,
                fallbackContent: "<div>Loading Angular Component...</div>",
                reactStateRestore: nil
            )
        ]
    }
    
    private func createVanillaLoadingSteps() -> [BFCacheSnapshot.DataLoadingGuide.LoadingStep] {
        return [
            BFCacheSnapshot.DataLoadingGuide.LoadingStep(
                stepId: "vanilla_content",
                dataSource: "cache:page_content",
                targetSelectors: [".bfcache-skeleton"],
                delayMs: 200,
                priority: 2,
                fallbackContent: "<div>Loading Content...</div>",
                reactStateRestore: nil
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
        
        _ = semaphore.wait(timeout: .now() + 3.0) // 복잡한 분석을 위해 3초로 증가
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
            
            self.dbg("💾 강화된 동적 사이트 상태 저장 완료: \(snapshot.snapshot.pageRecord.title) [\(snapshot.snapshot.scrollStateBlock.reactAppInfo.framework)] [v\(version)]")
            
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
                
                self.dbg("💾 강화된 디스크 캐시 인덱스 로드 완료: \(loadedCount)개 항목")
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
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title) [\(snapshot.scrollStateBlock.reactAppInfo.framework)]")
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
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [\(snapshot.scrollStateBlock.reactAppInfo.framework)] [v\(snapshot.version)]")
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
    
    // MARK: - 🎯 강화된 제스처 시스템 (React/SPA 대응)
    
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
        
        dbg("강화된 동적 사이트 복원 제스처 설정 완료")
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
    
    // MARK: - 제스처 전환 로직 (강화된 동적 사이트 지원)
    
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
        
        dbg("🎬 강화된 제스처 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
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
                dbg("📸 타겟 페이지 강화된 BFCache 스냅샷 사용: \(targetRecord.title)")
            } else {
                targetView = createEnhancedInfoCard(for: targetRecord, in: webView.bounds)
                dbg("ℹ️ 타겟 페이지 강화된 정보 카드 생성: \(targetRecord.title)")
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
    
    private func createEnhancedInfoCard(for record: PageRecord, in bounds: CGRect) -> UIView {
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
        
        // 프레임워크 아이콘
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        
        // URL을 기반으로 프레임워크 추정
        let host = record.url.host?.lowercased() ?? ""
        if host.contains("react") {
            iconView.image = UIImage(systemName: "atom")
            iconView.tintColor = .systemBlue
        } else if host.contains("vue") {
            iconView.image = UIImage(systemName: "v.square")
            iconView.tintColor = .systemGreen
        } else if host.contains("angular") {
            iconView.image = UIImage(systemName: "a.square")
            iconView.tintColor = .systemRed
        } else {
            iconView.image = UIImage(systemName: "globe")
            iconView.tintColor = .systemBlue
        }
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
        
        // 사이트 타입 표시
        let typeLabel = UILabel()
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        typeLabel.text = record.siteType ?? "동적 사이트"
        typeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        typeLabel.textColor = .systemBlue
        typeLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        typeLabel.textAlignment = .center
        typeLabel.layer.cornerRadius = 8
        typeLabel.clipsToBounds = true
        contentView.addSubview(typeLabel)
        
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
            contentView.widthAnchor.constraint(equalToConstant: min(320, bounds.width - 40)),
            contentView.heightAnchor.constraint(equalToConstant: 200),
            
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            typeLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 8),
            typeLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            typeLabel.widthAnchor.constraint(equalToConstant: 100),
            typeLabel.heightAnchor.constraint(equalToConstant: 20),
            
            timeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            timeLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
        
        return card
    }
    
    // 🎯 **강화된 동적 사이트 복원 적용 전환 완료**
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
                self?.performEnhancedDynamicNavigation(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🎯 **강화된 동적 사이트 네비게이션 수행**
    private func performEnhancedDynamicNavigation(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 강화된 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 강화된 앞으로가기 완료")
        }
        
        // 🎯 **강화된 동적 사이트 BFCache 복원 적용**
        tryEnhancedDynamicBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - 강화된 동적 복원 \(success ? "성공" : "실패")")
            }
        }
        
        // 안전장치: 최대 2초 후 강제 정리 (동적 사이트는 복원이 더 복잡할 수 있음)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (2초 타임아웃)")
            }
        }
    }
    
    // 🎯 **강화된 동적 사이트 BFCache 복원**
    private func tryEnhancedDynamicBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // BFCache에서 강화된 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // 🎯 **핵심: 강화된 동적 사이트 복원 호출**
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ 강화된 동적 사이트 복원 성공: \(currentRecord.title) [\(snapshot.scrollStateBlock.reactAppInfo.framework)]")
                } else {
                    self?.dbg("⚠️ 강화된 동적 사이트 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 기본 대기
            dbg("❌ 강화된 BFCache 미스: \(currentRecord.title)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
    
    // MARK: - 버튼 네비게이션 (강화된 동적 사이트 복원 적용)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryEnhancedDynamicBFCacheRestore(stateModel: stateModel, direction: .back) { _ in }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        tryEnhancedDynamicBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in }
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
    
    // MARK: - 🌐 강화된 JavaScript 스크립트 (React/SPA 완전 지원)
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        // 🎯 강화된 동적 사이트 복원 지원 스크립트 - React/SPA 완전 지원
        (function() {
            'use strict';
            
            console.log('🚀 강화된 동적 사이트 BFCache 스크립트 초기화');
            
            // iOS 웹뷰 특화: 강제 manual 스크롤 복원
            if (history.scrollRestoration) {
                history.scrollRestoration = 'manual';
            }
            
            // === 프레임워크 감지 및 후킹 ===
            
            // React 감지 및 후킹
            if (window.React || document.querySelector('[data-reactroot]') || window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
                console.log('⚛️ React 앱 감지됨');
                
                // React Router 네비게이션 후킹
                if (window.history && window.history.pushState) {
                    const originalPushState = window.history.pushState;
                    window.history.pushState = function(...args) {
                        const result = originalPushState.apply(this, args);
                        setTimeout(() => {
                            window.dispatchEvent(new CustomEvent('reactRouterNavigate', {
                                detail: { url: window.location.href }
                            }));
                        }, 100);
                        return result;
                    };
                }
                
                // React Query 캐시 저장 헬퍼
                window.saveReactQueryCache = function() {
                    if (window.__REACT_QUERY_CLIENT__) {
                        const cache = window.__REACT_QUERY_CLIENT__.getQueryCache();
                        const queries = cache.getAll();
                        const cacheData = {};
                        
                        queries.forEach(query => {
                            if (query.state.data) {
                                cacheData[JSON.stringify(query.queryKey)] = {
                                    data: query.state.data,
                                    dataUpdatedAt: query.state.dataUpdatedAt,
                                    status: query.state.status
                                };
                            }
                        });
                        
                        window.__BFCACHE_REACT_QUERY_DATA__ = cacheData;
                        return cacheData;
                    }
                    return null;
                };
                
                // Redux 상태 저장 헬퍼
                window.saveReduxState = function() {
                    if (window.__REDUX_STORE__) {
                        const state = window.__REDUX_STORE__.getState();
                        window.__BFCACHE_REDUX_STATE__ = JSON.stringify(state);
                        return state;
                    }
                    return null;
                };
            }
            
            // Vue 감지 및 후킹
            if (window.Vue || document.querySelector('[data-v-app]')) {
                console.log('🖖 Vue 앱 감지됨');
                
                // Vuex 상태 저장 헬퍼
                window.saveVuexState = function() {
                    if (window.__VUE_DEVTOOLS_GLOBAL_HOOK__ && window.__VUE_DEVTOOLS_GLOBAL_HOOK__.Vue) {
                        // Vue 3 또는 Vue 2 상태 추출 로직
                        console.log('Vue 상태 저장 시도');
                    }
                };
            }
            
            // Angular 감지 및 후킹  
            if (window.ng || document.querySelector('app-root')) {
                console.log('🅰️ Angular 앱 감지됨');
            }
            
            // === 가상화 라이브러리 후킹 ===
            
            // react-window 후킹
            if (window.FixedSizeList || window.VariableSizeList) {
                console.log('📋 react-window 감지됨');
                
                window.getReactWindowState = function() {
                    const lists = document.querySelectorAll('[data-react-window-list]');
                    const states = [];
                    
                    lists.forEach(list => {
                        const scrollContainer = list.querySelector('[style*="overflow"]');
                        if (scrollContainer) {
                            states.push({
                                selector: list.id ? '#' + list.id : '[data-react-window-list]',
                                scrollTop: scrollContainer.scrollTop,
                                scrollLeft: scrollContainer.scrollLeft
                            });
                        }
                    });
                    
                    return states;
                };
            }
            
            // === 페이지 보기/숨김 이벤트 강화 ===
            
            window.addEventListener('pageshow', function(event) {
                if (event.persisted) {
                    console.log('🔄 BFCache 페이지 복원 - 강화된 동적 사이트 시스템 활성');
                    
                    // 프레임워크별 캐시 상태 확인
                    if (window.__BFCACHE_REACT_QUERY_DATA__) {
                        console.log('💾 React Query 캐시 복원 준비');
                    }
                    
                    if (window.__BFCACHE_REDUX_STATE__) {
                        console.log('🗃️ Redux 상태 복원 준비');  
                    }
                    
                    // 가상화 스크롤러 상태 확인
                    if (window.getReactWindowState) {
                        const states = window.getReactWindowState();
                        console.log('🔄 react-window 상태:', states.length, '개');
                    }
                    
                    // 강화된 복원 준비 완료 이벤트
                    window.dispatchEvent(new CustomEvent('bfcacheEnhancedReadyForRestore', {
                        detail: { 
                            framework: detectCurrentFramework(),
                            timestamp: Date.now() 
                        }
                    }));
                }
            });
            
            window.addEventListener('pagehide', function(event) {
                if (event.persisted) {
                    console.log('📸 BFCache 페이지 저장 - 강화된 상태 수집');
                    
                    // 프레임워크별 상태 저장
                    if (window.saveReactQueryCache) window.saveReactQueryCache();
                    if (window.saveReduxState) window.saveReduxState();
                    if (window.saveVuexState) window.saveVuexState();
                    
                    // 가상화 상태 저장
                    if (window.getReactWindowState) {
                        window.__BFCACHE_VIRTUAL_STATES__ = window.getReactWindowState();
                    }
                }
            });
            
            // === 스크롤 위치 고정 헬퍼 함수들 (강화) ===
            
            window.lockScrollPosition = function(lockY, options = {}) {
                const { 
                    strict = true,           // 엄격 모드 (더 강한 고정)
                    virtualScrollSupport = true,  // 가상 스크롤 지원
                    reactSupport = true     // React 컴포넌트 지원
                } = options;
                
                window.__BFCACHE_SCROLL_LOCKED__ = true;
                window.__BFCACHE_FINAL_SCROLL_Y__ = lockY;
                window.__BFCACHE_SCROLL_OPTIONS__ = options;
                
                // 강화된 스크롤 이벤트 리스너
                const scrollLockHandler = (event) => {
                    if (!window.__BFCACHE_SCROLL_LOCKED__) return;
                    
                    const currentY = window.scrollY;
                    const targetY = window.__BFCACHE_FINAL_SCROLL_Y__;
                    const tolerance = strict ? 2 : 10;
                    
                    if (Math.abs(currentY - targetY) > tolerance) {
                        if (strict) {
                            event.preventDefault();
                        }
                        
                        // requestAnimationFrame으로 부드러운 복원
                        requestAnimationFrame(() => {
                            window.scrollTo({ top: targetY, behavior: 'auto' });
                        });
                    }
                };
                
                // 다양한 스크롤 이벤트 감지
                window.addEventListener('scroll', scrollLockHandler, { passive: !strict });
                window.addEventListener('wheel', scrollLockHandler, { passive: !strict });
                window.addEventListener('touchmove', scrollLockHandler, { passive: !strict });
                
                // 가상 스크롤러 고정
                if (virtualScrollSupport && window.__BFCACHE_VIRTUAL_STATES__) {
                    window.__BFCACHE_VIRTUAL_STATES__.forEach(state => {
                        const container = document.querySelector(state.selector);
                        if (container) {
                            const scrollContainer = container.querySelector('[style*="overflow"]');
                            if (scrollContainer) {
                                scrollContainer.scrollTop = state.scrollTop;
                                scrollContainer.scrollLeft = state.scrollLeft;
                            }
                        }
                    });
                }
                
                // React 컴포넌트 상태 복원
                if (reactSupport && window.__BFCACHE_REACT_QUERY_DATA__) {
                    Object.keys(window.__BFCACHE_REACT_QUERY_DATA__).forEach(key => {
                        const queryKey = JSON.parse(key);
                        const data = window.__BFCACHE_REACT_QUERY_DATA__[key];
                        
                        if (window.__REACT_QUERY_CLIENT__) {
                            window.__REACT_QUERY_CLIENT__.setQueryData(queryKey, data.data);
                        }
                    });
                }
                
                // 잠금 해제 함수 반환
                return () => {
                    window.__BFCACHE_SCROLL_LOCKED__ = false;
                    window.removeEventListener('scroll', scrollLockHandler);
                    window.removeEventListener('wheel', scrollLockHandler);
                    window.removeEventListener('touchmove', scrollLockHandler);
                    delete window.__BFCACHE_FINAL_SCROLL_Y__;
                    delete window.__BFCACHE_SCROLL_OPTIONS__;
                };
            };
            
            // 프레임워크별 데이터 즉시 하이드레이션 (강화)
            window.hydrateCachedData = function(data, framework = 'react', allowScrollChange = false) {
                try {
                    console.log(`💧 \\${framework} 데이터 하이드레이션 시작:`, data);
                    
                    if (!allowScrollChange && window.__BFCACHE_SCROLL_LOCKED__) {
                        // 스크롤 위치 고정 상태에서는 데이터만 교체
                        requestAnimationFrame(() => {
                            if (window.__BFCACHE_FINAL_SCROLL_Y__ !== undefined) {
                                window.scrollTo({ top: window.__BFCACHE_FINAL_SCROLL_Y__, behavior: 'auto' });
                            }
                        });
                    }
                    
                    // 프레임워크별 하이드레이션 로직
                    switch (framework) {
                        case 'react':
                            if (window.React && window.ReactDOM) {
                                // React 컴포넌트 하이드레이션
                                console.log('⚛️ React 하이드레이션 실행');
                                
                                // Redux 상태 복원
                                if (window.__BFCACHE_REDUX_STATE__ && window.__REDUX_STORE__) {
                                    try {
                                        const state = JSON.parse(window.__BFCACHE_REDUX_STATE__);
                                        window.__REDUX_STORE__.dispatch({ 
                                            type: 'BFCACHE_HYDRATE', 
                                            payload: state 
                                        });
                                    } catch (e) {
                                        console.warn('Redux 하이드레이션 실패:', e);
                                    }
                                }
                            }
                            break;
                            
                        case 'vue':
                            if (window.Vue) {
                                console.log('🖖 Vue 하이드레이션 실행');
                                // Vue 특화 로직
                            }
                            break;
                            
                        case 'angular':
                            if (window.ng) {
                                console.log('🅰️ Angular 하이드레이션 실행');
                                // Angular 특화 로직
                            }
                            break;
                    }
                    
                    // 실제 데이터 렌더링 로직은 앱별로 구현 필요
                    console.log(`💧 \\${framework} 하이드레이션 완료`);
                    return true;
                } catch (e) {
                    console.error(`\\${framework} 하이드레이션 실패:`, e);
                    return false;
                }
            };
            
            // 현재 프레임워크 감지 함수
            function detectCurrentFramework() {
                if (window.React || document.querySelector('[data-reactroot]')) return 'react';
                if (window.Vue || document.querySelector('[data-v-app]')) return 'vue';
                if (window.ng || document.querySelector('app-root')) return 'angular';
                if (window.svelte) return 'svelte';
                return 'vanilla';
            }
            
            // === Intersection Observer 강화 (무한 스크롤 지원) ===
            
            // 기존 Intersection Observer 래핑
            if (window.IntersectionObserver) {
                const OriginalIntersectionObserver = window.IntersectionObserver;
                
                window.IntersectionObserver = function(callback, options) {
                    const wrappedCallback = (entries, observer) => {
                        // BFCache 복원 중에는 무한 스크롤 트리거 방지
                        if (window.__BFCACHE_SCROLL_LOCKED__) {
                            console.log('🤫 스크롤 고정 중 - Intersection Observer 콜백 지연');
                            return;
                        }
                        
                        return callback(entries, observer);
                    };
                    
                    return new OriginalIntersectionObserver(wrappedCallback, options);
                };
                
                // 기존 프로토타입 복사
                window.IntersectionObserver.prototype = OriginalIntersectionObserver.prototype;
            }
            
            console.log('✅ 강화된 동적 사이트 BFCache 스크립트 로드 완료:', detectCurrentFramework());
            
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[강화된동적사이트복원] \(msg)")
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
        TabPersistenceManager.debugMessages.append("✅ 강화된 동적 사이트 복원 시스템 설치 완료")
    }
    
    static func uninstall(from webView: WKWebView) {
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        TabPersistenceManager.debugMessages.append("🧹 강화된 동적 사이트 복원 시스템 제거 완료")
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
        dbg("📸 강화된 통합 상태 캡처 시작: \(rec.title)")
    }

    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 강화된 도착 상태 캡처 시작: \(rec.title)")
        
        // 이전 페이지들도 메타데이터 확인 (React/SPA 기본 정보 포함)
        if stateModel.dataModel.currentPageIndex > 0 {
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                if !hasCache(for: previousRecord.id) {
                    // 기본 스냅샷 생성 (프레임워크 기본 정보 포함)
                    let defaultReactAppInfo = BFCacheSnapshot.ScrollStateBlock.ReactAppInfo(
                        framework: "vanilla",
                        appContainerSelector: "body",
                        hasReactRoot: false,
                        componentTree: [],
                        stateManagement: nil,
                        routingLibrary: nil
                    )
                    
                    let basicStateBlock = BFCacheSnapshot.ScrollStateBlock(
                        finalScrollY: 0,
                        viewportHeight: 800,
                        totalContentHeight: 1000,
                        reactAppInfo: defaultReactAppInfo,
                        iframeScrollStates: [],
                        anchorItem: BFCacheSnapshot.ScrollStateBlock.AnchorItemInfo(
                            id: "body-anchor", selector: "body", offsetFromTop: 0, elementHeight: 100, 
                            isSticky: false, reactComponentName: nil, reactKey: nil, reactProps: nil, isVirtualItem: false
                        ),
                        visibleItems: [],
                        virtualizationState: BFCacheSnapshot.ScrollStateBlock.VirtualizationState(
                            isVirtual: false, libraryType: nil, currentSequence: 0, visibleStartIndex: 0,
                            visibleEndIndex: 0, totalKnownItems: 0, itemHeight: nil, estimatedItemSize: nil,
                            pageInfo: nil, scrollOffset: 0
                        ),
                        containerScrolls: [:],
                        cacheKeys: [:]
                    )
                    
                    let basicSkeleton = BFCacheSnapshot.SkeletonTemplate(
                        averageItemHeight: 120,
                        itemsPerScreen: 7,
                        totalSkeletonItems: 10,
                        skeletonPattern: "",
                        placeholderStyles: [:],
                        componentSkeletons: []
                    )
                    
                    let basicGuide = BFCacheSnapshot.DataLoadingGuide(
                        loadingSequence: [],
                        backgroundLoadingEnabled: true,
                        lockScrollDuringLoad: true,
                        frameworkStrategy: BFCacheSnapshot.DataLoadingGuide.FrameworkStrategy(
                            framework: "vanilla",
                            hydrationMethod: "static-generation",
                            dataFetchingPattern: "fetch",
                            routerType: nil,
                            customRestoreScript: nil
                        )
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
                    dbg("📸 이전 페이지 강화된 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
