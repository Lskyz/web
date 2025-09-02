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
//  🎬 **미리보기 컨테이너 0.8초 고정 타이밍** - 깜빡임 방지
//  ⚡ **균형 잡힌 전환 속도 최적화**
//  🛡️ **빠른 연속 제스처 먹통 방지** - 전환 중 차단 + 강제 정리
//  🚫 **폼데이터/눌린상태 저장 제거** - 부작용 해결
//  🔍 **범용 동적 콘텐츠 감지** - 기술적 특성 기반 (사이트 무관)
//  🔄 **다단계 복원 시스템** - 동적사이트 안정성 검증
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
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord
        case domSnapshot
        case scrollPosition
        case jsState
        case timestamp
        case webViewSnapshotPath
        case captureStatus
        case version
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
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // ⚡ **동적사이트 대응 복원 메서드 - 0.8초 고정 대기 + 안정성 검증**
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
            
        case .partial, .complete:
            break
        }
        
                        TabPersistenceManager.debugMessages.append("BFCache 범용 동적 콘텐츠 대응 복원 시작 (0.8초 고정)")
        
        // 🎯 **동적사이트 감지 후 적응형 복원**
        DispatchQueue.main.async {
            self.performAdaptiveRestoreWithStabilityCheck(to: webView, completion: completion)
        }
    }
    
    // 🔄 **핵심: 동적사이트 안정성 체크 + 다단계 복원 시스템**
    private func performAdaptiveRestoreWithStabilityCheck(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        // 🎯 **동적 콘텐츠 감지**
        let isDynamic = detectDynamicSite(webView: webView)
        TabPersistenceManager.debugMessages.append("🔍 복원 대상: \(isDynamic ? "동적 콘텐츠" : "정적 콘텐츠")")
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        // **1단계: 메인 윈도우 스크롤 즉시 복원 (0ms)**
        restoreSteps.append((1, { stepCompletion in
            let targetPos = self.scrollPosition
            TabPersistenceManager.debugMessages.append("🔄 1단계: 메인 스크롤 복원 (즉시)")
            
            // 네이티브 스크롤뷰 즉시 설정
            webView.scrollView.setContentOffset(targetPos, animated: false)
            
            // JavaScript 메인 스크롤 복원 + 안정성 검증
            let mainScrollJS = """
            (function() {
                try {
                    const targetY = \(targetPos.y);
                    const targetX = \(targetPos.x);
                    
                    // 즉시 스크롤 설정
                    window.scrollTo(targetX, targetY);
                    document.documentElement.scrollTop = targetY;
                    document.body.scrollTop = targetY;
                    
                    // 🎯 **안정성 검증**: 실제 스크롤 위치 확인
                    setTimeout(() => {
                        const actualY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop;
                        const diff = Math.abs(actualY - targetY);
                        console.log(`스크롤 복원 검증: 목표=${targetY}, 실제=${actualY}, 차이=${diff}`);
                    }, 100);
                    
                    return true;
                } catch(e) { 
                    console.error('메인 스크롤 복원 실패:', e);
                    return false; 
                }
            })()
            """
            
            webView.evaluateJavaScript(mainScrollJS) { result, _ in
                let success = (result as? Bool) ?? false
                TabPersistenceManager.debugMessages.append("🔄 1단계 완료: \(success ? "성공" : "실패")")
                stepCompletion(success)
            }
        }))
        
        // **2단계: 주요 컨테이너 스크롤 복원 (동적 콘텐츠는 더 긴 대기)**
        if let jsState = self.jsState,
           let scrollData = jsState["scroll"] as? [String: Any],
           let elements = scrollData["elements"] as? [[String: Any]], !elements.isEmpty {
            
            let containerDelay: TimeInterval = isDynamic ? 0.4 : 0.2 // 동적 콘텐츠는 더 대기
            
            restoreSteps.append((2, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🔄 2단계: 컨테이너 스크롤 복원 (\(containerDelay)초 후)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + containerDelay) {
                    let containerScrollJS = self.generateStabilityAwareContainerScrollScript(elements)
                    webView.evaluateJavaScript(containerScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **3단계: iframe 스크롤 복원 (동적 콘텐츠는 더 긴 대기)**
        if let jsState = self.jsState,
           let iframeData = jsState["iframes"] as? [[String: Any]], !iframeData.isEmpty {
            
            let iframeDelay: TimeInterval = isDynamic ? 0.6 : 0.4 // 동적 콘텐츠는 더 대기
            
            restoreSteps.append((3, { stepCompletion in
                TabPersistenceManager.debugMessages.append("🔄 3단계: iframe 스크롤 복원 (\(iframeDelay)초 후)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + iframeDelay) {
                    let iframeScrollJS = self.generateIframeScrollScript(iframeData)
                    webView.evaluateJavaScript(iframeScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **4단계: 최종 확인 및 보정 (동적 콘텐츠는 더 긴 대기)**
        let finalDelay: TimeInterval = isDynamic ? 0.8 : 0.6 // 동적 콘텐츠는 더 대기
        
        restoreSteps.append((4, { stepCompletion in
            TabPersistenceManager.debugMessages.append("🔄 4단계: 최종 보정 (\(finalDelay)초 후)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + finalDelay) {
                let finalVerifyJS = """
                (function() {
                    try {
                        const targetY = \(self.scrollPosition.y);
                        const targetX = \(self.scrollPosition.x);
                        
                        // 🎯 **동적 콘텐츠 대응**: 콘텐츠 안정성 재확인
                        const loadingElements = document.querySelectorAll('[loading], .loading, .spinner');
                        if (loadingElements.length > 0) {
                            console.log('⚠️ 로딩 요소 여전히 존재, 복원 결과 불확실');
                        }
                        
                        // 최종 메인 스크롤 확인 및 보정
                        const currentY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop;
                        const diff = Math.abs(currentY - targetY);
                        
                        if (diff > 10) {
                            console.log(`최종 스크롤 보정 필요: 현재=${currentY}, 목표=${targetY}, 차이=${diff}`);
                            window.scrollTo(targetX, targetY);
                            
                            // 보정 후 재확인
                            setTimeout(() => {
                                const finalY = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop;
                                const finalDiff = Math.abs(finalY - targetY);
                                console.log(`보정 후 위치: ${finalY}, 최종 차이: ${finalDiff}`);
                            }, 100);
                        }
                        
                        // 성공 기준: 20px 이내 오차
                        return diff <= 20;
                    } catch(e) { 
                        console.error('최종 검증 실패:', e);
                        return false; 
                    }
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
                
                TabPersistenceManager.debugMessages.append("🔄 동적 콘텐츠 대응 복원 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                completion(overallSuccess)
            }
        }
        
        executeNextStep()
    }
    
    // 🎯 **안정성 체크가 포함된 컨테이너 스크롤 복원 스크립트**
    private func generateStabilityAwareContainerScrollScript(_ elements: [[String: Any]]) -> String {
        let elementsJSON = convertToJSONString(elements) ?? "[]"
        return """
        (function() {
            try {
                const elements = \(elementsJSON);
                let restored = 0;
                let skipped = 0;
                
                for (const item of elements) {
                    if (!item.selector) continue;
                    
                    // 🎯 **안정성 체크**: 요소가 동적 로딩 중인지 확인
                    const skipIfUnstable = (el) => {
                        if (el.classList.contains('loading') || 
                            el.classList.contains('skeleton') ||
                            el.hasAttribute('data-loading') ||
                            el.hasAttribute('loading')) {
                            console.log('⚠️ 불안정한 요소 스킵:', item.selector);
                            skipped++;
                            return true;
                        }
                        return false;
                    };
                    
                    // 다양한 selector 시도
                    const selectors = [
                        item.selector,
                        item.selector.replace(/\\[\\d+\\]/g, ''), // 인덱스 제거
                        item.className ? '.' + item.className : null,
                        item.id ? '#' + item.id : null
                    ].filter(s => s);
                    
                    let elementRestored = false;
                    
                    for (const sel of selectors) {
                        if (elementRestored) break;
                        
                        try {
                            const foundElements = document.querySelectorAll(sel);
                            if (foundElements.length > 0) {
                                for (const el of foundElements) {
                                    if (skipIfUnstable(el)) continue;
                                    
                                    if (el && typeof el.scrollTop === 'number') {
                                        // 🎯 **검증 후 복원**: 기존 스크롤 위치와 비교
                                        const currentTop = el.scrollTop;
                                        const targetTop = item.top || 0;
                                        const targetLeft = item.left || 0;
                                        
                                        // 의미있는 변화가 있을 때만 복원
                                        if (Math.abs(currentTop - targetTop) > 5) {
                                            el.scrollTop = targetTop;
                                            el.scrollLeft = targetLeft;
                                            
                                            // 복원 후 검증
                                            setTimeout(() => {
                                                const actualTop = el.scrollTop;
                                                const diff = Math.abs(actualTop - targetTop);
                                                if (diff > 10) {
                                                    console.log(`⚠️ 컨테이너 복원 오차: 목표=${targetTop}, 실제=${actualTop}, 차이=${diff}`, sel);
                                                }
                                            }, 50);
                                            
                                            restored++;
                                            console.log(`✅ 컨테이너 복원: ${sel} → ${targetTop}`);
                                        }
                                        elementRestored = true;
                                    }
                                }
                                if (elementRestored) break; // 성공하면 다음 selector 시도 안함
                            }
                        } catch(e) {
                            console.warn('컨테이너 selector 실패:', sel, e);
                        }
                    }
                }
                
                console.log(`컨테이너 스크롤 복원 완료: ${restored}개 성공, ${skipped}개 스킵`);
                return restored > 0;
            } catch(e) {
                console.error('컨테이너 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 컨테이너 스크롤 복원 스크립트 생성 (기존 버전 - 정적사이트용)
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
    }
    
    // MARK: - 🔧 **핵심 개선: 동적사이트 대응 원자적 캡처 작업**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    // 중복 방지를 위한 진행 중인 캡처 추적
    private var pendingCaptures: Set<UUID> = []
    
    // 🎯 **1. 범용 동적 콘텐츠 감지 로직 (사이트 무관)**
    private func detectDynamicSite(webView: WKWebView) -> Bool {
        var isDynamic = false
        let semaphore = DispatchSemaphore(value: 0)
        
        // JavaScript로 기술적 특성 분석
        let detectionScript = """
        (function() {
            try {
                // 1. 로딩/스켈레톤 UI 감지
                const loadingElements = document.querySelectorAll('[loading], .loading, .skeleton, .spinner, .placeholder, [data-loading]');
                const loadingCount = loadingElements.length;
                
                // 2. Lazy loading 이미지 감지
                const lazyImages = document.querySelectorAll('img[loading="lazy"]:not([src]), img[data-src], img[data-lazy]');
                const lazyCount = lazyImages.length;
                
                // 3. 무한스크롤/동적 로딩 패턴 감지
                const infiniteScrollElements = document.querySelectorAll('[data-infinite], [data-scroll-end], .infinite-scroll, [data-lazy-load]');
                const infiniteCount = infiniteScrollElements.length;
                
                // 4. SPA 프레임워크 감지
                const hasReact = !!(window.React || document.querySelector('[data-reactroot], [data-react], #root[data-react]'));
                const hasVue = !!(window.Vue || document.querySelector('[data-v-], [data-vue]'));
                const hasAngular = !!(window.angular || document.querySelector('[ng-app], [data-ng-app]'));
                const hasSPA = hasReact || hasVue || hasAngular;
                
                // 5. 동적 콘텐츠 컨테이너 감지
                const dynamicContainers = document.querySelectorAll('.feed, .timeline, .stream, .posts, .content-list, .dynamic-content');
                const dynamicCount = dynamicContainers.length;
                
                // 6. JavaScript 라우팅 감지 (pushState/replaceState 사용)
                const hasHistoryAPI = !!(history.pushState && window.location.hash.length > 2);
                
                // 7. Ajax/Fetch 활성 요청 감지 (간접적)
                const hasActiveRequests = document.readyState !== 'complete';
                
                // 8. 콘텐츠 높이 변동성 체크
                const body = document.body || document.documentElement;
                const hasVariableHeight = body.scrollHeight > window.innerHeight * 2; // 긴 페이지
                
                // 9. 실시간 업데이트 요소 감지
                const realTimeElements = document.querySelectorAll('[data-live], [data-real-time], [data-auto-update]');
                const realTimeCount = realTimeElements.length;
                
                // 점수 기반 판단
                let dynamicScore = 0;
                
                if (loadingCount > 0) dynamicScore += 2;
                if (lazyCount > 5) dynamicScore += 2;
                if (infiniteCount > 0) dynamicScore += 3;
                if (hasSPA) dynamicScore += 3;
                if (dynamicCount > 0) dynamicScore += 2;
                if (hasHistoryAPI) dynamicScore += 1;
                if (hasActiveRequests) dynamicScore += 1;
                if (hasVariableHeight) dynamicScore += 1;
                if (realTimeCount > 0) dynamicScore += 2;
                
                return {
                    isDynamic: dynamicScore >= 4, // 임계점: 4점 이상이면 동적사이트
                    score: dynamicScore,
                    details: {
                        loadingElements: loadingCount,
                        lazyImages: lazyCount,
                        infiniteScroll: infiniteCount,
                        spa: hasSPA,
                        dynamicContainers: dynamicCount,
                        historyAPI: hasHistoryAPI,
                        activeRequests: hasActiveRequests,
                        variableHeight: hasVariableHeight,
                        realTimeElements: realTimeCount
                    }
                };
            } catch(e) {
                return { isDynamic: false, score: 0, error: e.message };
            }
        })()
        """
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(detectionScript) { result, error in
                if let data = result as? [String: Any],
                   let detected = data["isDynamic"] as? Bool {
                    isDynamic = detected
                    
                    if let score = data["score"] as? Int {
                        self.dbg("🔍 동적사이트 감지 점수: \(score)점 → \(detected ? "동적" : "정적")")
                    }
                }
                semaphore.signal()
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 0.5)
        return isDynamic
    } hasAngular;
                
                // 5. 동적 콘텐츠 컨테이너 감지
                const dynamicContainers = document.querySelectorAll('.feed, .timeline, .stream, .posts, .content-list, .dynamic-content');
                const dynamicCount = dynamicContainers.length;
                
                // 6. JavaScript 라우팅 감지 (pushState/replaceState 사용)
                const hasHistoryAPI = !!(history.pushState && window.location.hash.length > 2);
                
                // 7. Ajax/Fetch 활성 요청 감지 (간접적)
                const hasActiveRequests = document.readyState !== 'complete';
                
                // 8. 콘텐츠 높이 변동성 체크
                const body = document.body || document.documentElement;
                const hasVariableHeight = body.scrollHeight > window.innerHeight * 2; // 긴 페이지
                
                // 9. 실시간 업데이트 요소 감지
                const realTimeElements = document.querySelectorAll('[data-live], [data-real-time], [data-auto-update]');
                const realTimeCount = realTimeElements.length;
                
                // 점수 기반 판단
                let dynamicScore = 0;
                
                if (loadingCount > 0) dynamicScore += 2;
                if (lazyCount > 5) dynamicScore += 2;
                if (infiniteCount > 0) dynamicScore += 3;
                if (hasSPA) dynamicScore += 3;
                if (dynamicCount > 0) dynamicScore += 2;
                if (hasHistoryAPI) dynamicScore += 1;
                if (hasActiveRequests) dynamicScore += 1;
                if (hasVariableHeight) dynamicScore += 1;
                if (realTimeCount > 0) dynamicScore += 2;
                
                return {
                    isDynamic: dynamicScore >= 4, // 임계점: 4점 이상이면 동적사이트
                    score: dynamicScore,
                    details: {
                        loadingElements: loadingCount,
                        lazyImages: lazyCount,
                        infiniteScroll: infiniteCount,
                        spa: hasSPA,
                        dynamicContainers: dynamicCount,
                        historyAPI: hasHistoryAPI,
                        activeRequests: hasActiveRequests,
                        variableHeight: hasVariableHeight,
                        realTimeElements: realTimeCount
                    }
                };
            } catch(e) {
                return { isDynamic: false, score: 0, error: e.message };
            }
        })()
        """
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(detectionScript) { result, error in
                if let data = result as? [String: Any],
                   let detected = data["isDynamic"] as? Bool {
                    isDynamic = detected
                    
                    if let score = data["score"] as? Int {
                        self.dbg("🔍 동적사이트 감지 점수: \(score)점 → \(detected ? "동적" : "정적")")
                    }
                }
                semaphore.signal()
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 0.5)
        return isDynamic
    }
    
    // MARK: - 🔧 **핵심 개선: 동적사이트 대응 원자적 캡처 작업**
    
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
        
        // 🎯 **2. 스크롤 위치 검증 시스템**
    private func validateScrollPosition(webView: WKWebView, expectedPosition: CGPoint, tolerance: CGFloat = 50) -> Bool {
        let currentPosition = webView.scrollView.contentOffset
        let yDiff = abs(currentPosition.y - expectedPosition.y)
        let xDiff = abs(currentPosition.x - expectedPosition.x)
        
        return yDiff <= tolerance && xDiff <= tolerance
    }
    
    // 🎯 **3. 동적사이트 안정화 대기 + 검증 캡처**
    private func performStabilizedCapture(task: CaptureTask, completion: @escaping () -> Void) {
        guard let webView = task.webView else {
            completion()
            return
        }
        
        let isDynamic = detectDynamicSite(webView: webView)
        let initialPosition = webView.scrollView.contentOffset
        
                        dbg("🔍 범용 콘텐츠 감지: \(task.pageRecord.title) - \(isDynamic ? "동적" : "정적")")
        
        if isDynamic {
            // 동적 콘텐츠: 안정화 대기 후 검증 캡처
            dbg("⏳ 동적 콘텐츠 안정화 대기 시작: \(task.pageRecord.title)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.performValidatedCapture(
                    task: task, 
                    expectedPosition: initialPosition,
                    retryCount: 3,
                    completion: completion
                )
            }
        } else {
            // 정적 콘텐츠: 즉시 캡처
            performDirectCapture(task: task)
            completion()
        }
    }
    
    // 🔄 **검증 및 재시도 캡처**
    private func performValidatedCapture(
        task: CaptureTask, 
        expectedPosition: CGPoint, 
        retryCount: Int,
        completion: @escaping () -> Void
    ) {
        guard let webView = task.webView, retryCount > 0 else {
            dbg("❌ 검증 캡처 재시도 소진: \(task.pageRecord.title)")
            performDirectCapture(task: task) // 최후 수단으로 직접 캡처
            completion()
            return
        }
        
        // 현재 스크롤 위치 검증
        if validateScrollPosition(webView: webView, expectedPosition: expectedPosition) {
            dbg("✅ 스크롤 위치 안정됨, 캡처 실행: \(task.pageRecord.title)")
            performDirectCapture(task: task)
            completion()
        } else {
            dbg("⚠️ 스크롤 위치 불안정, 재시도 (\(retryCount-1)회 남음): \(task.pageRecord.title)")
            
            // 0.2초 더 대기 후 재검증
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.performValidatedCapture(
                    task: task,
                    expectedPosition: expectedPosition,
                    retryCount: retryCount - 1,
                    completion: completion
                )
            }
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 중복 캡처 방지 (진행 중인 것만)
        guard !pendingCaptures.contains(pageID) else {
            dbg("⏸️ 중복 캡처 방지: \(task.pageRecord.title)")
            return
        }
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 진행 중 표시
        pendingCaptures.insert(pageID)
        dbg("🎯 범용 동적 콘텐츠 대응 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureReady = DispatchQueue.main.sync { () -> Bool in
            return webView.window != nil && !webView.bounds.isEmpty
        }
        
        guard captureReady else {
            dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🎯 **핵심: 동적사이트 안정화 캡처 적용**
        performStabilizedCapture(task: task) { [weak self] in
            // 캡처 완료 후 정리
            self?.pendingCaptures.remove(pageID)
            self?.dbg("✅ 범용 동적 콘텐츠 대응 캡처 완료: \(task.pageRecord.title)")
        }
    }
    
    // 🎯 **직접 캡처 (기존 로직)**
    private func performDirectCapture(task: CaptureTask) {
        guard let webView = task.webView else { return }
        
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else { return }
        
        // 캡처 실행
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        // 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: task.pageRecord.id)
        }
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
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
    
    // 🔍 **핵심 개선: 동적사이트 대응 스크롤 감지 JavaScript 생성**
    private func generateEnhancedScrollCaptureScript() -> String {
        return """
        (function() {
            try {
                // 🎯 **동적사이트 안정성 체크**
                function checkContentStability() {
                    // 로딩 중인 요소들 확인
                    const loadingElements = document.querySelectorAll('[loading], .loading, .spinner, .skeleton');
                    const lazyImages = document.querySelectorAll('img[loading="lazy"]:not([src])');
                    const isLoading = document.readyState !== 'complete';
                    
                    if (loadingElements.length > 0 || lazyImages.length > 0 || isLoading) {
                        console.log('⚠️ 콘텐츠 로딩 중:', {
                            loading: loadingElements.length,
                            lazyImages: lazyImages.length,
                            readyState: document.readyState
                        });
                        return false;
                    }
                    
                    return true;
                }
                
                // 🔍 **1단계: 범용 스크롤 요소 스캔 (안정성 확인 포함)**
                function findAllScrollableElements() {
                    const scrollables = [];
                    const maxElements = 50; // 성능 고려 제한
                    
                    // 동적사이트에서는 더 신중하게 스캔
                    const contentStable = checkContentStability();
                    if (!contentStable) {
                        console.log('⚠️ 콘텐츠 불안정 - 기본 스크롤만 캡처');
                        return []; // 불안정하면 상세 스크롤 스킵
                    }
                    
                    // 1) 명시적 overflow 스타일을 가진 요소들
                    const explicitScrollables = document.querySelectorAll('*');
                    let count = 0;
                    
                    for (const el of explicitScrollables) {
                        if (count >= maxElements) break;
                        
                        try {
                            const style = window.getComputedStyle(el);
                            const overflowY = style.overflowY;
                            const overflowX = style.overflowX;
                            
                            // 스크롤 가능한 요소 판별
                            if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                                (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) {
                                
                                // 🎯 **동적사이트 추가 검증**: 스크롤 위치 안정성 확인
                                const currentScrollTop = el.scrollTop;
                                const currentScrollLeft = el.scrollLeft;
                                
                                // 스크롤이 있고, DOM이 안정적인 경우만 저장
                                if ((currentScrollTop > 0 || currentScrollLeft > 0) && 
                                    !el.classList.contains('unstable') &&
                                    !el.hasAttribute('data-loading')) {
                                    
                                    const selector = generateBestSelector(el);
                                    if (selector) {
                                        scrollables.push({
                                            selector: selector,
                                            top: currentScrollTop,
                                            left: currentScrollLeft,
                                            maxTop: el.scrollHeight - el.clientHeight,
                                            maxLeft: el.scrollWidth - el.clientWidth,
                                            id: el.id || '',
                                            className: el.className || '',
                                            tagName: el.tagName.toLowerCase(),
                                            stability: 'verified' // 안정성 검증 완료 표시
                                        });
                                        count++;
                                    }
                                }
                            }
                        } catch(e) {
                            // 스타일 접근 실패 시 스킵
                            continue;
                        }
                    }
                    
                    // 2) 범용 동적 콘텐츠 컨테이너들 (사이트 무관)
                    const dynamicScrollContainers = [
                        '.scroll-container', '.scrollable', '.content', '.main', '.body',
                        '[data-scroll]', '[data-scrollable]', '.overflow-auto', '.overflow-scroll',
                        // 범용 동적 패턴 (기술적 특성)
                        '.feed-container', '.timeline', '.infinite-scroll', '.virtualized-list',
                        '.chat-messages', '.comments-list', '.posts-container', '.content-list',
                        '[data-infinite]', '[data-lazy]', '.dynamic-content', '[data-scroll-container]'
                    ];
                    
                    for (const selector of dynamicScrollContainers) {
                        if (count >= maxElements) break;
                        
                        try {
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
                                        tagName: el.tagName.toLowerCase(),
                                        stability: 'container-based'
                                    });
                                    count++;
                                }
                            }
                        } catch(e) {
                            console.warn('동적 컨테이너 스캔 실패:', selector, e);
                        }
                    }
                    
                    return scrollables;
                }
                
                // 🖼️ **2단계: iframe 스크롤 감지 (Same-Origin만) - 안정성 체크 추가**
                function detectIframeScrolls() {
                    const iframes = [];
                    const iframeElements = document.querySelectorAll('iframe');
                    
                    for (const iframe of iframeElements) {
                        try {
                            // Same-origin 체크
                            const contentWindow = iframe.contentWindow;
                            if (contentWindow && contentWindow.location) {
                                // 🎯 **iframe 로딩 상태 확인**
                                if (iframe.contentDocument && iframe.contentDocument.readyState !== 'complete') {
                                    console.log('⚠️ iframe 로딩 중 스킵:', iframe.src);
                                    continue;
                                }
                                
                                const scrollX = contentWindow.scrollX || 0;
                                const scrollY = contentWindow.scrollY || 0;
                                
                                if (scrollX > 0 || scrollY > 0) {
                                    iframes.push({
                                        selector: generateBestSelector(iframe) || `iframe[src*="${iframe.src.split('/').pop()}"]`,
                                        scrollX: scrollX,
                                        scrollY: scrollY,
                                        src: iframe.src || '',
                                        id: iframe.id || '',
                                        className: iframe.className || '',
                                        stability: 'iframe-verified'
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
                
                // 📏 **3단계: 동적 높이 요소 감지 (안정성 체크 강화)**
                function detectDynamicElements() {
                    const dynamics = [];
                    
                    // 동적 콘텐츠 안정성 먼저 확인
                    if (!checkContentStability()) {
                        console.log('⚠️ 동적 콘텐츠 불안정 - 동적 요소 스캔 스킵');
                        return dynamics;
                    }
                    
                    // 범용 동적 콘텐츠 컨테이너들 (기술적 특성 기반)
                    const dynamicSelectors = [
                        '[data-infinite]', '[data-lazy]', '.infinite-scroll',
                        '.lazy-load', '.dynamic-content', '.feed', '.timeline',
                        '[data-scroll-container]', '.virtualized',
                        // 추가 범용 동적 패턴
                        '.posts-container', '.content-list', '.comment-thread',
                        '.search-results', '.product-list', '.news-feed',
                        '[data-auto-load]', '[data-dynamic]', '.stream',
                        '.updates', '.notifications', '.activity-feed'
                    ];
                    
                    for (const selector of dynamicSelectors) {
                        try {
                            const elements = document.querySelectorAll(selector);
                            for (const el of elements) {
                                if ((el.scrollTop > 0 || el.scrollLeft > 0) &&
                                    !el.hasAttribute('data-loading') &&
                                    !el.classList.contains('loading')) {
                                    dynamics.push({
                                        selector: generateBestSelector(el) || selector,
                                        top: el.scrollTop,
                                        left: el.scrollLeft,
                                        type: 'dynamic-verified',
                                        stability: checkElementStability(el)
                                    });
                                }
                            }
                        } catch(e) {
                            console.warn('동적 요소 감지 실패:', selector, e);
                        }
                    }
                    
                    return dynamics;
                }
                
                // 🎯 **개별 요소 안정성 체크**
                function checkElementStability(element) {
                    try {
                        // 로딩 관련 클래스/속성 체크
                        const loadingIndicators = ['loading', 'spinner', 'skeleton', 'placeholder'];
                        const hasLoading = loadingIndicators.some(indicator => 
                            element.classList.contains(indicator) || 
                            element.hasAttribute(`data-${indicator}`)
                        );
                        
                        if (hasLoading) return 'unstable';
                        
                        // 높이 변화 감지 (간접적)
                        const hasFixedHeight = window.getComputedStyle(element).height !== 'auto';
                        return hasFixedHeight ? 'stable' : 'variable';
                    } catch(e) {
                        return 'unknown';
                    }
                }
                
                // 최적의 selector 생성 (개선된 버전)
                function generateBestSelector(element) {
                    if (!element || element.nodeType !== 1) return null;
                    
                    // 1순위: ID가 있으면 ID 사용 (안정성 체크 추가)
                    if (element.id && !/^(\\d|temp|auto|generated)/.test(element.id)) {
                        return `#${element.id}`;
                    }
                    
                    // 2순위: 고유한 클래스 조합
                    if (element.className) {
                        const classes = element.className.trim().split(/\\s+/)
                            .filter(cls => !/^(active|hover|focus|loading|temp)/.test(cls)); // 임시 클래스 제외
                        
                        const uniqueClasses = classes.filter(cls => {
                            try {
                                const elements = document.querySelectorAll(`.${cls}`);
                                return elements.length === 1 && elements[0] === element;
                            } catch(e) {
                                return false;
                            }
                        });
                        
                        if (uniqueClasses.length > 0) {
                            return `.${uniqueClasses[0]}`;
                        }
                        
                        // 클래스 조합으로 고유성 확보
                        if (classes.length > 0) {
                            const classSelector = `.${classes.join('.')}`;
                            try {
                                if (document.querySelectorAll(classSelector).length === 1) {
                                    return classSelector;
                                }
                            } catch(e) {
                                // 잘못된 클래스명은 스킵
                            }
                        }
                    }
                    
                    // 3순위: 태그명 + 안정한 속성
                    const tag = element.tagName.toLowerCase();
                    const attributes = [];
                    
                    // 안정한 data 속성 우선 (임시성 속성 제외)
                    for (const attr of element.attributes) {
                        if (attr.name.startsWith('data-') && 
                            !/^data-(loading|temp|auto|generated)/.test(attr.name)) {
                            attributes.push(`[${attr.name}="${attr.value}"]`);
                        }
                    }
                    
                    if (attributes.length > 0) {
                        const attrSelector = tag + attributes.join('');
                        try {
                            if (document.querySelectorAll(attrSelector).length === 1) {
                                return attrSelector;
                            }
                        } catch(e) {
                            // 잘못된 속성은 스킵
                        }
                    }
                    
                    // 4순위: nth-child 사용 (안정한 구조에서만)
                    let parent = element.parentElement;
                    if (parent && !parent.classList.contains('dynamic') && 
                        !parent.hasAttribute('data-dynamic')) {
                        const siblings = Array.from(parent.children);
                        const index = siblings.indexOf(element);
                        if (index !== -1 && siblings.length < 20) { // 너무 많은 자식이 있으면 불안정
                            return `${parent.tagName.toLowerCase()} > ${tag}:nth-child(${index + 1})`;
                        }
                    }
                    
                    // 최후: 태그명만
                    return tag;
                }
                
                // 🔍 **메인 실행 (안정성 우선 접근)**
                console.log('🔍 범용 동적 콘텐츠 감지 시작');
                
                // 기본 안정성 체크
                const contentStable = checkContentStability();
                console.log('📊 콘텐츠 안정성:', contentStable ? '안정' : '불안정');
                
                // 메인 스크롤은 항상 캡처 (가장 안정적)
                const mainScroll = {
                    x: window.scrollX || 0, 
                    y: window.scrollY || 0
                };
                
                // 상세 스크롤 요소들은 안정성에 따라 선택적 캡처
                let scrollableElements = [];
                let iframeScrolls = [];
                let dynamicElements = [];
                
                if (contentStable) {
                    // 안정한 상태에서만 상세 스크롤 감지
                    scrollableElements = findAllScrollableElements();
                    iframeScrolls = detectIframeScrolls();
                    dynamicElements = detectDynamicElements();
                } else {
                    console.log('⚠️ 콘텐츠 불안정으로 인한 상세 스크롤 감지 생략');
                }
                
                console.log(`🔍 스크롤 요소 감지 완료: 일반 ${scrollableElements.length}개, iframe ${iframeScrolls.length}개, 동적 ${dynamicElements.length}개`);
                
                return {
                    scroll: { 
                        x: mainScroll.x,
                        y: mainScroll.y,
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
                    },
                    stability: {
                        contentStable: contentStable,
                        readyState: document.readyState,
                        loadingElements: document.querySelectorAll('[loading], .loading, .spinner').length
                    }
                };
            } catch(e) { 
                console.error('스크롤 감지 실패:', e);
                // 실패해도 최소한의 정보는 반환
                return {
                    scroll: { x: window.scrollX || 0, y: window.scrollY || 0, elements: [] },
                    iframes: [],
                    href: window.location.href,
                    title: document.title,
                    stability: { contentStable: false, error: e.message }
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
            
            self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
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
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인 (스레드 안전)
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장 (최적화)
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title)")
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
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)]")
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
        
        dbg("BFCache 제스처 설정 완료")
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
                
                // 🎯 **동적 콘텐츠 대응 캡처**: 제스처 시작 전 안정화 캡처
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    // 동적 콘텐츠 감지
                    let isDynamic = detectDynamicSite(webView: webView)
                    
                    if isDynamic {
                        dbg("🔍 동적 콘텐츠 감지 - 안정화 캡처 적용: \(currentRecord.title)")
                        // 동적 콘텐츠는 0.3초 후 제스처 시작 (안정화 대기)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                            // 캡처 후 제스처 시작
                            self.startGestureAfterCapture(
                                gesture: gesture,
                                webView: webView,
                                stateModel: stateModel,
                                direction: direction,
                                tabID: tabID
                            )
                        }
                        return // 동적 콘텐츠는 여기서 대기
                    } else {
                        // 정적사이트는 즉시 캡처 후 진행
                        captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                    }
                }
                
                // 정적 콘텐츠 또는 캡처 불가능한 경우 즉시 제스처 시작
                startGestureAfterCapture(
                    gesture: gesture,
                    webView: webView,
                    stateModel: stateModel,
                    direction: direction,
                    tabID: tabID
                )
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
    
    // 🎯 **캡처 완료 후 제스처 시작** 
    private func startGestureAfterCapture(
        gesture: UIScreenEdgePanGestureRecognizer,
        webView: WKWebView,
        stateModel: WebViewStateModel, 
        direction: NavigationDirection,
        tabID: UUID
    ) {
        // 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
        captureCurrentSnapshot(webView: webView) { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.beginGestureTransitionWithSnapshot(
                    tabID: tabID,
                    webView: webView,
                    stateModel: stateModel,
                    direction: direction,
                    currentSnapshot: snapshot
                )
            }
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
                    self?.dbg("✅ 0.8초 고정 BFCache 복원 성공: \(currentRecord.title)")
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
    
    // MARK: - 버튼 네비게이션 (동적사이트 대응 캡처 적용)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🎯 **동적 콘텐츠 대응 캡처**
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            let isDynamic = detectDynamicSite(webView: webView)
            
            if isDynamic {
                dbg("🔍 버튼 네비게이션 - 동적 콘텐츠 안정화 캡처: \(currentRecord.title)")
                // 동적 콘텐츠는 0.2초 안정화 후 네비게이션
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        stateModel.goBack()
                        self.tryFixedBFCacheRestore(stateModel: stateModel, direction: .back)
                    }
                }
                return
            } else {
                // 정적 콘텐츠는 즉시 캡처
                captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
            }
        }
        
        stateModel.goBack()
        tryFixedBFCacheRestore(stateModel: stateModel, direction: .back)
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🎯 **동적 콘텐츠 대응 캡처**
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            let isDynamic = detectDynamicSite(webView: webView)
            
            if isDynamic {
                dbg("🔍 버튼 네비게이션 - 동적 콘텐츠 안정화 캡처: \(currentRecord.title)")
                // 동적 콘텐츠는 0.2초 안정화 후 네비게이션
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        stateModel.goForward()
                        self.tryFixedBFCacheRestore(stateModel: stateModel, direction: .forward)
                    }
                }
                return
            } else {
                // 정적 콘텐츠는 즉시 캡처
                captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
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
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔄 BFCache 페이지 복원');
                
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
        
        TabPersistenceManager.debugMessages.append("✅ 강화된 BFCache 시스템 설치 완료")
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

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출
extension BFCacheTransitionSystem {

    /// 사용자가 링크/폼으로 **떠나기 직전** 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 즉시 캡처 (최고 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📸 떠나기 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 캡처 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
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
