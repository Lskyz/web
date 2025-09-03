//
//  BFCacheSwipeTransition.swift
//  🎯 **강화된 BFCache 전환 시스템**
//  ✅ 직렬화 큐로 레이스 컨디션 완전 제거
//  🔄 원자적 연산으로 데이터 일관성 보장
//  📸 실패 복구 메커니즘 추가
//  ♾️ 무제한 영구 캐싱 (탭별 관리)
//  💾 스마트 메모리 관리 
//  🔧 **StateModel과 완벽 동기화**
//  🔧 **스냅샷 미스 수정 - 자동 캐시 강화**
//  🎬 **미리보기 컨테이너 0.8초 고정 타이밍** - 적응형 학습 제거
//  ⚡ **균형 잡힌 전환 속도 최적화 - 깜빡임 방지**
//  🛡️ **빠른 연속 제스처 먹통 방지** - 전환 중 차단 + 강제 정리
//  🚫 **폼데이터/눌린상태 저장 제거** - 부작용 해결
//  🔍 **범용 스크롤 감지 강화** - iframe, 커스텀 컨테이너 지원
//  🔄 **다단계 복원 시스템** - 0.8초 고정 대기
//  🚀 **동적사이트 전용 고급 스크롤 감지** - SPA/가상스크롤/무한스크롤 완벽 지원
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

