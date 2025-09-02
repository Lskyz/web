//
//  BFCacheSwipeTransition.swift
//  🎯 **안정성 강화된 BFCache 전환 시스템**
//  ✅ 직렬화 큐로 레이스 컨디션 완전 제거
//  🔄 원자적 연산으로 데이터 일관성 보장
//  📸 실패 복구 메커니즘 추가
//  ♾️ 무제한 영구 캐싱 (탭별 관리)
//  💾 스마트 메모리 관리 
//  🔧 **StateModel과 완벽 동기화**
//  🔧 **스냅샷 미스 수정 - 자동 캐시 강화**
//  🎬 **미리보기 컨테이너 타이밍 개선** - 복원 완료 후 제거
//  ⚡ **균형 잡힌 전환 속도 최적화 - 깜빡임 방지**
//  🛡️ **빠른 연속 제스처 먹통 방지** - 전환 중 차단 + 강제 정리
//  🌀 **DOM 동적 무한스크롤 저장/복원 추가** - 동적 로드 콘텐츠 지원
//  🧹 **클릭 상태 저장 제거** - 효과 없는 기능 정리
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
    
    // ⚡ **균형 잡힌 빠른 복원 메서드 - 깜빡임 방지**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 캡처 상태에 따른 복원 전략
        switch captureStatus {
        case .failed:
            // 즉시 실패 반환
            TabPersistenceManager.debugMessages.append("BFCache 캡처 실패 - 즉시 완료")
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
            // 정상적인 복원 진행
            break
        }
        
        TabPersistenceManager.debugMessages.append("BFCache 상태 복원 시작 (빠른 모드)")
        
        // ⚡ 즉시 상태 복원 시작 (깜빡임 방지를 위한 최소 대기)
        DispatchQueue.main.async {
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
        
        // ⚡ **적절한 스크롤 복원 - 깜빡임 방지**
        restoreSteps.append {
            let targetPos = self.scrollPosition
            TabPersistenceManager.debugMessages.append("🔄 스크롤 복원 시도: x=\(targetPos.x), y=\(targetPos.y)")
            
            // 1차: 네이티브 스크롤뷰 즉시 설정
            webView.scrollView.setContentOffset(targetPos, animated: false)
            
            // 2차: JavaScript로 강제 스크롤 (DOM 준비 대기 포함)
            let robustScrollJS = """
            (function() {
                function attemptScroll() {
                    try {
                        if (document.readyState !== 'complete') {
                            setTimeout(attemptScroll, 30); // ⚡ 25ms → 30ms (안정성)
                            return false;
                        }
                        
                        // 여러 방법으로 스크롤 시도
                        window.scrollTo(\(targetPos.x), \(targetPos.y));
                        document.documentElement.scrollTop = \(targetPos.y);
                        document.body.scrollTop = \(targetPos.y);
                        document.documentElement.scrollLeft = \(targetPos.x);
                        document.body.scrollLeft = \(targetPos.x);
                        
                        console.log('🔄 스크롤 복원 완료:', window.scrollY, window.scrollX);
                        return true;
                    } catch(e) {
                        console.error('🔄 스크롤 복원 실패:', e);
                        return false;
                    }
                }
                return attemptScroll();
            })()
            """
            
            webView.evaluateJavaScript(robustScrollJS) { result, error in
                let success = (result as? Bool) ?? false
                stepResults.append(success)
                
                if !success || targetPos.y > 0 {
                    // 3차: 추가 재시도 (WebKit 자동 스크롤 대응) - ⚡ 균형점 찾기
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        webView.scrollView.setContentOffset(targetPos, animated: false)
                        
                        // 4차: 최종 JavaScript 재시도 - ⚡ 안정성을 위한 적절한 대기
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            let finalScrollJS = "window.scrollTo(\(targetPos.x), \(targetPos.y)); window.scrollY >= \(targetPos.y - 50)"
                            webView.evaluateJavaScript(finalScrollJS) { finalResult, _ in
                                let finalSuccess = (finalResult as? Bool) ?? false
                                TabPersistenceManager.debugMessages.append("🔄 최종 스크롤 상태: \(finalSuccess ? "성공" : "실패")")
                                
                                // ⚡ 깜빡임 방지를 위한 최소 대기
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    nextStep()
                                }
                            }
                        }
                    }
                } else {
                    // ⚡ 성공 시에도 최소 대기로 안정성 확보
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        nextStep()
                    }
                }
            }
        }
        
        // 🌀 **DOM 동적 무한스크롤 복원**
        if let jsState = self.jsState,
           let s = jsState["scroll"] as? [String:Any],
           let els = s["elements"] as? [[String:Any]], !els.isEmpty {
            restoreSteps.append {
                let js = """
                (function(){
                    try{
                        const arr=\(self.convertScrollElementsToJSArray(els)); 
                        let ok=0;
                        
                        // 🌀 동적 무한스크롤 복원 - DOM 변경 감지 및 재시도
                        let retryCount = 0;
                        const maxRetries = 5;
                        
                        function restoreScrollPositions() {
                            for(const it of arr){
                                if(!it.selector) continue;
                                
                                const el = document.querySelector(it.selector);
                                if (el && el.scrollTop !== undefined) {
                                    el.scrollTop = it.top || 0;
                                    el.scrollLeft = it.left || 0;
                                    ok++;
                                }
                            }
                            
                            // 🌀 동적 콘텐츠 로딩 대기 및 재시도
                            if (ok < arr.length && retryCount < maxRetries) {
                                retryCount++;
                                setTimeout(restoreScrollPositions, 100);
                                console.log('🌀 동적 스크롤 복원 재시도:', retryCount);
                            }
                        }
                        
                        // 🌀 MutationObserver로 DOM 변경 감지
                        const observer = new MutationObserver((mutations) => {
                            restoreScrollPositions();
                        });
                        
                        // 감시 시작
                        observer.observe(document.body, {
                            childList: true,
                            subtree: true
                        });
                        
                        // 초기 복원 시도
                        restoreScrollPositions();
                        
                        // 5초 후 감시 중지
                        setTimeout(() => {
                            observer.disconnect();
                            console.log('🌀 DOM 감시 종료');
                        }, 5000);
                        
                        return ok>=0;
                    }catch(e){return false;}
                })()
                """
                webView.evaluateJavaScript(js) { result, _ in
                    stepResults.append((result as? Bool) ?? false)
                    
                    // ⚡ 안정성을 위한 적절한 대기 (0.02초 → 0.05초)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        nextStep()
                    }
                }
            }
        }
        
        nextStep()
    }
    
    // 안전한 JSON 변환 함수
    private func convertScrollElementsToJSArray(_ elements: [[String: Any]]) -> String {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: elements, options: [])
            return String(data: jsonData, encoding: .utf8) ?? "[]"
        } catch {
            TabPersistenceManager.debugMessages.append("스크롤 요소 JSON 변환 실패: \(error.localizedDescription)")
            return "[]"
        }
    }
}

