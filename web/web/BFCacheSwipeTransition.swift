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
//  🎬 **미리보기 컨테이너 타이밍 개선** - 복원 완료 후 제거
//  ⚡ **균형 잡힌 전환 속도 최적화 - 깜빡임 방지**
//  🛡️ **빠른 연속 제스처 먹통 방지** - 전환 중 차단 + 강제 정리
//  🚫 **폼데이터/눌린상태 저장 제거** - 부작용 해결
//  🔍 **범용 스크롤 감지 강화** - iframe, 커스텀 컨테이너 지원
//  🔄 **다단계 복원 시스템** - 적응형 타이밍 학습
//  🎯 **핵심 수정: 동적 사이트 스냅샷 매칭 문제 해결**
//  🔧 **스냅샷 매칭 문제 완전 해결** - 강화된 디버깅 + 캐시 무결성 검증
//  🎯 **SPA 스냅샷 매칭 버그 수정** - 제스처 시작 시점 인덱스 고정
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

// MARK: - 🔄 적응형 타이밍 학습 시스템
struct SiteTimingProfile: Codable {
    let hostname: String
    var loadingSamples: [TimeInterval] = []
    var averageLoadingTime: TimeInterval = 0.5
    var successfulRestores: Int = 0
    var totalRestores: Int = 0
    var lastUpdated: Date = Date()
    
    var successRate: Double {
        guard totalRestores > 0 else { return 0.0 }
        return Double(successfulRestores) / Double(totalRestores)
    }
    
    mutating func recordLoadingTime(_ duration: TimeInterval) {
        loadingSamples.append(duration)
        // 최근 10개 샘플만 유지
        if loadingSamples.count > 10 {
            loadingSamples.removeFirst()
        }
        averageLoadingTime = loadingSamples.reduce(0, +) / Double(loadingSamples.count)
        lastUpdated = Date()
    }
    
    mutating func recordRestoreAttempt(success: Bool) {
        totalRestores += 1
        if success {
            successfulRestores += 1
        }
        lastUpdated = Date()
    }
    
    // 적응형 대기 시간 계산
    func getAdaptiveWaitTime(step: Int) -> TimeInterval {
        let baseTime = averageLoadingTime
        let stepMultiplier = Double(step) * 0.1
        let successFactor = successRate > 0.8 ? 0.8 : 1.0 // 성공률 높으면 빠르게
        return (baseTime + stepMultiplier) * successFactor
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
    
    // 🔧 **추가: 캐시 무결성 검증을 위한 추가 메타데이터**
    let urlHash: String  // URL의 해시값으로 추가 검증
    let titleSnapshot: String  // 캡처 시점의 제목
    let historyIndex: Int  // 🎯 **추가: 캡처 시점의 히스토리 인덱스**
    
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
        case urlHash
        case titleSnapshot
        case historyIndex
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
        
        // 🔧 **무결성 검증 필드 (없으면 기본값)**
        urlHash = try container.decodeIfPresent(String.self, forKey: .urlHash) ?? ""
        titleSnapshot = try container.decodeIfPresent(String.self, forKey: .titleSnapshot) ?? pageRecord.title
        historyIndex = try container.decodeIfPresent(Int.self, forKey: .historyIndex) ?? -1
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
        try container.encode(urlHash, forKey: .urlHash)
        try container.encode(titleSnapshot, forKey: .titleSnapshot)
        try container.encode(historyIndex, forKey: .historyIndex)
    }
    