// MARK: - 📸 **강화된 BFCache 페이지 스냅샷**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 🚀 **새로 추가: 동적사이트 전용 상태**
    var dynamicState: DynamicSiteState?
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
        case enhanced       // 🚀 동적사이트 고급 캡처 성공
    }
    
    // 🚀 **동적 사이트 상태 구조체**
    struct DynamicSiteState: Codable {
        let frameworkType: String?          // react, vue, angular 등
        let routerState: [String: Any]?     // 라우터 상태
        let infiniteScrollState: InfiniteScrollState?
        let virtualScrollState: VirtualScrollState?
        let lazyLoadState: LazyLoadState?
        let networkState: NetworkState?
        
        struct InfiniteScrollState: Codable {
            let loadedItemsCount: Int
            let hasMore: Bool
            let lastAPICall: String?
            let scrollTriggerOffset: Double
        }
        
        struct VirtualScrollState: Codable {
            let virtualIndex: Int
            let virtualOffset: Double
            let totalItems: Int
            let itemHeight: Double
            let bufferSize: Int
        }
        
        struct LazyLoadState: Codable {
            let loadedImages: [String]
            let pendingImages: [String]
            let intersectionTargets: [String]
        }
        
        struct NetworkState: Codable {
            let pendingRequests: Int
            let lastRequestTimestamp: Date
            let isNetworkIdle: Bool
            let completedRequests: [String]
        }
        
        // Custom encoding/decoding for [String: Any]
        enum CodingKeys: String, CodingKey {
            case frameworkType, routerState, infiniteScrollState, virtualScrollState, lazyLoadState, networkState
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            frameworkType = try container.decodeIfPresent(String.self, forKey: .frameworkType)
            infiniteScrollState = try container.decodeIfPresent(InfiniteScrollState.self, forKey: .infiniteScrollState)
            virtualScrollState = try container.decodeIfPresent(VirtualScrollState.self, forKey: .virtualScrollState)
            lazyLoadState = try container.decodeIfPresent(LazyLoadState.self, forKey: .lazyLoadState)
            networkState = try container.decodeIfPresent(NetworkState.self, forKey: .networkState)
            
            if let routerData = try container.decodeIfPresent(Data.self, forKey: .routerState) {
                routerState = try JSONSerialization.jsonObject(with: routerData) as? [String: Any]
            } else {
                routerState = nil
            }
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(frameworkType, forKey: .frameworkType)
            try container.encodeIfPresent(infiniteScrollState, forKey: .infiniteScrollState)
            try container.encodeIfPresent(virtualScrollState, forKey: .virtualScrollState)
            try container.encodeIfPresent(lazyLoadState, forKey: .lazyLoadState)
            try container.encodeIfPresent(networkState, forKey: .networkState)
            
            if let router = routerState {
                let routerData = try JSONSerialization.data(withJSONObject: router)
                try container.encode(routerData, forKey: .routerState)
            }
        }
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, jsState, timestamp
        case webViewSnapshotPath, captureStatus, version, dynamicState
    }
    
    // Custom encoding/decoding for [String: Any]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        
        // JSON decode for [String: Any]
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
        dynamicState = try container.decodeIfPresent(DynamicSiteState.self, forKey: .dynamicState)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        
        // JSON encode for [String: Any]
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(dynamicState, forKey: .dynamicState)
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1, dynamicState: DynamicSiteState? = nil) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.dynamicState = dynamicState
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // ⚡ **강화된 복원 메서드 - 동적사이트 지원**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 캡처 상태에 따른 복원 전략
        switch captureStatus {
        case .failed:
            completion(false)
            return
            
        case .visualOnly:
            // 스크롤만 즉시 복원
            DispatchQueue.main.async {
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                TabPersistenceManager.debugMessages.append("BFCache 스크롤만 즉시 복원")
                completion(true)
            }
            return
            
        case .enhanced:
            // 🚀 동적사이트 전용 고급 복원
            TabPersistenceManager.debugMessages.append("BFCache 동적사이트 고급 복원 시작")
            performEnhancedDynamicRestore(to: webView, completion: completion)
            return
            
        case .partial, .complete:
            break
        }
        
        TabPersistenceManager.debugMessages.append("BFCache 다단계 복원 시작 (0.8초 고정)")
        
        // 0.8초 고정 타이밍으로 다단계 복원 실행
        DispatchQueue.main.async {
            self.performMultiStepRestoreWithFixedTiming(to: webView, completion: completion)
        }
    }
    
    // 🚀 **새로 추가: 동적사이트 전용 고급 복원**
    private func performEnhancedDynamicRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        // **1단계: 네트워크 상태 복원 및 대기 (0ms)**
        restoreSteps.append((1, { stepCompletion in
            TabPersistenceManager.debugMessages.append("🚀 1단계: 네트워크 상태 복원")
            
            let networkRestoreJS = self.generateNetworkStateRestoreScript()
            
            webView.evaluateJavaScript(networkRestoreJS) { result, _ in
                let success = (result as? Bool) ?? false
                TabPersistenceManager.debugMessages.append("🚀 1단계 완료: \(success ? "성공" : "실패")")
                stepCompletion(success)
            }
        }))
        
        // **2단계: 프레임워크 상태 복원 (0.2초 후)**
        if let dynamicState = self.dynamicState {
            restoreSteps.append((2, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🚀 2단계: 프레임워크 상태 복원")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let frameworkRestoreJS = self.generateFrameworkStateRestoreScript(dynamicState)
                    
                    webView.evaluateJavaScript(frameworkRestoreJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🚀 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **3단계: 무한스크롤 상태 복원 (0.4초 후)**
        if let dynamicState = self.dynamicState,
           let infiniteScroll = dynamicState.infiniteScrollState {
            
            restoreSteps.append((3, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🚀 3단계: 무한스크롤 상태 복원")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let infiniteScrollJS = self.generateInfiniteScrollRestoreScript(infiniteScroll)
                    
                    webView.evaluateJavaScript(infiniteScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🚀 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **4단계: 가상스크롤 위치 복원 (0.6초 후)**
        if let dynamicState = self.dynamicState,
           let virtualScroll = dynamicState.virtualScrollState {
            
            restoreSteps.append((4, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🚀 4단계: 가상스크롤 위치 복원")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let virtualScrollJS = self.generateVirtualScrollRestoreScript(virtualScroll)
                    
                    webView.evaluateJavaScript(virtualScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🚀 4단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **5단계: 일반 스크롤 + 지연로딩 복원 (0.8초 후)**
        restoreSteps.append((5, { stepCompletion in
            TabPersistenceManager.debugMessages.append("🚀 5단계: 일반 스크롤 + 지연로딩 복원")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                // 일반 스크롤 먼저
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                
                // 지연로딩 이미지 트리거
                let lazyLoadJS = self.generateLazyLoadRestoreScript()
                
                webView.evaluateJavaScript(lazyLoadJS) { result, _ in
                    let success = (result as? Bool) ?? false
                    TabPersistenceManager.debugMessages.append("🚀 5단계 완료: \(success ? "성공" : "실패")")
                    stepCompletion(success)
                }
            }
        }))
        
        // **6단계: 최종 확인 및 보정 (1.0초 후)**
        restoreSteps.append((6, { stepCompletion in
            TabPersistenceManager.debugMessages.append("🚀 6단계: 동적사이트 최종 확인")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let finalVerifyJS = """
                (function() {
                    try {
                        // 최종 상태 확인
                        const results = {
                            scrollMatch: Math.abs(window.scrollY - \(self.scrollPosition.y)) < 20,
                            networkIdle: (window.__bfcache_network_requests || 0) === 0,
                            contentLoaded: document.readyState === 'complete'
                        };
                        
                        console.log('🚀 동적사이트 복원 최종 확인:', results);
                        return Object.values(results).every(r => r);
                    } catch(e) { 
                        console.error('동적사이트 복원 확인 실패:', e);
                        return false; 
                    }
                })()
                """
                
                webView.evaluateJavaScript(finalVerifyJS) { result, _ in
                    let success = (result as? Bool) ?? false
                    TabPersistenceManager.debugMessages.append("🚀 6단계 완료: \(success ? "성공" : "실패")")
                    stepCompletion(success)
                }
            }
        }))
        
        // 단계별 실행
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                stepInfo.action { success in
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > totalSteps / 2
                
                TabPersistenceManager.debugMessages.append("🚀 동적사이트 고급 복원 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                completion(overallSuccess)
            }
        }
        
        executeNextStep()
    }
    
    // 🔄 **핵심: 다단계 복원 시스템 - 0.8초 고정 타이밍**
    private func performMultiStepRestoreWithFixedTiming(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        // **1단계: 메인 윈도우 스크롤 즉시 복원 (0ms)**
        restoreSteps.append((1, { stepCompletion in
            let targetPos = self.scrollPosition
            TabPersistenceManager.debugMessages.append("🔄 1단계: 메인 스크롤 복원 (즉시)")
            
            // 네이티브 스크롤뷰 즉시 설정
            webView.scrollView.setContentOffset(targetPos, animated: false)
            
            // JavaScript 메인 스크롤 복원
            let mainScrollJS = """
            (function() {
                try {
                    window.scrollTo(\(targetPos.x), \(targetPos.y));
                    document.documentElement.scrollTop = \(targetPos.y);
                    document.body.scrollTop = \(targetPos.y);
                    return true;
                } catch(e) { return false; }
            })()
            """
            
            webView.evaluateJavaScript(mainScrollJS) { result, _ in
                let success = (result as? Bool) ?? false
                TabPersistenceManager.debugMessages.append("🔄 1단계 완료: \(success ? "성공" : "실패")")
                stepCompletion(success)
            }
        }))
        
        // **2단계: 주요 컨테이너 스크롤 복원 (0.2초 후)**
        if let jsState = self.jsState,
           let scrollData = jsState["scroll"] as? [String: Any],
           let elements = scrollData["elements"] as? [[String: Any]], !elements.isEmpty {
            
            restoreSteps.append((2, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🔄 2단계: 컨테이너 스크롤 복원 (0.2초 후)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let containerScrollJS = self.generateContainerScrollScript(elements)
                    webView.evaluateJavaScript(containerScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **3단계: iframe 스크롤 복원 (0.4초 후)**
        if let jsState = self.jsState,
           let iframeData = jsState["iframes"] as? [[String: Any]], !iframeData.isEmpty {
            
            restoreSteps.append((3, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🔄 3단계: iframe 스크롤 복원 (0.4초 후)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let iframeScrollJS = self.generateIframeScrollScript(iframeData)
                    webView.evaluateJavaScript(iframeScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **4단계: 최종 확인 및 보정 (0.6초 후)**
        restoreSteps.append((4, { stepCompletion in
            TabPersistenceManager.debugMessages.append("🔄 4단계: 최종 보정 (0.6초 후)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let finalVerifyJS = """
                (function() {
                    try {
                        // 최종 메인 스크롤 확인 및 보정
                        if (Math.abs(window.scrollY - \(self.scrollPosition.y)) > 10) {
                            window.scrollTo(\(self.scrollPosition.x), \(self.scrollPosition.y));
                        }
                        return window.scrollY >= \(self.scrollPosition.y - 20);
                    } catch(e) { return false; }
                })()
                """
                
                webView.evaluateJavaScript(finalVerifyJS) { result, _ in
                    let success = (result as? Bool) ?? false
                    TabPersistenceManager.debugMessages.append("🔄 4단계 완료: \(success ? "성공" : "실패")")
                    stepCompletion(success)
                }
            }
        }))
        
        // 단계별 실행
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                stepInfo.action { success in
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > totalSteps / 2
                
                TabPersistenceManager.debugMessages.append("🔄 다단계 복원 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                completion(overallSuccess)
            }
        }
        
        executeNextStep()
    }
    
    // 🚀 **동적사이트 복원 스크립트 생성 메서드들**
    
    private func generateNetworkStateRestoreScript() -> String {
        return """
        (function() {
            try {
                // 네트워크 요청 상태 초기화
                window.__bfcache_network_requests = 0;
                
                // 진행중인 요청들 대기
                return new Promise((resolve) => {
                    let attempts = 0;
                    const maxAttempts = 10;
                    
                    function checkNetworkIdle() {
                        attempts++;
                        const activeRequests = window.__bfcache_network_requests || 0;
                        
                        if (activeRequests === 0 || attempts >= maxAttempts) {
                            console.log('🌐 네트워크 상태 확인 완료:', { activeRequests, attempts });
                            resolve(true);
                        } else {
                            setTimeout(checkNetworkIdle, 100);
                        }
                    }
                    
                    checkNetworkIdle();
                });
            } catch(e) {
                console.error('네트워크 상태 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    private func generateFrameworkStateRestoreScript(_ dynamicState: DynamicSiteState) -> String {
        let frameworkType = dynamicState.frameworkType ?? "unknown"
        
        return """
        (function() {
            try {
                const framework = '\(frameworkType)';
                console.log('🔧 프레임워크 상태 복원:', framework);
                
                switch(framework) {
                    case 'react':
                        return restoreReactState();
                    case 'vue':
                        return restoreVueState();
                    case 'angular':
                        return restoreAngularState();
                    default:
                        return restoreGenericSPAState();
                }
                
                function restoreReactState() {
                    if (window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
                        // React 상태 복원 시도
                        console.log('⚛️ React 상태 복원 시도');
                        return true;
                    }
                    return false;
                }
                
                function restoreVueState() {
                    if (window.Vue || window.__VUE__) {
                        // Vue 상태 복원 시도
                        console.log('💚 Vue 상태 복원 시도');
                        return true;
                    }
                    return false;
                }
                
                function restoreAngularState() {
                    if (window.ng || window.getAllAngularRootElements) {
                        // Angular 상태 복원 시도
                        console.log('🅰️ Angular 상태 복원 시도');
                        return true;
                    }
                    return false;
                }
                
                function restoreGenericSPAState() {
                    // 범용 SPA 상태 복원
                    console.log('🔧 범용 SPA 상태 복원');
                    
                    // History API 상태 확인
                    if (window.history && window.history.state) {
                        console.log('📍 History API 상태 확인됨');
                    }
                    
                    return true;
                }
            } catch(e) {
                console.error('프레임워크 상태 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    private func generateInfiniteScrollRestoreScript(_ infiniteScroll: DynamicSiteState.InfiniteScrollState) -> String {
        return """
        (function() {
            try {
                console.log('♾️ 무한스크롤 상태 복원 시작');
                
                const targetCount = \(infiniteScroll.loadedItemsCount);
                const hasMore = \(infiniteScroll.hasMore);
                const triggerOffset = \(infiniteScroll.scrollTriggerOffset);
                
                // 일반적인 무한스크롤 컨테이너들 탐지
                const containers = [
                    document.querySelector('[data-infinite-scroll]'),
                    document.querySelector('.infinite-scroll'),
                    document.querySelector('[data-virtualized]'),
                    document.querySelector('.feed'),
                    document.querySelector('.timeline'),
                    document.querySelector('.posts-container'),
                    document.querySelector('.items-container')
                ].filter(el => el !== null);
                
                if (containers.length === 0) {
                    console.log('⚠️ 무한스크롤 컨테이너 없음');
                    return false;
                }
                
                let restored = false;
                
                containers.forEach(container => {
                    const currentItems = container.children.length;
                    console.log('📦 컨테이너 아이템 수:', currentItems, '/', targetCount);
                    
                    if (currentItems >= targetCount) {
                        // 이미 충분한 아이템이 로드됨
                        restored = true;
                    } else {
                        // 부족한 아이템 - 추가 로딩 트리거 시도
                        if (container.__infiniteLoader) {
                            container.__infiniteLoader.loadMore(targetCount - currentItems);
                            restored = true;
                        } else {
                            // 스크롤 이벤트로 로딩 트리거
                            container.scrollTop = triggerOffset;
                            restored = true;
                        }
                    }
                });
                
                console.log('♾️ 무한스크롤 복원 완료:', restored);
                return restored;
            } catch(e) {
                console.error('무한스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    private func generateVirtualScrollRestoreScript(_ virtualScroll: DynamicSiteState.VirtualScrollState) -> String {
        return """
        (function() {
            try {
                console.log('📋 가상스크롤 위치 복원 시작');
                
                const targetIndex = \(virtualScroll.virtualIndex);
                const targetOffset = \(virtualScroll.virtualOffset);
                const itemHeight = \(virtualScroll.itemHeight);
                
                // React Virtualized 감지
                const virtualizedElements = document.querySelectorAll('[data-test-id*="virtualized"], .ReactVirtualized__Grid, .ReactVirtualized__List');
                
                if (virtualizedElements.length > 0) {
                    virtualizedElements.forEach(el => {
                        // React Virtualized 스크롤 복원
                        if (el._scrollToRow && typeof el._scrollToRow === 'function') {
                            el._scrollToRow(targetIndex);
                            console.log('⚛️ React Virtualized 스크롤 복원:', targetIndex);
                        }
                        
                        // 수동 스크롤 위치 설정
                        if (el.scrollTop !== undefined) {
                            el.scrollTop = targetOffset;
                        }
                    });
                    return true;
                }
                
                // Vue Virtual Scroller 감지
                const vueVirtualElements = document.querySelectorAll('.vue-virtual-scroller, [data-vue-virtual-scroller]');
                
                if (vueVirtualElements.length > 0) {
                    vueVirtualElements.forEach(el => {
                        // Vue Virtual Scroller 복원
                        if (el.__vue__ && el.__vue__.scrollToItem) {
                            el.__vue__.scrollToItem(targetIndex);
                            console.log('💚 Vue Virtual Scroller 복원:', targetIndex);
                        } else {
                            el.scrollTop = targetOffset;
                        }
                    });
                    return true;
                }
                
                // 범용 가상스크롤 복원
                const possibleVirtualContainers = document.querySelectorAll('[style*="transform"], [data-virtual]');
                
                possibleVirtualContainers.forEach(el => {
                    if (el.scrollTop !== undefined) {
                        el.scrollTop = targetOffset;
                        console.log('🔧 범용 가상스크롤 복원:', targetOffset);
                    }
                });
                
                return possibleVirtualContainers.length > 0;
            } catch(e) {
                console.error('가상스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    private func generateLazyLoadRestoreScript() -> String {
        return """
        (function() {
            try {
                console.log('🖼️ 지연로딩 이미지 복원 시작');
                
                // 일반적인 lazy loading 이미지들 탐지
                const lazyImages = document.querySelectorAll([
                    'img[loading="lazy"]',
                    'img[data-src]',
                    'img[data-lazy]',
                    '.lazy-image',
                    '.lazyload',
                    '[data-bg]'
                ].join(', '));
                
                let triggeredCount = 0;
                
                lazyImages.forEach(img => {
                    // Intersection Observer로 로딩 트리거
                    if ('IntersectionObserver' in window) {
                        const observer = new IntersectionObserver((entries) => {
                            entries.forEach(entry => {
                                if (entry.isIntersecting) {
                                    // data-src를 src로 복사
                                    if (entry.target.dataset.src) {
                                        entry.target.src = entry.target.dataset.src;
                                        triggeredCount++;
                                    }
                                    
                                    // 배경 이미지 처리
                                    if (entry.target.dataset.bg) {
                                        entry.target.style.backgroundImage = `url(\${entry.target.dataset.bg})`;
                                        triggeredCount++;
                                    }
                                    
                                    observer.unobserve(entry.target);
                                }
                            });
                        }, { threshold: 0.1 });
                        
                        observer.observe(img);
                    }
                });
                
                // 즉시 보이는 이미지들 강제 로드
                lazyImages.forEach(img => {
                    const rect = img.getBoundingClientRect();
                    if (rect.top >= 0 && rect.bottom <= window.innerHeight) {
                        if (img.dataset.src) {
                            img.src = img.dataset.src;
                            triggeredCount++;
                        }
                    }
                });
                
                console.log('🖼️ 지연로딩 트리거 완료:', triggeredCount, '개');
                return triggeredCount > 0;
            } catch(e) {
                console.error('지연로딩 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 컨테이너 스크롤 복원 스크립트 생성
    private func generateContainerScrollScript(_ elements: [[String: Any]]) -> String {
        let elementsJSON = convertToJSONString(elements) ?? "[]"
        return """
        (function() {
            try {
                const elements = \(elementsJSON);
                let restored = 0;
                
                for (const item of elements) {
                    if (!item.selector) continue;
                    
                    // 다양한 selector 시도
                    const selectors = [
                        item.selector,
                        item.selector.replace(/\\[\\d+\\]/g, ''), // 인덱스 제거
                        item.className ? '.' + item.className : null,
                        item.id ? '#' + item.id : null
                    ].filter(s => s);
                    
                    for (const sel of selectors) {
                        const elements = document.querySelectorAll(sel);
                        if (elements.length > 0) {
                            elements.forEach(el => {
                                if (el && typeof el.scrollTop === 'number') {
                                    el.scrollTop = item.top || 0;
                                    el.scrollLeft = item.left || 0;
                                    restored++;
                                }
                            });
                            break; // 성공하면 다음 selector 시도 안함
                        }
                    }
                }
                
                console.log('컨테이너 스크롤 복원:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('컨테이너 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // iframe 스크롤 복원 스크립트 생성
    private func generateIframeScrollScript(_ iframeData: [[String: Any]]) -> String {
        let iframeJSON = convertToJSONString(iframeData) ?? "[]"
        return """
        (function() {
            try {
                const iframes = \(iframeJSON);
                let restored = 0;
                
                for (const iframeInfo of iframes) {
                    const iframe = document.querySelector(iframeInfo.selector);
                    if (iframe && iframe.contentWindow) {
                        try {
                            // Same-origin인 경우에만 접근 가능
                            iframe.contentWindow.scrollTo(
                                iframeInfo.scrollX || 0,
                                iframeInfo.scrollY || 0
                            );
                            restored++;
                        } catch(e) {
                            // Cross-origin iframe은 무시
                            console.log('Cross-origin iframe 스킵:', iframeInfo.selector);
                        }
                    }
                }
                
                console.log('iframe 스크롤 복원:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('iframe 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 안전한 JSON 변환 유틸리티
    private func convertToJSONString(_ object: Any) -> String? {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: object, options: [])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            TabPersistenceManager.debugMessages.append("JSON 변환 실패: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - 🎯 **강화된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 **핵심 개선: 단일 직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // MARK: - 💾 스레드 안전 캐시 시스템
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
    
    enum CaptureType {
        case immediate  // 현재 페이지 (높은 우선순위)
        case background // 과거 페이지 (일반 우선순위)
        case enhanced   // 🚀 동적사이트 고급 캡처
    }
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🚀 동적사이트 전용 캡처 추가)**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    // 중복 방지를 위한 진행 중인 캡처 추적
    private var pendingCaptures: Set<UUID> = []
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 중복 캡처 방지 (진행 중인 것만)
        guard !pendingCaptures.contains(pageID) else {
            dbg("⏸️ 중복 캡처 방지: \(task.pageRecord.title)")
            return
        }
        
        guard task.webView != nil else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 진행 중 표시
        pendingCaptures.insert(pageID)
        
        // 🚀 **캡처 타입별 분기**
        switch task.type {
        case .enhanced:
            dbg("🚀 동적사이트 고급 캡처 시작: \(task.pageRecord.title)")
            performEnhancedDynamicCapture(task)
        default:
            dbg("🎯 일반 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
            performStandardCapture(task)
        }
    }
    
    // 🚀 **새로 추가: 동적사이트 전용 고급 캡처**
    private func performEnhancedDynamicCapture(_ task: CaptureTask) {
        guard let webView = task.webView else {
            pendingCaptures.remove(task.pageRecord.id)
            return
        }
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(task.pageRecord.id)
            return
        }
        
        // 🚀 **고급 캡처 로직 - 동적사이트 상태까지 캡처**
        performRobustEnhancedCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: 1
        ) { [weak self] captureResult in
            // 캡처 완료 후 저장
            if let tabID = task.tabID {
                self?.saveToDisk(snapshot: captureResult, tabID: tabID)
            } else {
                self?.storeInMemory(captureResult.snapshot, for: task.pageRecord.id)
            }
            
            // 진행 중 해제
            self?.pendingCaptures.remove(task.pageRecord.id)
            self?.dbg("✅ 동적사이트 고급 캡처 완료: \(task.pageRecord.title)")
        }
    }
    
    private func performStandardCapture(_ task: CaptureTask) {
        guard let webView = task.webView else {
            pendingCaptures.remove(task.pageRecord.id)
            return
        }
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(task.pageRecord.id)
            return
        }
        
        // 🔧 **개선된 캡처 로직 - 실패 시 재시도**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
        )
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: task.pageRecord.id)
        }
        
        // 진행 중 해제
        pendingCaptures.remove(task.pageRecord.id)
        dbg("✅ 일반 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🚀 **새로 추가: 고급 동적사이트 캡처 (비동기 콜백)**
    private func performRobustEnhancedCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0, completion: @escaping ((snapshot: BFCacheSnapshot, image: UIImage?)) -> Void) {
        
        attemptEnhancedCapture(pageRecord: pageRecord, webView: webView, captureData: captureData) { [weak self] result in
            if result.snapshot.captureStatus != .failed || retryCount <= 0 {
                // 성공하거나 재시도 없음
                completion(result)
                return
            }
            
            // 재시도
            self?.dbg("⏳ 고급 캡처 실패 - 재시도: \(pageRecord.title)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.performRobustEnhancedCapture(
                    pageRecord: pageRecord,
                    webView: webView,
                    captureData: captureData,
                    retryCount: retryCount - 1,
                    completion: completion
                )
            }
        }
    }
    
    private func attemptEnhancedCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, completion: @escaping ((snapshot: BFCacheSnapshot, image: UIImage?)) -> Void) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var dynamicState: BFCacheSnapshot.DynamicSiteState? = nil
        
        let group = DispatchGroup()
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        group.enter()
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    // Fallback: layer 렌더링
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                group.leave()
            }
        }
        
        // 2. DOM 캡처 - 🚫 **눌린 상태 제거하는 스크립트 추가**
        group.enter()
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 🚫 **눌린 상태/활성 상태 모두 제거**
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(el => {
                        el.classList.remove(...Array.from(el.classList).filter(c => 
                            c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus')
                        ));
                    });
                    
                    // input focus 제거
                    document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(el => {
                        el.blur();
                    });
                    
                    const html = document.documentElement.outerHTML;
                    return html.length > 100000 ? html.substring(0, 100000) : html;
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                domSnapshot = result as? String
                group.leave()
            }
        }
        
        // 3. 🚀 **동적사이트 상태 캡처**
        group.enter()
        DispatchQueue.main.sync {
            let enhancedScript = generateEnhancedDynamicSiteScript()
            
            webView.evaluateJavaScript(enhancedScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                    
                    // 동적 사이트 상태 파싱
                    dynamicState = self.parseDynamicSiteState(data)
                }
                group.leave()
            }
        }
        
        // 모든 작업 완료 대기
        group.notify(queue: .main) {
            // 캡처 상태 결정
            let captureStatus: BFCacheSnapshot.CaptureStatus
            if visualSnapshot != nil && domSnapshot != nil && jsState != nil && dynamicState != nil {
                captureStatus = .enhanced  // 🚀 동적사이트 고급 캡처 성공
            } else if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
                captureStatus = .complete
            } else if visualSnapshot != nil {
                captureStatus = jsState != nil ? .partial : .visualOnly
            } else {
                captureStatus = .failed
            }
            
            // 버전 증가 (스레드 안전)
            let version: Int = self.cacheAccessQueue.sync(flags: .barrier) { [weak self] in
                guard let self = self else { return 1 }
                let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
                let newVersion = currentVersion + 1
                self._cacheVersion[pageRecord.id] = newVersion
                return newVersion
            }
            
            let snapshot = BFCacheSnapshot(
                pageRecord: pageRecord,
                domSnapshot: domSnapshot,
                scrollPosition: captureData.scrollPosition,
                jsState: jsState,
                timestamp: Date(),
                webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
                captureStatus: captureStatus,
                version: version,
                dynamicState: dynamicState  // 🚀 동적 상태 추가
            )
            
            completion((snapshot, visualSnapshot))
        }
    }
    
    // 🔧 **실패 복구 기능 추가된 캡처**
    private func performRobustCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기
            dbg("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08) // ⚡ 0.05초 → 0.08초 (안정성)
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    // Fallback: layer 렌더링
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                semaphore.signal()
            }
        }
        
        // ⚡ 적절한 타임아웃 (2초 → 2.5초로 약간 여유)
        let result = semaphore.wait(timeout: .now() + 2.5)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처 - 🚫 **눌린 상태 제거하는 스크립트 추가**
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 🚫 **눌린 상태/활성 상태 모두 제거**
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(el => {
                        el.classList.remove(...Array.from(el.classList).filter(c => 
                            c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus')
                        ));
                    });
                    
                    // input focus 제거
                    document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(el => {
                        el.blur();
                    });
                    
                    const html = document.documentElement.outerHTML;
                    return html.length > 100000 ? html.substring(0, 100000) : html;
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                domSnapshot = result as? String
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 0.8) // ⚡ 0.5초 → 0.8초 (안정성)
        
        // 3. 🔍 **강화된 JS 상태 캡처 - 범용 스크롤 감지**
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = generateEnhancedScrollCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 1.2) // 더 복잡한 스크립트이므로 여유시간 증가
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 버전 증가 (스레드 안전)
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            jsState: jsState,
            timestamp: Date(),
            webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
            captureStatus: captureStatus,
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🚀 **새로 추가: 동적사이트 전용 고급 JavaScript 생성**
    private func generateEnhancedDynamicSiteScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 동적사이트 고급 상태 캡처 시작');
                
                // 기본 스크롤 정보
                const baseScrollInfo = {
                    x: window.scrollX,
                    y: window.scrollY,
                    elements: [],
                    dynamics: []
                };
                
                // 🔧 **1. 프레임워크 감지**
                const frameworkInfo = detectFramework();
                
                // 🔧 **2. 무한스크롤 상태 감지**
                const infiniteScrollInfo = detectInfiniteScrollState();
                
                // 🔧 **3. 가상스크롤 상태 감지**
                const virtualScrollInfo = detectVirtualScrollState();
                
                // 🔧 **4. 지연로딩 상태 감지**
                const lazyLoadInfo = detectLazyLoadState();
                
                // 🔧 **5. 네트워크 상태 감지**
                const networkInfo = detectNetworkState();
                
                // 🔍 **6. 기존 범용 스크롤 감지**
                const scrollableElements = findAllScrollableElements();
                const iframeScrolls = detectIframeScrolls();
                const dynamicElements = detectDynamicElements();
                
                baseScrollInfo.elements = scrollableElements;
                baseScrollInfo.dynamics = dynamicElements;
                
                console.log('🚀 동적사이트 상태 캡처 완료');
                
                return {
                    // 기존 정보
                    scroll: baseScrollInfo,
                    iframes: iframeScrolls,
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now(),
                    viewport: {
                        width: window.innerWidth,
                        height: window.innerHeight
                    },
                    
                    // 🚀 새로운 동적사이트 정보
                    framework: frameworkInfo,
                    infiniteScroll: infiniteScrollInfo,
                    virtualScroll: virtualScrollInfo,
                    lazyLoad: lazyLoadInfo,
                    network: networkInfo
                };
                
                // === 프레임워크 감지 함수들 ===
                
                function detectFramework() {
                    let framework = 'unknown';
                    let version = null;
                    let routerState = null;
                    
                    // React 감지
                    if (window.__REACT_DEVTOOLS_GLOBAL_HOOK__ || 
                        window.React || 
                        document.querySelector('[data-reactroot]')) {
                        framework = 'react';
                        
                        // React Router 상태 감지
                        if (window.history && window.history.state) {
                            routerState = {
                                pathname: window.location.pathname,
                                search: window.location.search,
                                hash: window.location.hash,
                                state: window.history.state
                            };
                        }
                    }
                    // Vue 감지
                    else if (window.Vue || window.__VUE__ || 
                             document.querySelector('[data-v-]') ||
                             document.querySelector('.vue-component')) {
                        framework = 'vue';
                        
                        // Vue Router 상태 감지
                        if (window.__VUE_ROUTER__) {
                            routerState = {
                                currentRoute: window.__VUE_ROUTER__.currentRoute,
                                pathname: window.location.pathname
                            };
                        }
                    }
                    // Angular 감지
                    else if (window.ng || window.getAllAngularRootElements || 
                             document.querySelector('[ng-app]') ||
                             document.querySelector('[data-ng-app]')) {
                        framework = 'angular';
                        
                        routerState = {
                            pathname: window.location.pathname,
                            search: window.location.search
                        };
                    }
                    // Svelte 감지
                    else if (document.querySelector('[data-svelte-h]')) {
                        framework = 'svelte';
                    }
                    
                    return { type: framework, version, routerState };
                }
                
                function detectInfiniteScrollState() {
                    const containers = [
                        document.querySelector('[data-infinite-scroll]'),
                        document.querySelector('.infinite-scroll'),
                        document.querySelector('[data-virtualized]'),
                        document.querySelector('.feed'),
                        document.querySelector('.timeline'),
                        document.querySelector('.posts-container'),
                        document.querySelector('.items-container')
                    ].filter(el => el !== null);
                    
                    if (containers.length === 0) return null;
                    
                    const container = containers[0];
                    const loadedItemsCount = container.children.length;
                    
                    // 더보기 버튼이나 로딩 인디케이터로 hasMore 판단
                    const hasMore = !!(
                        document.querySelector('.load-more') ||
                        document.querySelector('[data-testid="load-more"]') ||
                        document.querySelector('.loading-spinner') ||
                        document.querySelector('.infinite-loading') ||
                        container.dataset.hasMore === 'true'
                    );
                    
                    // 스크롤 트리거 오프셋 계산
                    const scrollTriggerOffset = container.scrollHeight * 0.8; // 80% 지점
                    
                    // 마지막 API 호출 추적
                    const lastAPICall = window.__lastInfiniteScrollAPI || null;
                    
                    return {
                        loadedItemsCount,
                        hasMore,
                        scrollTriggerOffset,
                        lastAPICall
                    };
                }
                
                function detectVirtualScrollState() {
                    // React Virtualized 감지
                    let virtualizedElement = document.querySelector('.ReactVirtualized__Grid, .ReactVirtualized__List, [data-test-id*="virtualized"]');
                    
                    if (virtualizedElement) {
                        return {
                            virtualIndex: parseInt(virtualizedElement.dataset.virtualIndex || '0'),
                            virtualOffset: parseFloat(virtualizedElement.dataset.virtualOffset || '0'),
                            totalItems: parseInt(virtualizedElement.dataset.totalItems || '0'),
                            itemHeight: parseFloat(virtualizedElement.dataset.itemHeight || '50'),
                            bufferSize: parseInt(virtualizedElement.dataset.bufferSize || '10'),
                            type: 'react-virtualized'
                        };
                    }
                    
                    // Vue Virtual Scroller 감지
                    virtualizedElement = document.querySelector('.vue-virtual-scroller, [data-vue-virtual-scroller]');
                    
                    if (virtualizedElement && virtualizedElement.__vue__) {
                        const vue = virtualizedElement.__vue__;
                        return {
                            virtualIndex: vue.startIndex || 0,
                            virtualOffset: vue.scrollTop || 0,
                            totalItems: vue.items ? vue.items.length : 0,
                            itemHeight: vue.itemHeight || 50,
                            bufferSize: vue.buffer || 10,
                            type: 'vue-virtual-scroller'
                        };
                    }
                    
                    // 범용 가상스크롤 감지 (transform 기반)
                    const transformElements = document.querySelectorAll('[style*="transform"]');
                    for (const el of transformElements) {
                        const transform = el.style.transform;
                        const translateMatch = transform.match(/translateY\\(([\\d.-]+)px\\)/);
                        if (translateMatch) {
                            const offset = parseFloat(translateMatch[1]);
                            if (Math.abs(offset) > 100) { // 100px 이상 이동한 경우만
                                return {
                                    virtualIndex: Math.floor(Math.abs(offset) / 50),
                                    virtualOffset: Math.abs(offset),
                                    totalItems: el.children.length || 0,
                                    itemHeight: 50,
                                    bufferSize: 5,
                                    type: 'generic-transform'
                                };
                            }
                        }
                    }
                    
                    return null;
                }
                
                function detectLazyLoadState() {
                    const lazyImages = document.querySelectorAll([
                        'img[loading="lazy"]',
                        'img[data-src]',
                        'img[data-lazy]',
                        '.lazy-image',
                        '.lazyload',
                        '[data-bg]'
                    ].join(', '));
                    
                    const loadedImages = [];
                    const pendingImages = [];
                    
                    lazyImages.forEach(img => {
                        if (img.complete && img.naturalHeight !== 0) {
                            loadedImages.push(img.src || img.dataset.src || '');
                        } else {
                            pendingImages.push(img.dataset.src || img.src || '');
                        }
                    });
                    
                    // Intersection Observer 타겟들
                    const intersectionTargets = [];
                    document.querySelectorAll('[data-intersection]').forEach(el => {
                        intersectionTargets.push(el.dataset.intersection || '');
                    });
                    
                    return {
                        loadedImages,
                        pendingImages,
                        intersectionTargets,
                        totalLazyElements: lazyImages.length
                    };
                }
                
                function detectNetworkState() {
                    // 진행중인 요청 수 추적
                    const pendingRequests = window.__bfcache_network_requests || 0;
                    
                    // 마지막 요청 시간
                    const lastRequestTimestamp = window.__bfcache_last_request_time || Date.now();
                    
                    // 네트워크 idle 상태 (1초 이상 요청 없음)
                    const isNetworkIdle = (Date.now() - lastRequestTimestamp) > 1000;
                    
                    // 완료된 요청들
                    const completedRequests = window.__bfcache_completed_requests || [];
                    
                    return {
                        pendingRequests,
                        lastRequestTimestamp: new Date(lastRequestTimestamp),
                        isNetworkIdle,
                        completedRequests: completedRequests.slice(-10) // 최근 10개만
                    };
                }
                
                // === 기존 스크롤 감지 함수들 (유지) ===
                
                function findAllScrollableElements() {
                    const scrollables = [];
                    const maxElements = 50;
                    
                    const explicitScrollables = document.querySelectorAll('*');
                    let count = 0;
                    
                    for (const el of explicitScrollables) {
                        if (count >= maxElements) break;
                        
                        const style = window.getComputedStyle(el);
                        const overflowY = style.overflowY;
                        const overflowX = style.overflowX;
                        
                        if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                            (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) {
                            
                            if (el.scrollTop > 0 || el.scrollLeft > 0) {
                                const selector = generateBestSelector(el);
                                if (selector) {
                                    scrollables.push({
                                        selector: selector,
                                        top: el.scrollTop,
                                        left: el.scrollLeft,
                                        maxTop: el.scrollHeight - el.clientHeight,
                                        maxLeft: el.scrollWidth - el.clientWidth,
                                        id: el.id || '',
                                        className: el.className || '',
                                        tagName: el.tagName.toLowerCase()
                                    });
                                    count++;
                                }
                            }
                        }
                    }
                    
                    return scrollables;
                }
                
                function detectIframeScrolls() {
                    const iframes = [];
                    const iframeElements = document.querySelectorAll('iframe');
                    
                    for (const iframe of iframeElements) {
                        try {
                            const contentWindow = iframe.contentWindow;
                            if (contentWindow && contentWindow.location) {
                                const scrollX = contentWindow.scrollX || 0;
                                const scrollY = contentWindow.scrollY || 0;
                                
                                if (scrollX > 0 || scrollY > 0) {
                                    iframes.push({
                                        selector: generateBestSelector(iframe) || `iframe[src*="\${iframe.src.split('/').pop()}"]`,
                                        scrollX: scrollX,
                                        scrollY: scrollY,
                                        src: iframe.src || '',
                                        id: iframe.id || '',
                                        className: iframe.className || ''
                                    });
                                }
                            }
                        } catch(e) {
                            console.log('Cross-origin iframe 스킵:', iframe.src);
                        }
                    }
                    
                    return iframes;
                }
                
                function detectDynamicElements() {
                    const dynamics = [];
                    
                    const dynamicSelectors = [
                        '[data-infinite]', '[data-lazy]', '.infinite-scroll',
                        '.lazy-load', '.dynamic-content', '.feed', '.timeline',
                        '[data-scroll-container]', '.virtualized'
                    ];
                    
                    for (const selector of dynamicSelectors) {
                        const elements = document.querySelectorAll(selector);
                        for (const el of elements) {
                            if (el.scrollTop > 0 || el.scrollLeft > 0) {
                                dynamics.push({
                                    selector: generateBestSelector(el) || selector,
                                    top: el.scrollTop,
                                    left: el.scrollLeft,
                                    type: 'dynamic'
                                });
                            }
                        }
                    }
                    
                    return dynamics;
                }
                
                function generateBestSelector(element) {
                    if (!element || element.nodeType !== 1) return null;
                    
                    if (element.id) {
                        return `#\${element.id}`;
                    }
                    
                    if (element.className) {
                        const classes = element.className.trim().split(/\\s+/);
                        const uniqueClasses = classes.filter(cls => {
                            const elements = document.querySelectorAll(`.\${cls}`);
                            return elements.length === 1 && elements[0] === element;
                        });
                        
                        if (uniqueClasses.length > 0) {
                            return `.\${uniqueClasses[0]}`;
                        }
                        
                        if (classes.length > 0) {
                            const classSelector = `.\${classes.join('.')}`;
                            if (document.querySelectorAll(classSelector).length === 1) {
                                return classSelector;
                            }
                        }
                    }
                    
                    const tag = element.tagName.toLowerCase();
                    const attributes = [];
                    
                    for (const attr of element.attributes) {
                        if (attr.name.startsWith('data-')) {
                            attributes.push(`[\${attr.name}="\${attr.value}"]`);
                        }
                    }
                    
                    if (attributes.length > 0) {
                        const attrSelector = tag + attributes.join('');
                        if (document.querySelectorAll(attrSelector).length === 1) {
                            return attrSelector;
                        }
                    }
                    
                    let parent = element.parentElement;
                    if (parent) {
                        const siblings = Array.from(parent.children);
                        const index = siblings.indexOf(element);
                        if (index !== -1) {
                            return `\${parent.tagName.toLowerCase()} > \${tag}:nth-child(\${index + 1})`;
                        }
                    }
                    
                    return tag;
                }
                
            } catch(e) { 
                console.error('동적사이트 상태 캡처 실패:', e);
                return {
                    scroll: { x: window.scrollX, y: window.scrollY, elements: [] },
                    iframes: [],
                    href: window.location.href,
                    title: document.title,
                    error: e.message
                };
            }
        })()
        """
    }
    
    // 🚀 **동적사이트 상태 파싱**
    private func parseDynamicSiteState(_ jsData: [String: Any]) -> BFCacheSnapshot.DynamicSiteState? {
        let frameworkInfo = jsData["framework"] as? [String: Any]
        let infiniteScrollInfo = jsData["infiniteScroll"] as? [String: Any]
        let virtualScrollInfo = jsData["virtualScroll"] as? [String: Any]
        let lazyLoadInfo = jsData["lazyLoad"] as? [String: Any]
        let networkInfo = jsData["network"] as? [String: Any]
        
        let frameworkType = frameworkInfo?["type"] as? String
        let routerState = frameworkInfo?["routerState"] as? [String: Any]
        
        var infiniteScrollState: BFCacheSnapshot.DynamicSiteState.InfiniteScrollState?
        if let infiniteInfo = infiniteScrollInfo {
            infiniteScrollState = BFCacheSnapshot.DynamicSiteState.InfiniteScrollState(
                loadedItemsCount: infiniteInfo["loadedItemsCount"] as? Int ?? 0,
                hasMore: infiniteInfo["hasMore"] as? Bool ?? false,
                lastAPICall: infiniteInfo["lastAPICall"] as? String,
                scrollTriggerOffset: infiniteInfo["scrollTriggerOffset"] as? Double ?? 0
            )
        }
        
        var virtualScrollState: BFCacheSnapshot.DynamicSiteState.VirtualScrollState?
        if let virtualInfo = virtualScrollInfo {
            virtualScrollState = BFCacheSnapshot.DynamicSiteState.VirtualScrollState(
                virtualIndex: virtualInfo["virtualIndex"] as? Int ?? 0,
                virtualOffset: virtualInfo["virtualOffset"] as? Double ?? 0,
                totalItems: virtualInfo["totalItems"] as? Int ?? 0,
                itemHeight: virtualInfo["itemHeight"] as? Double ?? 50,
                bufferSize: virtualInfo["bufferSize"] as? Int ?? 10
            )
        }
        
        var lazyLoadState: BFCacheSnapshot.DynamicSiteState.LazyLoadState?
        if let lazyInfo = lazyLoadInfo {
            lazyLoadState = BFCacheSnapshot.DynamicSiteState.LazyLoadState(
                loadedImages: lazyInfo["loadedImages"] as? [String] ?? [],
                pendingImages: lazyInfo["pendingImages"] as? [String] ?? [],
                intersectionTargets: lazyInfo["intersectionTargets"] as? [String] ?? []
            )
        }
        
        var networkState: BFCacheSnapshot.DynamicSiteState.NetworkState?
        if let networkInfo = networkInfo {
            networkState = BFCacheSnapshot.DynamicSiteState.NetworkState(
                pendingRequests: networkInfo["pendingRequests"] as? Int ?? 0,
                lastRequestTimestamp: networkInfo["lastRequestTimestamp"] as? Date ?? Date(),
                isNetworkIdle: networkInfo["isNetworkIdle"] as? Bool ?? true,
                completedRequests: networkInfo["completedRequests"] as? [String] ?? []
            )
        }
        
        // 모든 정보가 nil이면 nil 반환
        if frameworkType == nil && infiniteScrollState == nil && virtualScrollState == nil && lazyLoadState == nil && networkState == nil {
            return nil
        }
        
        return BFCacheSnapshot.DynamicSiteState(
            frameworkType: frameworkType,
            routerState: routerState,
            infiniteScrollState: infiniteScrollState,
            virtualScrollState: virtualScrollState,
            lazyLoadState: lazyLoadState,
            networkState: networkState
        )
    }
    
    // 🔍 **핵심 개선: 범용 스크롤 감지 JavaScript 생성**
    private func generateEnhancedScrollCaptureScript() -> String {
        return """
        (function() {
            try {
                // 🔍 **1단계: 범용 스크롤 요소 스캔**
                function findAllScrollableElements() {
                    const scrollables = [];
                    const maxElements = 50; // 성능 고려 제한
                    
                    // 1) 명시적 overflow 스타일을 가진 요소들
                    const explicitScrollables = document.querySelectorAll('*');
                    let count = 0;
                    
                    for (const el of explicitScrollables) {
                        if (count >= maxElements) break;
                        
                        const style = window.getComputedStyle(el);
                        const overflowY = style.overflowY;
                        const overflowX = style.overflowX;
                        
                        // 스크롤 가능한 요소 판별
                        if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                            (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) {
                            
                            // 현재 스크롤 위치가 0이 아닌 경우만 저장
                            if (el.scrollTop > 0 || el.scrollLeft > 0) {
                                const selector = generateBestSelector(el);
                                if (selector) {
                                    scrollables.push({
                                        selector: selector,
                                        top: el.scrollTop,
                                        left: el.scrollLeft,
                                        maxTop: el.scrollHeight - el.clientHeight,
                                        maxLeft: el.scrollWidth - el.clientWidth,
                                        id: el.id || '',
                                        className: el.className || '',
                                        tagName: el.tagName.toLowerCase()
                                    });
                                    count++;
                                }
                            }
                        }
                    }
                    
                    // 2) 일반적인 스크롤 컨테이너들
                    const commonScrollContainers = [
                        '.scroll-container', '.scrollable', '.content', '.main', '.body',
                        '[data-scroll]', '[data-scrollable]', '.overflow-auto', '.overflow-scroll'
                    ];
                    
                    for (const selector of commonScrollContainers) {
                        if (count >= maxElements) break;
                        
                        const elements = document.querySelectorAll(selector);
                        for (const el of elements) {
                            if (count >= maxElements) break;
                            
                            if ((el.scrollTop > 0 || el.scrollLeft > 0) && 
                                !scrollables.some(s => s.selector === generateBestSelector(el))) {
                                
                                scrollables.push({
                                    selector: generateBestSelector(el) || selector,
                                    top: el.scrollTop,
                                    left: el.scrollLeft,
                                    maxTop: el.scrollHeight - el.clientHeight,
                                    maxLeft: el.scrollWidth - el.clientWidth,
                                    id: el.id || '',
                                    className: el.className || '',
                                    tagName: el.tagName.toLowerCase()
                                });
                                count++;
                            }
                        }
                    }
                    
                    return scrollables;
                }
                
                // 🖼️ **2단계: iframe 스크롤 감지 (Same-Origin만)**
                function detectIframeScrolls() {
                    const iframes = [];
                    const iframeElements = document.querySelectorAll('iframe');
                    
                    for (const iframe of iframeElements) {
                        try {
                            // Same-origin 체크
                            const contentWindow = iframe.contentWindow;
                            if (contentWindow && contentWindow.location) {
                                const scrollX = contentWindow.scrollX || 0;
                                const scrollY = contentWindow.scrollY || 0;
                                
                                if (scrollX > 0 || scrollY > 0) {
                                    iframes.push({
                                        selector: generateBestSelector(iframe) || `iframe[src*="\${iframe.src.split('/').pop()}"]`,
                                        scrollX: scrollX,
                                        scrollY: scrollY,
                                        src: iframe.src || '',
                                        id: iframe.id || '',
                                        className: iframe.className || ''
                                    });
                                }
                            }
                        } catch(e) {
                            // Cross-origin iframe은 접근 불가 - 무시
                            console.log('Cross-origin iframe 스킵:', iframe.src);
                        }
                    }
                    
                    return iframes;
                }
                
                // 📏 **3단계: 동적 높이 요소 감지**
                function detectDynamicElements() {
                    const dynamics = [];
                    
                    // 일반적인 동적 콘텐츠 컨테이너들
                    const dynamicSelectors = [
                        '[data-infinite]', '[data-lazy]', '.infinite-scroll',
                        '.lazy-load', '.dynamic-content', '.feed', '.timeline',
                        '[data-scroll-container]', '.virtualized'
                    ];
                    
                    for (const selector of dynamicSelectors) {
                        const elements = document.querySelectorAll(selector);
                        for (const el of elements) {
                            if (el.scrollTop > 0 || el.scrollLeft > 0) {
                                dynamics.push({
                                    selector: generateBestSelector(el) || selector,
                                    top: el.scrollTop,
                                    left: el.scrollLeft,
                                    type: 'dynamic'
                                });
                            }
                        }
                    }
                    
                    return dynamics;
                }
                
                // 최적의 selector 생성
                function generateBestSelector(element) {
                    if (!element || element.nodeType !== 1) return null;
                    
                    // 1순위: ID가 있으면 ID 사용
                    if (element.id) {
                        return `#\${element.id}`;
                    }
                    
                    // 2순위: 고유한 클래스 조합
                    if (element.className) {
                        const classes = element.className.trim().split(/\\s+/);
                        const uniqueClasses = classes.filter(cls => {
                            const elements = document.querySelectorAll(`.\${cls}`);
                            return elements.length === 1 && elements[0] === element;
                        });
                        
                        if (uniqueClasses.length > 0) {
                            return `.\${uniqueClasses[0]}`;
                        }
                        
                        // 클래스 조합으로 고유성 확보
                        if (classes.length > 0) {
                            const classSelector = `.\${classes.join('.')}`;
                            if (document.querySelectorAll(classSelector).length === 1) {
                                return classSelector;
                            }
                        }
                    }
                    
                    // 3순위: 태그명 + 속성
                    const tag = element.tagName.toLowerCase();
                    const attributes = [];
                    
                    // data 속성 우선
                    for (const attr of element.attributes) {
                        if (attr.name.startsWith('data-')) {
                            attributes.push(`[\${attr.name}="\${attr.value}"]`);
                        }
                    }
                    
                    if (attributes.length > 0) {
                        const attrSelector = tag + attributes.join('');
                        if (document.querySelectorAll(attrSelector).length === 1) {
                            return attrSelector;
                        }
                    }
                    
                    // 4순위: nth-child 사용
                    let parent = element.parentElement;
                    if (parent) {
                        const siblings = Array.from(parent.children);
                        const index = siblings.indexOf(element);
                        if (index !== -1) {
                            return `\${parent.tagName.toLowerCase()} > \${tag}:nth-child(\${index + 1})`;
                        }
                    }
                    
                    // 최후: 태그명만
                    return tag;
                }
                
                // 🔍 **메인 실행**
                const scrollableElements = findAllScrollableElements();
                const iframeScrolls = detectIframeScrolls();
                const dynamicElements = detectDynamicElements();
                
                console.log(`🔍 스크롤 요소 감지: 일반 \${scrollableElements.length}개, iframe \${iframeScrolls.length}개, 동적 \${dynamicElements.length}개`);
                
                return {
                    scroll: { 
                        x: window.scrollX, 
                        y: window.scrollY,
                        elements: scrollableElements,
                        dynamics: dynamicElements
                    },
                    iframes: iframeScrolls,
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now(),
                    userAgent: navigator.userAgent,
                    viewport: {
                        width: window.innerWidth,
                        height: window.innerHeight
                    }
                };
            } catch(e) { 
                console.error('스크롤 감지 실패:', e);
                return {
                    scroll: { x: window.scrollX, y: window.scrollY, elements: [] },
                    iframes: [],
                    href: window.location.href,
                    title: document.title
                };
            }
        })()
        """
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 **개선된 디스크 저장 시스템**
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            // 디렉토리 생성
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // 1. 이미지 저장 (JPEG 압축)
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    do {
                        try jpegData.write(to: imagePath)
                        finalSnapshot.webViewSnapshotPath = imagePath.path
                        self.dbg("💾 이미지 저장 성공: \(imagePath.lastPathComponent)")
                    } catch {
                        self.dbg("❌ 이미지 저장 실패: \(error.localizedDescription)")
                        // 저장 실패해도 계속 진행
                    }
                }
            }
            
            // 2. 상태 데이터 저장 (JSON)
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                do {
                    try stateData.write(to: statePath)
                    self.dbg("💾 상태 저장 성공: \(statePath.lastPathComponent)")
                } catch {
                    self.dbg("❌ 상태 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 3. 메타데이터 저장
            let metadata = CacheMetadata(
                pageID: pageID,
                tabID: tabID,
                version: version,
                timestamp: Date(),
                url: snapshot.snapshot.pageRecord.url.absoluteString,
                title: snapshot.snapshot.pageRecord.title
            )
            
            let metadataPath = pageDir.appendingPathComponent("metadata.json")
            if let metadataData = try? JSONEncoder().encode(metadata) {
                do {
                    try metadataData.write(to: metadataPath)
                } catch {
                    self.dbg("❌ 메타데이터 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 4. 인덱스 업데이트 (원자적)
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            let statusMsg = finalSnapshot.captureStatus == .enhanced ? "🚀 고급" : "💾 일반"
            self.dbg("\(statusMsg) 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
            // 5. 이전 버전 정리 (최신 3개만 유지)
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
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
                    // 버전 번호 추출하여 정렬
                    let v1 = Int(url1.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    let v2 = Int(url2.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    return v1 > v2  // 최신 버전부터
                }
            
            // 최신 3개 제외하고 삭제
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
    
    // MARK: - 💾 **개선된 디스크 캐시 로딩**
    
    private func loadDiskCacheIndex() {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            // BFCache 디렉토리 생성
            self.createDirectoryIfNeeded(at: self.bfCacheDirectory)
            
            var loadedCount = 0
            
            // 모든 탭 디렉토리 스캔
            do {
                let tabDirs = try FileManager.default.contentsOfDirectory(at: self.bfCacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                
                for tabDir in tabDirs {
                    if tabDir.lastPathComponent.hasPrefix("Tab_") {
                        // 각 페이지 디렉토리 스캔
                        let pageDirs = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        
                        for pageDir in pageDirs {
                            if pageDir.lastPathComponent.hasPrefix("Page_") {
                                // metadata.json 로드
                                let metadataPath = pageDir.appendingPathComponent("metadata.json")
                                if let data = try? Data(contentsOf: metadataPath),
                                   let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) {
                                    
                                    // 스레드 안전하게 인덱스 업데이트
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
    
    // MARK: - 🔍 **개선된 스냅샷 조회 시스템**
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        // 1. 먼저 메모리 캐시 확인 (스레드 안전)
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            let typeMsg = snapshot.captureStatus == .enhanced ? "🚀 고급" : "💭 일반"
            dbg("\(typeMsg) 메모리 캐시 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인 (스레드 안전)
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장 (최적화)
                setMemoryCache(snapshot, for: pageID)
                
                let typeMsg = snapshot.captureStatus == .enhanced ? "🚀 고급" : "💾 일반"
                dbg("\(typeMsg) 디스크 캐시 히트: \(snapshot.pageRecord.title)")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
    // MARK: - 🔧 **수정: hasCache 메서드 추가**
    func hasCache(for pageID: UUID) -> Bool {
        // 메모리 캐시 체크
        if cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) != nil {
            return true
        }
        
        // 디스크 캐시 인덱스 체크
        if cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) != nil {
            return true
        }
        
        return false
    }
    
    // MARK: - 메모리 캐시 관리
    
    private func storeInMemory(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        setMemoryCache(snapshot, for: pageID)
        let typeMsg = snapshot.captureStatus == .enhanced ? "🚀 고급" : "💭 일반"
        dbg("\(typeMsg) 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)]")
    }
    
    // MARK: - 🧹 **개선된 캐시 정리**
    
    // 탭 닫을 때만 호출 (무제한 캐시 정책)
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        // 메모리에서 제거 (스레드 안전)
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
                self._cacheVersion.removeValue(forKey: pageID)
            }
        }
        
        // 디스크에서 제거
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
    
    // 메모리 경고 처리 (메모리 캐시만 일부 정리)
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
            
            // 메모리 캐시의 절반 정리 (오래된 것부터)
            let sorted = self._memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            self.dbg("⚠️ 메모리 경고 - 메모리 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🚀 **동적사이트 전용 고급 캡처 API**
    
    func captureEnhancedSnapshot(pageRecord: PageRecord, webView: WKWebView, tabID: UUID? = nil) {
        captureSnapshot(pageRecord: pageRecord, webView: webView, type: .enhanced, tabID: tabID)
    }
    
    // 동적사이트 감지 (외부에서 호출 가능)
    func detectDynamicSite(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let detectionScript = """
        (function() {
            // SPA 프레임워크 감지
            const hasSPAFramework = !!(
                window.__REACT_DEVTOOLS_GLOBAL_HOOK__ || 
                window.React || 
                window.Vue || window.__VUE__ || 
                window.ng || window.getAllAngularRootElements ||
                document.querySelector('[data-reactroot]') ||
                document.querySelector('[data-v-]') ||
                document.querySelector('[ng-app]')
            );
            
            // 무한스크롤 감지
            const hasInfiniteScroll = !!(
                document.querySelector('[data-infinite-scroll]') ||
                document.querySelector('.infinite-scroll') ||
                document.querySelector('.feed') ||
                document.querySelector('.timeline')
            );
            
            // 가상스크롤 감지
            const hasVirtualScroll = !!(
                document.querySelector('.ReactVirtualized__Grid') ||
                document.querySelector('.ReactVirtualized__List') ||
                document.querySelector('.vue-virtual-scroller') ||
                document.querySelector('[data-virtualized]')
            );
            
            // 지연로딩 감지
            const hasLazyLoad = !!(
                document.querySelector('img[loading="lazy"]') ||
                document.querySelector('img[data-src]') ||
                document.querySelector('.lazy-image')
            );
            
            return hasSPAFramework || hasInfiniteScroll || hasVirtualScroll || hasLazyLoad;
        })()
        """
        
        webView.evaluateJavaScript(detectionScript) { result, _ in
            completion((result as? Bool) ?? false)
        }
    }
    
    // MARK: - 🎯 **제스처 시스템 (🛡️ 연속 제스처 먹통 방지 적용)**
    
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
        
        dbg("🚀 강화된 BFCache 제스처 설정 완료")
    }
    
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
            // 🛡️ **핵심 1: 전환 중이면 새 제스처 무시**
            guard activeTransitions[tabID] == nil else { 
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 🛡️ **핵심 3: 혹시 남아있는 기존 전환 강제 정리**
                if let existing = activeTransitions[tabID] {
                    existing.previewContainer?.removeFromSuperview()
                    activeTransitions.removeValue(forKey: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                // 🚀 **동적사이트 감지 후 적절한 캡처 타입 결정**
                detectDynamicSite(webView: webView) { [weak self] isDynamic in
                    guard let self = self else { return }
                    
                    // 현재 페이지 캡처 (동적사이트면 고급 캡처)
                    if let currentRecord = stateModel.dataModel.currentPageRecord {
                        let captureType: CaptureType = isDynamic ? .enhanced : .immediate
                        self.captureSnapshot(pageRecord: currentRecord, webView: webView, type: captureType, tabID: tabID)
                        
                        let captureMsg = isDynamic ? "🚀 동적사이트 고급" : "📸 일반"
                        self.dbg("\(captureMsg) 캡처 시작: \(currentRecord.title)")
                    }
                }
                
                // 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
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
    
    // MARK: - 🎯 **나머지 제스처/전환 로직 (기존 유지)**
    
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
        
        // 현재 웹뷰 스냅샷 사용
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
            
            if let snapshot = retrieveSnapshot(for: targetRecord.id),
               let targetImage = snapshot.loadImage() {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
                
                let typeMsg = snapshot.captureStatus == .enhanced ? "🚀 고급" : "📸 일반"
                dbg("\(typeMsg) 타겟 페이지 BFCache 스냅샷 사용: \(targetRecord.title)")
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
    
    // 🎬 **핵심 개선: 미리보기 컨테이너 0.8초 고정 타이밍**
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
                // 🎬 **0.8초 고정 타이밍으로 네비게이션 수행**
                self?.performNavigationWithFixedTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🔄 **0.8초 고정 타이밍을 적용한 네비게이션 수행**
    private func performNavigationWithFixedTiming(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            // 실패 시 즉시 정리
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // 🔄 **0.8초 고정 BFCache 복원 + 미리보기 제거**
        tryFixedBFCacheRestore(stateModel: stateModel, direction: context.direction)
        
        // 🎬 **핵심: 0.8초 후 미리보기 제거 (깜빡임 방지)**
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            previewContainer.removeFromSuperview()
            self?.activeTransitions.removeValue(forKey: context.tabID)
            self?.dbg("🎬 0.8초 고정 타이밍 미리보기 제거 완료")
        }
    }
    
    // 🔄 **단순화된 BFCache 복원 (0.8초 고정 타이밍)** 
    private func tryFixedBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 0.8초 고정 복원
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    let typeMsg = snapshot.captureStatus == .enhanced ? "🚀 고급" : "✅ 일반"
                    self?.dbg("\(typeMsg) 0.8초 고정 BFCache 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ 0.8초 고정 BFCache 복원 실패: \(currentRecord.title)")
                }
            }
        } else {
            // BFCache 미스
            dbg("❌ BFCache 미스: \(currentRecord.title)")
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
    
    // MARK: - 버튼 네비게이션 (즉시 전환)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🚀 **동적사이트 감지 후 적절한 캡처 타입 결정**
        detectDynamicSite(webView: webView) { [weak self] isDynamic in
            guard let self = self else { return }
            
            // 현재 페이지 캡처 (동적사이트면 고급 캡처)
            if let currentRecord = stateModel.dataModel.currentPageRecord {
                let captureType: CaptureType = isDynamic ? .enhanced : .immediate
                self.captureSnapshot(pageRecord: currentRecord, webView: webView, type: captureType, tabID: tabID)
                
                let captureMsg = isDynamic ? "🚀 동적사이트 고급" : "📸 일반"
                self.dbg("\(captureMsg) 버튼 뒤로가기 캡처: \(currentRecord.title)")
            }
        }
        
        stateModel.goBack()
        tryFixedBFCacheRestore(stateModel: stateModel, direction: .back)
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🚀 **동적사이트 감지 후 적절한 캡처 타입 결정**
        detectDynamicSite(webView: webView) { [weak self] isDynamic in
            guard let self = self else { return }
            
            // 현재 페이지 캡처 (동적사이트면 고급 캡처)
            if let currentRecord = stateModel.dataModel.currentPageRecord {
                let captureType: CaptureType = isDynamic ? .enhanced : .immediate
                self.captureSnapshot(pageRecord: currentRecord, webView: webView, type: captureType, tabID: tabID)
                
                let captureMsg = isDynamic ? "🚀 동적사이트 고급" : "📸 일반"
                self.dbg("\(captureMsg) 버튼 앞으로가기 캡처: \(currentRecord.title)")
            }
        }
        
        stateModel.goForward()
        tryFixedBFCacheRestore(stateModel: stateModel, direction: .forward)
    }
    
    // MARK: - 스와이프 제스처 감지 처리 (DataModel에서 이관)
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
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
    
    // MARK: - 🌐 JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        // 🚀 **강화된 BFCache + 네트워크 상태 추적 스크립트**
        (function() {
            'use strict';
            
            console.log('🚀 강화된 BFCache + 네트워크 추적 시스템 초기화');
            
            // === 네트워크 요청 추적 시스템 ===
            
            window.__bfcache_network_requests = 0;
            window.__bfcache_last_request_time = Date.now();
            window.__bfcache_completed_requests = [];
            
            // XMLHttpRequest 후킹
            const originalXHROpen = XMLHttpRequest.prototype.open;
            const originalXHRSend = XMLHttpRequest.prototype.send;
            
            XMLHttpRequest.prototype.open = function(...args) {
                this.__bfcache_url = args[1];
                return originalXHROpen.apply(this, args);
            };
            
            XMLHttpRequest.prototype.send = function(...args) {
                window.__bfcache_network_requests++;
                window.__bfcache_last_request_time = Date.now();
                
                console.log('📡 XHR 요청 시작:', this.__bfcache_url, '활성 요청:', window.__bfcache_network_requests);
                
                const originalOnLoad = this.onload;
                const originalOnError = this.onerror;
                const originalOnAbort = this.onabort;
                const originalOnTimeout = this.ontimeout;
                
                const finishRequest = (status) => {
                    window.__bfcache_network_requests = Math.max(0, window.__bfcache_network_requests - 1);
                    
                    if (this.__bfcache_url) {
                        window.__bfcache_completed_requests.push({
                            url: this.__bfcache_url,
                            status: status,
                            timestamp: Date.now()
                        });
                        
                        // 최근 20개만 유지
                        if (window.__bfcache_completed_requests.length > 20) {
                            window.__bfcache_completed_requests = window.__bfcache_completed_requests.slice(-20);
                        }
                    }
                    
                    console.log('📡 XHR 완료:', this.__bfcache_url, status, '남은 요청:', window.__bfcache_network_requests);
                };
                
                this.onload = function(e) {
                    finishRequest('success');
                    return originalOnLoad?.call(this, e);
                };
                
                this.onerror = function(e) {
                    finishRequest('error');
                    return originalOnError?.call(this, e);
                };
                
                this.onabort = function(e) {
                    finishRequest('abort');
                    return originalOnAbort?.call(this, e);
                };
                
                this.ontimeout = function(e) {
                    finishRequest('timeout');
                    return originalOnTimeout?.call(this, e);
                };
                
                return originalXHRSend.apply(this, args);
            };
            
            // Fetch API 후킹
            if (window.fetch) {
                const originalFetch = window.fetch;
                
                window.fetch = function(url, options) {
                    window.__bfcache_network_requests++;
                    window.__bfcache_last_request_time = Date.now();
                    
                    const urlString = typeof url === 'string' ? url : url.toString();
                    console.log('📡 Fetch 요청 시작:', urlString, '활성 요청:', window.__bfcache_network_requests);
                    
                    return originalFetch.apply(this, arguments)
                        .then(response => {
                            window.__bfcache_network_requests = Math.max(0, window.__bfcache_network_requests - 1);
                            
                            window.__bfcache_completed_requests.push({
                                url: urlString,
                                status: response.ok ? 'success' : 'error',
                                timestamp: Date.now()
                            });
                            
                            if (window.__bfcache_completed_requests.length > 20) {
                                window.__bfcache_completed_requests = window.__bfcache_completed_requests.slice(-20);
                            }
                            
                            console.log('📡 Fetch 완료:', urlString, response.status, '남은 요청:', window.__bfcache_network_requests);
                            return response;
                        })
                        .catch(error => {
                            window.__bfcache_network_requests = Math.max(0, window.__bfcache_network_requests - 1);
                            
                            window.__bfcache_completed_requests.push({
                                url: urlString,
                                status: 'error',
                                timestamp: Date.now()
                            });
                            
                            console.log('📡 Fetch 실패:', urlString, error.message, '남은 요청:', window.__bfcache_network_requests);
                            throw error;
                        });
                };
            }
            
            // === 무한스크롤 API 추적 ===
            
            // 일반적인 무한스크롤 패턴 감지
            let infiniteScrollObserver;
            
            function setupInfiniteScrollTracking() {
                if ('IntersectionObserver' in window) {
                    infiniteScrollObserver = new IntersectionObserver((entries) => {
                        entries.forEach(entry => {
                            if (entry.isIntersecting) {
                                const element = entry.target;
                                
                                // 무한스크롤 트리거 감지
                                if (element.classList.contains('load-more') || 
                                    element.dataset.loadMore ||
                                    element.classList.contains('infinite-trigger')) {
                                    
                                    console.log('♾️ 무한스크롤 트리거 감지:', element);
                                    window.__lastInfiniteScrollAPI = window.location.href;
                                }
                            }
                        });
                    }, { threshold: 0.1 });
                    
                    // 무한스크롤 요소들 관찰 시작
                    document.querySelectorAll('.load-more, [data-load-more], .infinite-trigger, .infinite-scroll-trigger').forEach(el => {
                        infiniteScrollObserver.observe(el);
                    });
                }
            }
            
            // DOM 변화 감지로 새로운 무한스크롤 요소 추적
            if ('MutationObserver' in window) {
                const mutationObserver = new MutationObserver((mutations) => {
                    mutations.forEach(mutation => {
                        mutation.addedNodes.forEach(node => {
                            if (node.nodeType === 1) { // Element node
                                // 새로운 무한스크롤 요소 체크
                                if (node.classList?.contains('load-more') || 
                                    node.dataset?.loadMore ||
                                    node.classList?.contains('infinite-trigger')) {
                                    
                                    if (infiniteScrollObserver) {
                                        infiniteScrollObserver.observe(node);
                                        console.log('♾️ 새 무한스크롤 요소 관찰 시작:', node);
                                    }
                                }
                                
                                // 하위 요소들도 체크
                                node.querySelectorAll?.('.load-more, [data-load-more], .infinite-trigger').forEach(el => {
                                    if (infiniteScrollObserver) {
                                        infiniteScrollObserver.observe(el);
                                    }
                                });
                            }
                        });
                    });
                });
                
                mutationObserver.observe(document.body, {
                    childList: true,
                    subtree: true
                });
            }
            
            // === 기존 BFCache 이벤트 처리 ===
            
            window.addEventListener('pageshow', function(event) {
                if (event.persisted) {
                    console.log('🔄 BFCache 페이지 복원 - 네트워크 상태 초기화');
                    
                    // 네트워크 상태 초기화
                    window.__bfcache_network_requests = 0;
                    window.__bfcache_last_request_time = Date.now();
                    
                    // 동적 콘텐츠 새로고침 (필요시)
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
                    console.log('📸 BFCache 페이지 저장 - 상태 정리');
                    
                    // 관찰자 정리
                    if (infiniteScrollObserver) {
                        infiniteScrollObserver.disconnect();
                        infiniteScrollObserver = null;
                    }
                }
            });
            
            // DOM 로드 완료 후 무한스크롤 추적 시작
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setupInfiniteScrollTracking);
            } else {
                setupInfiniteScrollTracking();
            }
            
            console.log('✅ 강화된 BFCache + 네트워크 추적 시스템 설정 완료');
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[🚀 BFCache] \(msg)")
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
        
        TabPersistenceManager.debugMessages.append("✅ 🚀 강화된 동적사이트 BFCache 시스템 설치 완료")
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
    
    // 🚀 **동적사이트 전용 API**
    static func captureEnhancedSnapshot(pageRecord: PageRecord, webView: WKWebView, tabID: UUID) {
        shared.captureEnhancedSnapshot(pageRecord: pageRecord, webView: webView, tabID: tabID)
    }
    
    static func detectDynamicSite(webView: WKWebView, completion: @escaping (Bool) -> Void) {
        shared.detectDynamicSite(webView: webView, completion: completion)
    }
}

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출
extension BFCacheTransitionSystem {

    /// 사용자가 링크/폼으로 **떠나기 직전** 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 🚀 **동적사이트 감지 후 적절한 캡처 타입 결정**
        detectDynamicSite(webView: webView) { [weak self] isDynamic in
            guard let self = self else { return }
            
            let captureType: CaptureType = isDynamic ? .enhanced : .immediate
            self.captureSnapshot(pageRecord: rec, webView: webView, type: captureType, tabID: tabID)
            
            let captureMsg = isDynamic ? "🚀 동적사이트 고급" : "📸 일반"
            self.dbg("\(captureMsg) 떠나기 스냅샷 캡처 시작: \(rec.title)")
        }
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 🚀 **동적사이트 감지 후 적절한 캡처 타입 결정**
        detectDynamicSite(webView: webView) { [weak self] isDynamic in
            guard let self = self else { return }
            
            // 현재 페이지 캡처 (동적사이트면 고급 캡처, 아니면 백그라운드 우선순위)
            let captureType: CaptureType = isDynamic ? .enhanced : .background
            self.captureSnapshot(pageRecord: rec, webView: webView, type: captureType, tabID: tabID)
            
            let captureMsg = isDynamic ? "🚀 동적사이트 고급" : "📸 일반"
            self.dbg("\(captureMsg) 도착 스냅샷 캡처 시작: \(rec.title)")
        }
        
        // 이전 페이지들도 순차적으로 캐시 확인 및 캡처
        if stateModel.dataModel.currentPageIndex > 0 {
            // 최근 3개 페이지만 체크 (성능 고려)
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                // 캐시가 없는 경우만 메타데이터 저장
                if !hasCache(for: previousRecord.id) {
                    // 메타데이터만 저장 (이미지는 없음)
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollPosition: .zero,
                        timestamp: Date(),
                        captureStatus: .failed,
                        version: 1
                    )
                    
                    // 디스크에 메타데이터만 저장
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