// MARK: - 🎯 **안정성 강화된 BFCache 전환 시스템**
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
    }
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업**
    
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
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 진행 중 표시
        pendingCaptures.insert(pageID)
        dbg("🎯 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 유효한지 확인
            guard webView.window != nil else {
                self.dbg("❌ 웹뷰가 화면에 없음 - 캡처 취소")
                return nil
            }
            
            return CaptureData(
                bounds: webView.bounds,
                scrollPosition: webView.scrollView.contentOffset
            )
        }
        
        guard let captureData = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 스냅샷 캡처 (동기적)
        let snapshotResult = captureWebViewSnapshot(webView: webView, pageRecord: task.pageRecord, captureData: captureData)
        
        // 진행 중 표시 제거
        pendingCaptures.remove(pageID)
        
        // 결과 처리
        if snapshotResult.snapshot.captureStatus != .failed {
            // 메모리 캐시 저장
            setMemoryCache(snapshotResult.snapshot, for: pageID)
            
            // 디스크 저장 (비동기)
            if let tabID = task.tabID {
                saveToDisk(snapshot: snapshotResult, tabID: tabID)
            }
            
            dbg("✅ 캡처 성공: \(task.pageRecord.title) [상태: \(snapshotResult.snapshot.captureStatus)]")
        } else {
            dbg("❌ 캡처 실패: \(task.pageRecord.title)")
        }
    }
    
    // 캡처 데이터 구조
    private struct CaptureData {
        let bounds: CGRect
        let scrollPosition: CGPoint
    }
    
    // 🔧 **동기적 스냅샷 캡처 메서드**
    private func captureWebViewSnapshot(webView: WKWebView, pageRecord: PageRecord, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
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
        
        // 2. DOM 캡처 - 🧹 **클릭 상태 저장 제거**
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
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
        
        // 3. JS 상태 캡처 - 🌀 **DOM 동적 무한스크롤 처리**
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = """
            (function() {
                try {
                    // 🌀 **동적 무한스크롤 정보 수집**
                    const scrollableElements = [];
                    
                    // 메인 문서의 스크롤 가능한 요소들 수집
                    function collectScrollableElements(doc) {
                        const elements = doc.querySelectorAll('*');
                        elements.forEach((el, i) => {
                            if (scrollableElements.length >= 100) return; // 최대 100개로 증가 (무한스크롤 대응)
                            
                            if (el.scrollTop > 0 || el.scrollLeft > 0) {
                                // 🌀 더 정확한 선택자 생성 (동적 요소 대응)
                                let selector = el.tagName.toLowerCase();
                                
                                // ID가 있으면 우선 사용
                                if (el.id) {
                                    selector = '#' + el.id;
                                } 
                                // 클래스가 있으면 추가
                                else if (el.className) {
                                    const classes = el.className.split(' ').filter(c => c.length > 0);
                                    if (classes.length > 0) {
                                        selector += '.' + classes.join('.');
                                    }
                                    // 동일 클래스가 여러 개면 인덱스 추가
                                    const siblings = doc.querySelectorAll(selector);
                                    if (siblings.length > 1) {
                                        const index = Array.from(siblings).indexOf(el);
                                        selector += ':nth-of-type(' + (index + 1) + ')';
                                    }
                                }
                                // data 속성 체크 (동적 콘텐츠에서 자주 사용)
                                else if (el.dataset && Object.keys(el.dataset).length > 0) {
                                    const dataKey = Object.keys(el.dataset)[0];
                                    selector += '[data-' + dataKey + '="' + el.dataset[dataKey] + '"]';
                                }
                                
                                scrollableElements.push({
                                    selector: selector,
                                    top: el.scrollTop,
                                    left: el.scrollLeft,
                                    height: el.scrollHeight,
                                    width: el.scrollWidth
                                });
                            }
                        });
                    }
                    
                    // 메인 문서 스크롤 수집
                    collectScrollableElements(document);
                    
                    // 🌀 무한스크롤 상태 추가 정보
                    const infiniteScrollData = {
                        documentHeight: document.documentElement.scrollHeight,
                        viewportHeight: window.innerHeight,
                        hasMoreContent: document.querySelector('[data-infinite-scroll]') !== null,
                        loadedItemsCount: document.querySelectorAll('[data-infinite-item]').length
                    };
                    
                    return {
                        scroll: { 
                            x: window.scrollX, 
                            y: window.scrollY,
                            elements: scrollableElements,
                            infiniteScroll: infiniteScrollData
                        },
                        href: window.location.href,
                        title: document.title
                    };
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 0.8) // ⚡ 0.5초 → 0.8초 (안정성)
        
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
            let metadata = CacheMetadata(pageID: pageID, version: version, timestamp: Date())
            let metadataPath = pageDir.appendingPathComponent("metadata.json")
            if let metadataData = try? JSONEncoder().encode(metadata) {
                do {
                    try metadataData.write(to: metadataPath)
                    self.setDiskIndex(pageDir.path, for: pageID)
                    self.dbg("💾 메타데이터 저장 성공")
                } catch {
                    self.dbg("❌ 메타데이터 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 4. 이전 버전 정리 (최신 3개만 유지)
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
        }
    }
    
    // 메타데이터 구조
    private struct CacheMetadata: Codable {
        let pageID: UUID
        let version: Int
        let timestamp: Date
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            } catch {
                dbg("❌ 디렉토리 생성 실패: \(error)")
            }
        }
    }
    
    private func cleanupOldVersions(pageID: UUID, tabID: UUID, currentVersion: Int) {
        let tabDir = tabDirectory(for: tabID)
        let pagePrefix = "Page_\(pageID.uuidString)_v"
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            
            let pageDirs = contents.filter { $0.lastPathComponent.hasPrefix(pagePrefix) }
                .sorted { url1, url2 in
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
        // 1. 메모리 캐시 확인
        if let snapshot = memoryCache[pageID] {
            dbg("💾 메모리 캐시 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인
        if let diskPath = diskCacheIndex[pageID] {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에 로드
                setMemoryCache(snapshot, for: pageID)
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title)")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: pageID=\(pageID)")
        return nil
    }
    
    // MARK: - 메모리 관리
    
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func handleMemoryWarning() {
        cacheAccessQueue.async(flags: .barrier) {
            let oldCount = self._memoryCache.count
            self._memoryCache.removeAll()
            self.dbg("⚠️ 메모리 경고 - 캐시 정리: \(oldCount)개 항목 제거")
        }
    }
    
    // MARK: - 제스처 설정
    
    private func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        guard let tabID = stateModel.tabID else { return }
        
        // 네이티브 제스처 비활성화
        webView.allowsBackForwardNavigationGestures = false
        
        // 기존 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        // 컨텍스트 생성
        let context = WeakGestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
        
        // 좌측 엣지 (뒤로가기)
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        webView.addGestureRecognizer(leftEdge)
        objc_setAssociatedObject(leftEdge, "context", context, .OBJC_ASSOCIATION_RETAIN)
        
        // 우측 엣지 (앞으로가기)
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        webView.addGestureRecognizer(rightEdge)
        objc_setAssociatedObject(rightEdge, "context", context, .OBJC_ASSOCIATION_RETAIN)
        
        dbg("✅ 제스처 설정 완료: tabID=\(tabID)")
    }
    
    // MARK: - 🛡️ **빠른 연속 제스처 차단 개선**
    
    @objc private func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let context = objc_getAssociatedObject(gesture, "context") as? WeakGestureContext,
              let webView = context.webView,
              let stateModel = context.stateModel else { return }
        
        let tabID = context.tabID
        let translation = gesture.translation(in: webView)
        let velocity = gesture.velocity(in: webView)
        
        let isLeftEdge = gesture.edges == .left
        let width = webView.bounds.width
        let absX = abs(translation.x)
        let absY = abs(translation.y)
        let horizontalEnough = absX > absY * 1.5
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
                
                // 현재 페이지 즉시 캡처 (높은 우선순위)
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
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
            
        if targetIndex >= 0 && targetIndex < stateModel.dataModel.pageHistory.count {
            let targetRecord = stateModel.dataModel.pageHistory[targetIndex]
            
            if let snapshot = retrieveSnapshot(for: targetRecord.id),
               let image = snapshot.loadImage() {
                let targetView = UIImageView(image: image)
                targetView.contentMode = .scaleAspectFill
                targetView.clipsToBounds = true
                targetView.frame = webView.bounds
                targetView.frame.origin.x = direction == .back ? -webView.bounds.width : webView.bounds.width
                targetView.tag = 1002
                container.addSubview(targetView)
                dbg("🎬 타겟 미리보기 로드 성공: \(targetRecord.title)")
            } else {
                let placeholderView = UIView(frame: webView.bounds)
                placeholderView.backgroundColor = .systemBackground
                placeholderView.frame.origin.x = direction == .back ? -webView.bounds.width : webView.bounds.width
                placeholderView.tag = 1002
                container.addSubview(placeholderView)
                dbg("🎬 타겟 미리보기 플레이스홀더 사용")
            }
        }
        
        webView.addSubview(container)
        return container
    }
    
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = context.webView?.bounds.width ?? UIScreen.main.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        dbg("🎬 제스처 전환 완료 시작")
        
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
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
                // 🎬 **핵심 수정: 네비게이션 수행 후 스마트 대기 (터치 차단 최소화)**
                self?.performNavigationWithSmartTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🎬 **진짜 깜빡임 방지: 웹뷰 로딩 완료 후 제거**
    private func performNavigationWithSmartTiming(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel,
              let webView = context.webView else {
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
        
        // BFCache 복원 (비동기, 미리보기 제거와 무관)
        tryBFCacheRestoreAsync(stateModel: stateModel, direction: context.direction)
        
        // 🎯 **핵심: 웹뷰 로딩 완료 감지**
        var loadingObserver: NSKeyValueObservation?
        var hasRemoved = false
        
        let removePreview = {
            guard !hasRemoved else { return }
            hasRemoved = true
            loadingObserver?.invalidate()
            previewContainer.removeFromSuperview()
            self.activeTransitions.removeValue(forKey: context.tabID)
            self.dbg("🎬 미리보기 제거 - 웹뷰 로딩 완료")
        }
        
        // 로딩 상태 감지
        loadingObserver = webView.observe(\.isLoading, options: [.new]) { _, change in
            let isLoading = change.newValue ?? true
            if !isLoading {
                // 로딩 완료 - 약간의 대기 후 제거
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    removePreview()
                }
            }
        }
        
        // 타임아웃 설정 (최대 0.8초)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            removePreview()
        }
    }
    
    // 비동기 BFCache 복원 (미리보기와 독립적)
    private func tryBFCacheRestoreAsync(stateModel: WebViewStateModel, direction: NavigationDirection) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else { return }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ BFCache 상태 복원 성공: \(currentRecord.title) [상태: \(snapshot.captureStatus)]")
                } else {
                    self?.dbg("⚠️ BFCache 상태 복원 실패: \(currentRecord.title)")
                }
            }
        } else {
            dbg("❌ BFCache 미스: \(currentRecord.title)")
        }
    }
    
    private func cancelGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let previewContainer = context.previewContainer else { return }
        
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        dbg("🎬 제스처 전환 취소")
        
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                currentView?.frame.origin.x = 0
                targetView?.frame.origin.x = context.direction == .back ? 
                    -(context.webView?.bounds.width ?? 0) : 
                    (context.webView?.bounds.width ?? 0)
                currentView?.layer.shadowOpacity = 0
            },
            completion: { _ in
                previewContainer.removeFromSuperview()
                self.activeTransitions.removeValue(forKey: tabID)
            }
        )
    }
    
    // ⚡ **핵심 개선: 완료 콜백이 있는 네비게이션 - 대기 시간 최소화**
    private func performNavigation(context: TransitionContext, completion: @escaping (Bool) -> Void) {
        guard let stateModel = context.stateModel else { 
            completion(false)
            return 
        }
        
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // BFCache 복원 시도 (완료 콜백 포함)
        tryBFCacheRestore(stateModel: stateModel, direction: context.direction, completion: completion)
    }
    
    // ⚡ **균형 잡힌 BFCache 복원 - 깜빡임 방지**
    private func tryBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else { 
            completion(false)
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ BFCache 상태 복원 성공: \(currentRecord.title) [상태: \(snapshot.captureStatus)]")
                } else {
                    self?.dbg("⚠️ BFCache 상태 복원 실패: \(currentRecord.title)")
                }
                
                // ⚡ 균형 잡힌 완료 (깜빡임 방지: 0.05초 → 0.12초)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    completion(success)
                }
            }
        } else {
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            // ⚡ 미스 시 적절한 대기 (0.1초 → 0.15초)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                completion(false)
            }
        }
    }
    
    // MARK: - 버튼 네비게이션 (즉시 전환)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryBFCacheRestore(stateModel: stateModel, direction: .back) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        tryBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
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
    
    // MARK: - 헬퍼 메서드
    
    func hasCache(for pageID: UUID) -> Bool {
        return memoryCache[pageID] != nil || diskCacheIndex[pageID] != nil
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

    /// ⚡ **수정: 페이지 로드 완료 후 자동 캐시 강화 - 대기 시간 최소화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 캡처 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
        // ⚡ **추가: 이전 페이지들도 순차적으로 캐시 확인 및 캡처**
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