    // 🔧 **수정된 초기화 - 무결성 검증 필드 추가**
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1, historyIndex: Int = -1) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.historyIndex = historyIndex
        
        // 🔧 **무결성 검증을 위한 추가 메타데이터**
        self.urlHash = String(pageRecord.url.absoluteString.hashValue)
        self.titleSnapshot = pageRecord.title
    }
    
    // 🔧 **무결성 검증 메서드**
    func validateIntegrity(against targetRecord: PageRecord) -> Bool {
        let targetUrlHash = String(targetRecord.url.absoluteString.hashValue)
        let urlMatches = (urlHash == targetUrlHash)
        let idMatches = (pageRecord.id == targetRecord.id)
        
        if !urlMatches || !idMatches {
            TabPersistenceManager.debugMessages.append("❌ 스냅샷 무결성 실패:")
            TabPersistenceManager.debugMessages.append("   저장된: ID=\(String(pageRecord.id.uuidString.prefix(8))), URL=\(pageRecord.url.absoluteString), 제목='\(titleSnapshot)', 인덱스=\(historyIndex)")
            TabPersistenceManager.debugMessages.append("   요청된: ID=\(String(targetRecord.id.uuidString.prefix(8))), URL=\(targetRecord.url.absoluteString), 제목='\(targetRecord.title)'")
            TabPersistenceManager.debugMessages.append("   URL일치: \(urlMatches), ID일치: \(idMatches)")
            return false
        }
        
        return true
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // ⚡ **다단계 복원 메서드 - 적응형 타이밍 적용**
    func restore(to webView: WKWebView, siteProfile: SiteTimingProfile?, completion: @escaping (Bool) -> Void) {
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
        
        TabPersistenceManager.debugMessages.append("BFCache 다단계 복원 시작 (적응형)")
        
        // 적응형 타이밍으로 다단계 복원 실행
        DispatchQueue.main.async {
            self.performMultiStepRestore(to: webView, siteProfile: siteProfile, completion: completion)
        }
    }
    
    // 🔄 **핵심: 다단계 복원 시스템**
    private func performMultiStepRestore(to webView: WKWebView, siteProfile: SiteTimingProfile?, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        // 사이트별 적응형 타이밍 계산
        let profile = siteProfile ?? SiteTimingProfile(hostname: "default")
        
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
        
        // **2단계: 주요 컨테이너 스크롤 복원 (적응형 대기)**
        if let jsState = self.jsState,
           let scrollData = jsState["scroll"] as? [String: Any],
           let elements = scrollData["elements"] as? [[String: Any]], !elements.isEmpty {
            
            restoreSteps.append((2, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 1)
                TabPersistenceManager.debugMessages.append("🔄 2단계: 컨테이너 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let containerScrollJS = self.generateContainerScrollScript(elements)
                    webView.evaluateJavaScript(containerScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **3단계: iframe 스크롤 복원 (더 긴 대기)**
        if let jsState = self.jsState,
           let iframeData = jsState["iframes"] as? [[String: Any]], !iframeData.isEmpty {
            
            restoreSteps.append((3, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 2)
                TabPersistenceManager.debugMessages.append("🔄 3단계: iframe 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let iframeScrollJS = self.generateIframeScrollScript(iframeData)
                    webView.evaluateJavaScript(iframeScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **4단계: 최종 확인 및 보정**
        restoreSteps.append((4, { stepCompletion in
            let waitTime = profile.getAdaptiveWaitTime(step: 3)
            TabPersistenceManager.debugMessages.append("🔄 4단계: 최종 보정 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
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
        loadSiteTimingProfiles()
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
    
    // 🔄 **사이트별 타이밍 프로파일**
    private var _siteTimingProfiles: [String: SiteTimingProfile] = [:]
    
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
    
    // 🔄 **사이트별 타이밍 프로파일 관리**
    private func getSiteProfile(for url: URL) -> SiteTimingProfile? {
        guard let hostname = url.host else { return nil }
        return cacheAccessQueue.sync { _siteTimingProfiles[hostname] }
    }
    
    private func updateSiteProfile(_ profile: SiteTimingProfile) {
        cacheAccessQueue.async(flags: .barrier) {
            self._siteTimingProfiles[profile.hostname] = profile
        }
        saveSiteTimingProfiles()
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
    
    // 전환 컨텍스트 - 🎯 **제스처 시작 시점 스냅샷 추가**
    private struct TransitionContext {
        let tabID: UUID
        weak var webView: WKWebView?
        weak var stateModel: WebViewStateModel?
        var isGesture: Bool
        var direction: NavigationDirection
        var initialTransform: CGAffineTransform
        var previewContainer: UIView?
        var currentSnapshot: UIImage?
        let gestureStartIndex: Int  // 🎯 **추가: 제스처 시작 시점의 인덱스**
        let targetPageRecord: PageRecord?  // 🎯 **추가: 제스처 시작 시점에 결정된 타겟**
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    enum CaptureType {
        case immediate  // 현재 페이지 (높은 우선순위)
        case background // 과거 페이지 (일반 우선순위)
    }
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (강화된 스크롤 감지)**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
        let historyIndex: Int  // 🎯 **추가: 캡처 시점의 히스토리 인덱스**
    }
    
    // 중복 방지를 위한 진행 중인 캡처 추적
    private var pendingCaptures: Set<UUID> = []
    
    // 🔧 **강화된 디버깅: 캡처 시작 시 상세 로깅**
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil, historyIndex: Int = -1) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        dbg("📸 캡처 요청: '\(pageRecord.title)' [ID: \(String(pageRecord.id.uuidString.prefix(8)))] URL: \(pageRecord.url.absoluteString) 인덱스: \(historyIndex)")
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView, historyIndex: historyIndex)
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    // 🎯 **핵심 수정 2: 현재 상태 기반 캡처 메서드 추가**
    func captureCurrentPageSnapshot(webView: WKWebView, stateModel: WebViewStateModel, type: CaptureType = .immediate) {
        guard let currentRecord = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else {
            dbg("❌ 현재 페이지 캡처 실패: 현재 레코드 없음")
            return
        }
        
        let currentIndex = stateModel.dataModel.currentPageIndex
        
        // 🔧 **강화된 디버깅: 현재 상태 상세 로깅**
        dbg("📸 현재 페이지 캡처 시작:")
        dbg("   제목: '\(currentRecord.title)'")
        dbg("   ID: \(String(currentRecord.id.uuidString.prefix(8)))")
        dbg("   URL: \(currentRecord.url.absoluteString)")
        dbg("   인덱스: \(currentIndex)/\(stateModel.dataModel.pageHistory.count)")
        dbg("   TabID: \(String(tabID.uuidString.prefix(8)))")
        
        captureSnapshot(pageRecord: currentRecord, webView: webView, type: type, tabID: tabID, historyIndex: currentIndex)
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
        dbg("🎯 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type)) [ID: \(String(pageID.uuidString.prefix(8)))] 인덱스: \(task.historyIndex)")
        
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
                isLoading: webView.isLoading,
                historyIndex: task.historyIndex
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🔧 **개선된 캡처 로직 - 실패 시 재시도**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
        )
        
        // 🔧 **강화된 디버깅: 캡처 결과 상세 로깅**
        dbg("📸 캡처 완료: '\(task.pageRecord.title)' [ID: \(String(pageID.uuidString.prefix(8)))], 상태: \(captureResult.snapshot.captureStatus), 인덱스: \(captureResult.snapshot.historyIndex)")
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        // 진행 중 해제
        pendingCaptures.remove(pageID)
        dbg("✅ 직렬 캡처 완료: \(task.pageRecord.title) [ID: \(String(pageID.uuidString.prefix(8)))]")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
        let historyIndex: Int
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
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, timestamp: Date(), captureStatus: .failed, version: 1, historyIndex: captureData.historyIndex), nil)
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
            version: version,
            historyIndex: captureData.historyIndex  // 🎯 **히스토리 인덱스 저장**
        )
        
        return (snapshot, visualSnapshot)
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
                                        selector: generateBestSelector(iframe) || `iframe[src*="${iframe.src.split('/').pop()}"]`,
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
                        return `#${element.id}`;
                    }
                    
                    // 2순위: 고유한 클래스 조합
                    if (element.className) {
                        const classes = element.className.trim().split(/\\s+/);
                        const uniqueClasses = classes.filter(cls => {
                            const elements = document.querySelectorAll(`.${cls}`);
                            return elements.length === 1 && elements[0] === element;
                        });
                        
                        if (uniqueClasses.length > 0) {
                            return `.${uniqueClasses[0]}`;
                        }
                        
                        // 클래스 조합으로 고유성 확보
                        if (classes.length > 0) {
                            const classSelector = `.${classes.join('.')}`;
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
                            attributes.push(`[${attr.name}="${attr.value}"]`);
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
                            return `${parent.tagName.toLowerCase()} > ${tag}:nth-child(${index + 1})`;
                        }
                    }
                    
                    // 최후: 태그명만
                    return tag;
                }
                
                // 🔍 **메인 실행**
                const scrollableElements = findAllScrollableElements();
                const iframeScrolls = detectIframeScrolls();
                const dynamicElements = detectDynamicElements();
                
                console.log(`🔍 스크롤 요소 감지: 일반 ${scrollableElements.length}개, iframe ${iframeScrolls.length}개, 동적 ${dynamicElements.length}개`);
                
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
                title: snapshot.snapshot.pageRecord.title,
                historyIndex: snapshot.snapshot.historyIndex  // 🎯 **히스토리 인덱스 저장**
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
            
            // 🔧 **강화된 디버깅: 저장 완료 후 상세 정보**
            self.dbg("💾 디스크 저장 완료:")
            self.dbg("   제목: '\(snapshot.snapshot.pageRecord.title)'")
            self.dbg("   ID: \(String(pageID.uuidString.prefix(8)))")
            self.dbg("   URL: \(snapshot.snapshot.pageRecord.url.absoluteString)")
            self.dbg("   버전: v\(version)")
            self.dbg("   상태: \(snapshot.snapshot.captureStatus)")
            self.dbg("   인덱스: \(snapshot.snapshot.historyIndex)")
            
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
        let historyIndex: Int  // 🎯 **추가: 히스토리 인덱스**
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
    
    // MARK: - 🔄 **사이트별 타이밍 프로파일 관리**
    
    private func loadSiteTimingProfiles() {
        if let data = UserDefaults.standard.data(forKey: "BFCache.SiteTimingProfiles"),
           let profiles = try? JSONDecoder().decode([String: SiteTimingProfile].self, from: data) {
            cacheAccessQueue.async(flags: .barrier) {
                self._siteTimingProfiles = profiles
            }
            dbg("🔄 사이트 타이밍 프로파일 로드: \(profiles.count)개")
        }
    }
    
    private func saveSiteTimingProfiles() {
        let profiles = cacheAccessQueue.sync { _siteTimingProfiles }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "BFCache.SiteTimingProfiles")
        }
    }
    
    // MARK: - 🔍 **핵심 수정: 강화된 스냅샷 조회 시스템 (무결성 검증 추가)**
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        // 1. 먼저 메모리 캐시 확인 (스레드 안전)
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: '\(snapshot.pageRecord.title)' [ID: \(String(pageID.uuidString.prefix(8)))] 인덱스: \(snapshot.historyIndex)")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인 (스레드 안전)
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장 (최적화)
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: '\(snapshot.pageRecord.title)' [ID: \(String(pageID.uuidString.prefix(8)))] 인덱스: \(snapshot.historyIndex)")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: [ID: \(String(pageID.uuidString.prefix(8)))]")
        return nil
    }
    
    // 🔧 **핵심 수정: 무결성 검증이 포함된 안전한 조회 메서드**
    private func retrieveSnapshotSafely(for targetRecord: PageRecord) -> BFCacheSnapshot? {
        let pageID = targetRecord.id
        
        // 기본 조회
        guard let snapshot = retrieveSnapshot(for: pageID) else {
            dbg("❌ 캐시 미스: '\(targetRecord.title)' [ID: \(String(pageID.uuidString.prefix(8)))]")
            return nil
        }
        
        // 🔧 **무결성 검증**
        guard snapshot.validateIntegrity(against: targetRecord) else {
            dbg("❌ 무결성 검증 실패 - 캐시 제거: '\(targetRecord.title)' [ID: \(String(pageID.uuidString.prefix(8)))]")
            
            // 오염된 캐시 제거
            removeFromMemoryCache(pageID)
            
            // 디스크에서도 제거 (백그라운드)
            diskIOQueue.async { [weak self] in
                guard let self = self,
                      let diskPath = self.cacheAccessQueue.sync(execute: { self._diskCacheIndex[pageID] }) else { return }
                
                let pageDir = URL(fileURLWithPath: diskPath)
                try? FileManager.default.removeItem(at: pageDir)
                
                self.cacheAccessQueue.async(flags: .barrier) {
                    self._diskCacheIndex.removeValue(forKey: pageID)
                    self._cacheVersion.removeValue(forKey: pageID)
                }
                
                self.dbg("🗑️ 오염된 캐시 디스크 삭제: '\(targetRecord.title)' [ID: \(String(pageID.uuidString.prefix(8)))]")
            }
            
            return nil
        }
        
        dbg("✅ 무결성 검증 통과: '\(targetRecord.title)' [ID: \(String(pageID.uuidString.prefix(8)))] 인덱스: \(snapshot.historyIndex)")
        return snapshot
    }
    
    // 🎯 **핵심 버그 수정: 제스처 시작 시점에 타겟을 확정하는 메서드**
    private func determineTargetAtGestureStart(stateModel: WebViewStateModel, direction: NavigationDirection) -> (index: Int, record: PageRecord?, snapshot: BFCacheSnapshot?) {
        let currentIndex = stateModel.dataModel.currentPageIndex
        let pageHistory = stateModel.dataModel.pageHistory
        
        // 🔧 **디버깅 강화: 제스처 시작 시점의 정확한 상태**
        dbg("🎯 제스처 시작 시점 타겟 결정:")
        dbg("   현재 인덱스: \(currentIndex)")
        dbg("   전체 히스토리: \(pageHistory.count)개")
        dbg("   방향: \(direction == .back ? "뒤로가기" : "앞으로가기")")
        
        if !pageHistory.isEmpty && currentIndex >= 0 && currentIndex < pageHistory.count {
            let currentRecord = pageHistory[currentIndex]
            dbg("   현재 페이지: '\(currentRecord.title)' [ID: \(String(currentRecord.id.uuidString.prefix(8)))]")
        }
        
        let targetIndex = direction == .back ? currentIndex - 1 : currentIndex + 1
        
        guard targetIndex >= 0 && targetIndex < pageHistory.count else {
            dbg("❌ 타겟 인덱스 범위 초과: \(targetIndex), 범위: 0..<\(pageHistory.count)")
            return (targetIndex, nil, nil)
        }
        
        let targetRecord = pageHistory[targetIndex]
        let targetSnapshot = retrieveSnapshotSafely(for: targetRecord)
        
        dbg("🎯 타겟 확정:")
        dbg("   타겟 인덱스: \(targetIndex)")
        dbg("   타겟 제목: '\(targetRecord.title)'")
        dbg("   타겟 ID: \(String(targetRecord.id.uuidString.prefix(8)))")
        dbg("   타겟 URL: \(targetRecord.url.absoluteString)")
        dbg("   캐시 상태: \(targetSnapshot != nil ? "✅ 있음" : "❌ 없음")")
        
        if let snapshot = targetSnapshot {
            dbg("   스냅샷 버전: v\(snapshot.version)")
            dbg("   스냅샷 상태: \(snapshot.captureStatus)")
            dbg("   스냅샷 인덱스: \(snapshot.historyIndex)")
        }
        
        return (targetIndex, targetRecord, targetSnapshot)
    }
    
    // 🔧 **핵심 수정: hasCache 메서드 추가**
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
        dbg("💭 메모리 캐시 저장: '\(snapshot.pageRecord.title)' [v\(snapshot.version)] [ID: \(String(pageID.uuidString.prefix(8)))] 인덱스: \(snapshot.historyIndex)")
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
                
                // 🎯 **핵심 수정: 제스처 시작 시점에 타겟 확정**
                let currentIndex = stateModel.dataModel.currentPageIndex
                let (targetIndex, targetRecord, targetSnapshot) = determineTargetAtGestureStart(
                    stateModel: stateModel, 
                    direction: direction
                )
                
                // 🎯 **현재 페이지 즉시 캡처**
                captureCurrentPageSnapshot(webView: webView, stateModel: stateModel, type: .immediate)
                
                // 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
                captureCurrentSnapshot(webView: webView) { [weak self] snapshot in
                    self?.beginGestureTransitionWithSnapshot(
                        tabID: tabID,
                        webView: webView,
                        stateModel: stateModel,
                        direction: direction,
                        currentSnapshot: snapshot,
                        gestureStartIndex: currentIndex,
                        targetPageRecord: targetRecord,
                        targetSnapshot: targetSnapshot
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
    
    // 🎯 **수정된 메서드: 타겟 정보를 파라미터로 받음**
    private func beginGestureTransitionWithSnapshot(
        tabID: UUID, 
        webView: WKWebView, 
        stateModel: WebViewStateModel, 
        direction: NavigationDirection, 
        currentSnapshot: UIImage?,
        gestureStartIndex: Int,
        targetPageRecord: PageRecord?,
        targetSnapshot: BFCacheSnapshot?
    ) {
        let initialTransform = webView.transform
        
        let previewContainer = createPreviewContainerWithTarget(
            webView: webView,
            direction: direction,
            currentSnapshot: currentSnapshot,
            targetPageRecord: targetPageRecord,
            targetSnapshot: targetSnapshot
        )
        
        let context = TransitionContext(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            isGesture: true,
            direction: direction,
            initialTransform: initialTransform,
            previewContainer: previewContainer,
            currentSnapshot: currentSnapshot,
            gestureStartIndex: gestureStartIndex,
            targetPageRecord: targetPageRecord
        )
        activeTransitions[tabID] = context
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기") (시작 인덱스: \(gestureStartIndex))")
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
    
    // 🎯 **새로운 메서드: 확정된 타겟으로 프리뷰 컨테이너 생성**
    private func createPreviewContainerWithTarget(
        webView: WKWebView, 
        direction: NavigationDirection, 
        currentSnapshot: UIImage? = nil,
        targetPageRecord: PageRecord?,
        targetSnapshot: BFCacheSnapshot?
    ) -> UIView {
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
        
        // 🎯 **이미 확정된 타겟 사용**
        var targetView: UIView
        
        if let record = targetPageRecord {
            if let snapshot = targetSnapshot,
               let targetImage = snapshot.loadImage() {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
                dbg("📸 타겟 페이지 BFCache 스냅샷 사용: '\(record.title)' [ID: \(String(record.id.uuidString.prefix(8)))]")
            } else {
                targetView = createInfoCard(for: record, in: webView.bounds)
                dbg("ℹ️ 타겟 페이지 정보 카드 생성: '\(record.title)' [ID: \(String(record.id.uuidString.prefix(8)))]")
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
        
        // 🎯 **추가: PageRecord ID 표시 (디버깅용)**
        let idLabel = UILabel()
        idLabel.translatesAutoresizingMaskIntoConstraints = false
        idLabel.text = "ID: \(String(record.id.uuidString.prefix(8)))"
        idLabel.font = .systemFont(ofSize: 10)
        idLabel.textColor = .quaternaryLabel
        idLabel.textAlignment = .center
        contentView.addSubview(idLabel)
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 200),
            
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            timeLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 8),
            timeLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            
            idLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 4),
            idLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            idLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
        
        return card
    }
    
    // 🎬 **핵심 개선: 미리보기 컨테이너 타이밍 수정 - 적응형 타이밍 적용**
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
                // 🎬 **적응형 타이밍으로 네비게이션 수행**
                self?.performNavigationWithAdaptiveTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🔄 **적응형 타이밍을 적용한 네비게이션 수행**
    private func performNavigationWithAdaptiveTiming(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            // 실패 시 즉시 정리
            previewContainer.removeFromSuperview()
            activeTransitions.removeValue(forKey: context.tabID)
            return
        }
        
        // 로딩 시간 측정 시작
        let navigationStartTime = Date()
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // 🔄 **적응형 BFCache 복원 + 타이밍 학습**
        tryAdaptiveBFCacheRestore(stateModel: stateModel, direction: context.direction, navigationStartTime: navigationStartTime) { [weak self] success in
            // BFCache 복원 완료 또는 실패 시 즉시 정리 (깜빡임 최소화)
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - BFCache \(success ? "성공" : "실패")")
            }
        }
        
        // 🛡️ **안전장치: 최대 1초 후 강제 정리** (적응형 타이밍으로 조금 더 여유)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.activeTransitions[context.tabID] != nil {
                previewContainer.removeFromSuperview()
                self?.activeTransitions.removeValue(forKey: context.tabID)
                self?.dbg("🛡️ 미리보기 강제 정리 (1초 타임아웃)")
            }
        }
    }
    
    // 🔄 **적응형 BFCache 복원 + 타이밍 학습** 
    private func tryAdaptiveBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, navigationStartTime: Date, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // 사이트별 프로파일 조회/생성
        var siteProfile = getSiteProfile(for: currentRecord.url) ?? SiteTimingProfile(hostname: currentRecord.url.host ?? "unknown")
        
        // 🔧 **핵심 수정: 안전한 조회 사용**
        if let snapshot = retrieveSnapshotSafely(for: currentRecord) {
            // BFCache 히트 - 적응형 복원
            snapshot.restore(to: webView, siteProfile: siteProfile) { [weak self] success in
                // 로딩 시간 기록
                let loadingDuration = Date().timeIntervalSince(navigationStartTime)
                siteProfile.recordLoadingTime(loadingDuration)
                siteProfile.recordRestoreAttempt(success: success)
                self?.updateSiteProfile(siteProfile)
                
                if success {
                    self?.dbg("✅ 적응형 BFCache 복원 성공: \(currentRecord.title) (소요: \(String(format: "%.2f", loadingDuration))초)")
                } else {
                    self?.dbg("⚠️ 적응형 BFCache 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 기본 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            let loadingDuration = Date().timeIntervalSince(navigationStartTime)
            siteProfile.recordLoadingTime(loadingDuration)
            siteProfile.recordRestoreAttempt(success: false)
            updateSiteProfile(siteProfile)
            
            // 기본 대기 시간 적용
            let waitTime = siteProfile.getAdaptiveWaitTime(step: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
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
    
    // MARK: - 버튼 네비게이션 (즉시 전환)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🎯 **핵심 수정 7: 현재 페이지 명시적 캡처**
        captureCurrentPageSnapshot(webView: webView, stateModel: stateModel, type: .immediate)
        
        stateModel.goBack()
        tryAdaptiveBFCacheRestore(stateModel: stateModel, direction: .back, navigationStartTime: Date()) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 🎯 **핵심 수정 8: 현재 페이지 명시적 캡처**
        captureCurrentPageSnapshot(webView: webView, stateModel: stateModel, type: .immediate)
        
        stateModel.goForward()
        tryAdaptiveBFCacheRestore(stateModel: stateModel, direction: .forward, navigationStartTime: Date()) { _ in
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

    /// 🎯 **핵심 수정 9: 사용자가 링크/폼으로 떠나기 직전 현재 페이지 저장 (명시적 캡처)**
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        dbg("📸 떠나기 스냅샷 캡처 요청")
        captureCurrentPageSnapshot(webView: webView, stateModel: stateModel, type: .immediate)
    }

    /// 🎯 **핵심 수정 10: 페이지 로드 완료 후 자동 캐시 강화 (명시적 캡처)**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        dbg("📸 도착 스냅샷 캡처 요청")
        
        // 현재 페이지 캡처 (백그라운드 우선순위)
        captureCurrentPageSnapshot(webView: webView, stateModel: stateModel, type: .background)
        
        // 🔧 **개선된 이전 페이지 캐시 강화 로직**
        if let tabID = stateModel.tabID, stateModel.dataModel.currentPageIndex > 0 {
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
                        version: 1,
                        historyIndex: i  // 🎯 **정확한 히스토리 인덱스 저장**
                    )
                    
                    // 디스크에 메타데이터만 저장
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)] [ID: \(String(previousRecord.id.uuidString.prefix(8)))]")
                }
            }
        }
    }
}
