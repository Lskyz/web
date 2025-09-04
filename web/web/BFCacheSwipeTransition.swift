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
//  🎯 **앵커 + 아이템 기반 정밀 복원** - selector/key/textHash 매칭
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

// MARK: - 🎯 앵커/아이템 데이터 구조
struct AnchorData: Codable {
    let selector: String?
    let key: String?
    let textHash: Int?
}

struct ItemData: Codable {
    let selector: String?
    let key: String?
    let textHash: Int?
    let parentSelector: String?
    let indexHint: Int?
}

struct ScrollContainer: Codable {
    let selector: String
    let top: CGFloat
    let left: CGFloat
}

struct ViewportData: Codable {
    let innerHeight: CGFloat
    let visualHeight: CGFloat
}

struct InsetsData: Codable {
    let safeBottom: CGFloat
    let adjustedBottom: CGFloat
}

struct IframeScroll: Codable {
    let selector: String
    let scrollX: CGFloat
    let scrollY: CGFloat
    let sameOrigin: Bool
}

// MARK: - 📸 BFCache 페이지 스냅샷
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    let scrollRatio: Double // 추가: 비율 기반 복원용
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    // 🎯 앵커/아이템 기반 복원 데이터
    let anchor: AnchorData?
    let item: ItemData?
    let containers: [ScrollContainer]?
    let viewport: ViewportData?
    let insets: InsetsData?
    let iframes: [IframeScroll]?
    
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
        case scrollRatio
        case jsState
        case timestamp
        case webViewSnapshotPath
        case captureStatus
        case version
        case anchor
        case item
        case containers
        case viewport
        case insets
        case iframes
    }
    
    // Custom encoding/decoding for [String: Any]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        scrollRatio = try container.decodeIfPresent(Double.self, forKey: .scrollRatio) ?? 0.0
        
        // JSON decode for [String: Any]
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        version = try container.decode(Int.self, forKey: .version)
        
        // 새로운 필드들
        anchor = try container.decodeIfPresent(AnchorData.self, forKey: .anchor)
        item = try container.decodeIfPresent(ItemData.self, forKey: .item)
        containers = try container.decodeIfPresent([ScrollContainer].self, forKey: .containers)
        viewport = try container.decodeIfPresent(ViewportData.self, forKey: .viewport)
        insets = try container.decodeIfPresent(InsetsData.self, forKey: .insets)
        iframes = try container.decodeIfPresent([IframeScroll].self, forKey: .iframes)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        try container.encode(scrollRatio, forKey: .scrollRatio)
        
        // JSON encode for [String: Any]
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
        
        // 새로운 필드들
        try container.encodeIfPresent(anchor, forKey: .anchor)
        try container.encodeIfPresent(item, forKey: .item)
        try container.encodeIfPresent(containers, forKey: .containers)
        try container.encodeIfPresent(viewport, forKey: .viewport)
        try container.encodeIfPresent(insets, forKey: .insets)
        try container.encodeIfPresent(iframes, forKey: .iframes)
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, scrollRatio: Double = 0.0, jsState: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1, anchor: AnchorData? = nil, item: ItemData? = nil, containers: [ScrollContainer]? = nil, viewport: ViewportData? = nil, insets: InsetsData? = nil, iframes: [IframeScroll]? = nil) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.scrollRatio = scrollRatio
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
        self.anchor = anchor
        self.item = item
        self.containers = containers
        self.viewport = viewport
        self.insets = insets
        self.iframes = iframes
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // ⚡ **다단계 복원 메서드 - 앵커/아이템 기반**
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
        
        TabPersistenceManager.debugMessages.append("BFCache 다단계 복원 시작 (앵커/아이템 기반)")
        
        // 적응형 타이밍으로 다단계 복원 실행
        DispatchQueue.main.async {
            self.performMultiStepRestore(to: webView, siteProfile: siteProfile, completion: completion)
        }
    }
    
    // 🔄 **핵심: 앵커/아이템 기반 다단계 복원**
    private func performMultiStepRestore(to webView: WKWebView, siteProfile: SiteTimingProfile?, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        // 사이트별 적응형 타이밍 계산
        let profile = siteProfile ?? SiteTimingProfile(hostname: "default")
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        // **1단계: 비율 기반 1차 정렬 (0ms)**
        restoreSteps.append((1, { stepCompletion in
            TabPersistenceManager.debugMessages.append("🔄 1단계: 비율 기반 초기 정렬")
            
            let restoreJS = """
            (function() {
                try {
                    const vh = window.visualViewport?.height || window.innerHeight;
                    const maxTop = Math.max(1, document.documentElement.scrollHeight - vh);
                    const targetY = Math.round(\(self.scrollRatio) * maxTop);
                    window.scrollTo(0, targetY);
                    return true;
                } catch(e) { return false; }
            })()
            """
            
            webView.evaluateJavaScript(restoreJS) { result, _ in
                let success = (result as? Bool) ?? false
                TabPersistenceManager.debugMessages.append("🔄 1단계 완료: \(success ? "성공" : "실패")")
                stepCompletion(success)
            }
        }))
        
        // **2단계: 앵커 복원 (적응형 대기)**
        if let anchor = self.anchor {
            restoreSteps.append((2, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 1)
                TabPersistenceManager.debugMessages.append("🔄 2단계: 앵커 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let anchorJS = self.generateAnchorRestoreScript(anchor)
                    webView.evaluateJavaScript(anchorJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **3단계: 아이템 정밀 복원**
        if let item = self.item {
            restoreSteps.append((3, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 2)
                TabPersistenceManager.debugMessages.append("🔄 3단계: 아이템 정밀 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let itemJS = self.generateItemRestoreScript(item)
                    webView.evaluateJavaScript(itemJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **4단계: 컨테이너 보정**
        if let containers = self.containers, !containers.isEmpty {
            restoreSteps.append((4, { stepCompletion in
                let waitTime = profile.getAdaptiveWaitTime(step: 3)
                TabPersistenceManager.debugMessages.append("🔄 4단계: 컨테이너 스크롤 보정 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let containerJS = self.generateContainerRestoreScript(containers)
                    webView.evaluateJavaScript(containerJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🔄 4단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **5단계: 최종 검증 및 적응 루프**
        restoreSteps.append((5, { stepCompletion in
            let waitTime = profile.getAdaptiveWaitTime(step: 4)
            TabPersistenceManager.debugMessages.append("🔄 5단계: 최종 검증 및 적응 루프 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                let adaptiveJS = self.generateAdaptiveLoopScript(targetY: self.scrollPosition.y, item: self.item)
                webView.evaluateJavaScript(adaptiveJS) { result, _ in
                    let success = (result as? Bool) ?? false
                    TabPersistenceManager.debugMessages.append("🔄 5단계 완료: \(success ? "성공" : "실패")")
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
    
    // 앵커 복원 스크립트 생성
    private func generateAnchorRestoreScript(_ anchor: AnchorData) -> String {
        let selectorEscaped = anchor.selector?.replacingOccurrences(of: "'", with: "\\'") ?? ""
        let keyEscaped = anchor.key?.replacingOccurrences(of: "'", with: "\\'") ?? ""
        
        return """
        (function() {
            try {
                // 앵커 찾기
                let anchorEl = null;
                
                // 1) selector로 찾기
                if ('\(selectorEscaped)') {
                    try {
                        anchorEl = document.querySelector('\(selectorEscaped)');
                    } catch(e) {}
                }
                
                // 2) key로 찾기
                if (!anchorEl && '\(keyEscaped)') {
                    anchorEl = document.querySelector(`[data-key="\(keyEscaped)"]`) ||
                               document.querySelector(`[data-id="\(keyEscaped)"]`) ||
                               document.querySelector(`a[href="\(keyEscaped)"]`);
                }
                
                if (anchorEl) {
                    anchorEl.scrollIntoView({block: 'center', inline: 'nearest'});
                    console.log('앵커 복원 성공:', anchorEl);
                    return true;
                }
                
                return false;
            } catch(e) {
                console.error('앵커 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 아이템 복원 스크립트 생성
    private func generateItemRestoreScript(_ item: ItemData) -> String {
        let selectorEscaped = item.selector?.replacingOccurrences(of: "'", with: "\\'") ?? ""
        let keyEscaped = item.key?.replacingOccurrences(of: "'", with: "\\'") ?? ""
        let textHash = item.textHash ?? 0
        
        return """
        (function() {
            try {
                function findItem() {
                    // 1) selector로 찾기
                    if ('\(selectorEscaped)') {
                        try {
                            const el = document.querySelector('\(selectorEscaped)');
                            if (el) return el;
                        } catch(e) {}
                    }
                    
                    // 2) key로 찾기
                    if ('\(keyEscaped)') {
                        const el = document.querySelector(`[data-key="\(keyEscaped)"]`) ||
                                   document.querySelector(`[data-id="\(keyEscaped)"]`) ||
                                   document.querySelector(`[data-item-id="\(keyEscaped)"]`) ||
                                   document.querySelector(`a[href="\(keyEscaped)"]`) ||
                                   document.querySelector(`img[src="\(keyEscaped)"]`);
                        if (el) return el;
                    }
                    
                    // 3) textHash로 찾기
                    if (\(textHash) !== 0) {
                        let best = null, diff = 1e9;
                        const pool = document.querySelectorAll('li,article,[role="article"],[data-key],[data-id],a[href],[data-item-id]');
                        for (const e of pool) {
                            const t = (e.textContent || '').trim().slice(0, 256);
                            let x = 0;
                            for (let i = 0; i < t.length; i++) {
                                x = (x * 31 + t.charCodeAt(i)) | 0;
                            }
                            const d = Math.abs(x - \(textHash));
                            if (d < diff) {
                                best = e;
                                diff = d;
                            }
                        }
                        if (best) return best;
                    }
                    
                    return null;
                }
                
                const item = findItem();
                if (item) {
                    item.scrollIntoView({block: 'center', inline: 'nearest'});
                    console.log('아이템 복원 성공:', item);
                    return true;
                }
                
                return false;
            } catch(e) {
                console.error('아이템 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 컨테이너 복원 스크립트 생성
    private func generateContainerRestoreScript(_ containers: [ScrollContainer]) -> String {
        let containersJSON = containers.map { container in
            return """
            {selector: '\(container.selector.replacingOccurrences(of: "'", with: "\\'"))', top: \(container.top), left: \(container.left)}
            """
        }.joined(separator: ",")
        
        return """
        (function() {
            try {
                const containers = [\(containersJSON)];
                let restored = 0;
                
                for (const container of containers) {
                    try {
                        const el = document.querySelector(container.selector);
                        if (el && typeof el.scrollTop === 'number') {
                            el.scrollTop = container.top;
                            el.scrollLeft = container.left;
                            restored++;
                        }
                    } catch(e) {}
                }
                
                console.log('컨테이너 복원:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('컨테이너 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 적응 루프 스크립트 생성
    private func generateAdaptiveLoopScript(targetY: CGFloat, item: ItemData?) -> String {
        let keyEscaped = item?.key?.replacingOccurrences(of: "'", with: "\\'") ?? ""
        let textHash = item?.textHash ?? 0
        
        return """
        (async function() {
            const wait = ms => new Promise(r => setTimeout(r, ms));
            
            try {
                // 아이템이 있으면 적응 루프 실행
                if (\(item != nil)) {
                    for (let i = 0; i < 5; i++) {
                        await wait(100);
                        
                        // 아이템 재탐색
                        let item = null;
                        if ('\(keyEscaped)') {
                            item = document.querySelector(`[data-key="\(keyEscaped)"]`) ||
                                   document.querySelector(`[data-id="\(keyEscaped)"]`);
                        }
                        
                        if (!item && \(textHash) !== 0) {
                            // textHash로 찾기
                            let best = null, diff = 1e9;
                            const pool = document.querySelectorAll('li,article,[role="article"],[data-key],[data-id]');
                            for (const e of pool) {
                                const t = (e.textContent || '').trim().slice(0, 256);
                                let x = 0;
                                for (let j = 0; j < t.length; j++) {
                                    x = (x * 31 + t.charCodeAt(j)) | 0;
                                }
                                const d = Math.abs(x - \(textHash));
                                if (d < diff) {
                                    best = e;
                                    diff = d;
                                }
                            }
                            item = best;
                        }
                        
                        if (!item) break;
                        
                        const r = item.getBoundingClientRect();
                        const vh = window.visualViewport?.height || window.innerHeight;
                        const center = vh / 2;
                        const delta = (r.top + r.height / 2) - center;
                        
                        // 중앙 ±10% 이내면 성공
                        if (Math.abs(delta) < center * 0.1) {
                            console.log('아이템 중앙 정렬 성공');
                            return true;
                        }
                        
                        window.scrollBy(0, delta);
                    }
                }
                
                // 최종 위치 보정
                const currentY = window.scrollY;
                const errorPx = Math.abs(currentY - \(targetY));
                if (errorPx > 20) {
                    window.scrollTo(0, \(targetY));
                }
                
                return errorPx <= 20;
            } catch(e) {
                console.error('적응 루프 실패:', e);
                return false;
            }
        })()
        """
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
        setupSnapshotUpdateObserver()
    }
    
    // MARK: - 📸 **핵심 개선: 단일 직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // MARK: - 💾 스레드 안전 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]

    // 🧮 스냅샷 버전 저장소 (전용 직렬 큐로 원자 처리)
private let versionQueue = DispatchQueue(label: "bfcache.version", qos: .userInitiated)
private var _cacheVersion: [UUID: Int] = [:]

@inline(__always)
private func nextVersion(for id: UUID) -> Int {
    return versionQueue.sync {
        let v = (_cacheVersion[id] ?? 0) + 1
        _cacheVersion[id] = v
        return v
    }
}

@inline(__always)
private func setVersion(_ v: Int, for id: UUID) {
    versionQueue.sync {
        _cacheVersion[id] = v
    }
}

@inline(__always)
private func clearVersion(for id: UUID) {
    versionQueue.sync {
        _cacheVersion.removeValue(forKey: id)
    }
}

    
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
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (앵커/아이템 캡처 추가)**
    
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
    
    pprivate func performAtomicCapture(_ task: CaptureTask) {
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

    // 안정 상태 대기 (immediate 타입은 즉시, background는 대기)
    if task.type == .background {
        waitForStableState(webView: webView) { [weak self] in
            guard let self = self else { return }
            // ⬇️ 콜백은 메인에서 오니까 직렬 큐로 되돌려 캡처 실행
            self.serialQueue.async {
                self.performCaptureAfterStable(task: task)
            }
        }
    } else {
        // immediate는 지금 serialQueue 위라 그대로 진행
        performCaptureAfterStable(task: task)
    }
}

    
    private func waitForStableState(webView: WKWebView, completion: @escaping () -> Void) {
        let stableScript = """
        (async function() {
            const wait = ms => new Promise(r => setTimeout(r, ms));
            
            // readyState 대기
            while (document.readyState !== 'complete') {
                await wait(100);
            }
            
            // 이미지 로딩 대기
            const images = Array.from(document.images);
            for (const img of images) {
                if (!img.complete) {
                    await new Promise(r => img.onload = r);
                }
            }
            
            // DOM 변경 감지
            let lastMutationTime = Date.now();
            const observer = new MutationObserver(() => {
                lastMutationTime = Date.now();
            });
            observer.observe(document.body, { childList: true, subtree: true });
            
            // 150ms 동안 DOM 변경 없을 때까지 대기
            while (Date.now() - lastMutationTime < 150) {
                await wait(50);
            }
            
            observer.disconnect();
            return true;
        })()
        """
        
        DispatchQueue.main.async {
            webView.evaluateJavaScript(stableScript) { _, _ in
                completion()
            }
        }
    }
    
    private func performCaptureAfterStable(task: CaptureTask) {
        guard let webView = task.webView else {
            pendingCaptures.remove(task.pageRecord.id)
            return
        }
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = mainSyncOrNow { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            // 키보드 숨기기
            webView.evaluateJavaScript("document.activeElement?.blur()", completionHandler: nil)
            
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
        dbg("✅ 직렬 캡처 완료: \(task.pageRecord.title)")
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
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        // 여기까지 오면 모든 시도 실패
let scrollHeight = mainSyncOrNow { webView.scrollView.contentSize.height }
let scrollRatio = scrollHeight > 0 ? captureData.scrollPosition.y / scrollHeight : 0.0

return (
    BFCacheSnapshot(
        pageRecord: pageRecord,
        scrollPosition: captureData.scrollPosition,
        scrollRatio: scrollRatio,
        timestamp: Date(),
        captureStatus: .failed,
        version: 1
    ),
    nil
)
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var anchorData: AnchorData? = nil
        var itemData: ItemData? = nil
        var containers: [ScrollContainer]? = nil
        var viewportData: ViewportData? = nil
        var insetsData: InsetsData? = nil
        var iframeScrolls: [IframeScroll]? = nil
        
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        mainSyncOrNow {
    let config = WKSnapshotConfiguration()
    config.rect = captureData.bounds
    config.afterScreenUpdates = false
    
    webView.takeSnapshot(with: config) { image, error in
        if let error = error {
            self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
            visualSnapshot = self.renderWebViewToImage(webView)
        } else {
            visualSnapshot = image
        }
        semaphore.signal()
    }
}

        
        // ⚡ 적절한 타임아웃 (2.5초)
        let result = semaphore.wait(timeout: .now() + 2.5)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처
        let domSemaphore = DispatchSemaphore(value: 0)
        mainSyncOrNow {
        let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 🚫 눌린 상태/활성 상태 모두 제거
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
        _ = domSemaphore.wait(timeout: .now() + 0.8)
        
        // 3. 🎯 앵커/아이템 기반 JS 상태 캡처
        let jsSemaphore = DispatchSemaphore(value: 0)
mainSyncOrNow {
    let jsScript = generateEnhancedCaptureScript()
    webView.evaluateJavaScript(jsScript) { result, error in
        if let data = result as? [String: Any] {
                    jsState = data
                    
                    // 앵커 데이터 추출
                    if let anchorDict = data["anchor"] as? [String: Any] {
                        anchorData = AnchorData(
                            selector: anchorDict["selector"] as? String,
                            key: anchorDict["key"] as? String,
                            textHash: anchorDict["textHash"] as? Int
                        )
                    }
                    
                    // 아이템 데이터 추출
                    if let itemDict = data["item"] as? [String: Any] {
                        itemData = ItemData(
                            selector: itemDict["selector"] as? String,
                            key: itemDict["key"] as? String,
                            textHash: itemDict["textHash"] as? Int,
                            parentSelector: itemDict["parentSelector"] as? String,
                            indexHint: itemDict["indexHint"] as? Int
                        )
                    }
                    
                    // 컨테이너 데이터 추출
                    if let containerArray = data["containers"] as? [[String: Any]] {
                        containers = containerArray.compactMap { dict in
                            guard let selector = dict["selector"] as? String,
                                  let top = dict["top"] as? Double,
                                  let left = dict["left"] as? Double else { return nil }
                            return ScrollContainer(selector: selector, top: CGFloat(top), left: CGFloat(left))
                        }
                    }
                    
                    // 뷰포트 데이터 추출
                    if let vpDict = data["viewport"] as? [String: Any],
                       let innerH = vpDict["innerH"] as? Double,
                       let visualH = vpDict["visualH"] as? Double {
                        viewportData = ViewportData(innerHeight: CGFloat(innerH), visualHeight: CGFloat(visualH))
                    }
                    
                    // 인셋 데이터 추출
                    if let insetDict = data["insets"] as? [String: Any],
                       let safeBottom = insetDict["safeBottom"] as? Double,
                       let adjustedBottom = insetDict["adjustedBottom"] as? Double {
                        insetsData = InsetsData(safeBottom: CGFloat(safeBottom), adjustedBottom: CGFloat(adjustedBottom))
                    }
                    
                    // iframe 데이터 추출
                    if let iframeArray = data["iframes"] as? [[String: Any]] {
                        iframeScrolls = iframeArray.compactMap { dict in
                            guard let selector = dict["selector"] as? String,
                                  let scrollX = dict["scrollX"] as? Double,
                                  let scrollY = dict["scrollY"] as? Double,
                                  let sameOrigin = dict["sameOrigin"] as? Bool else { return nil }
                            return IframeScroll(selector: selector, scrollX: CGFloat(scrollX), scrollY: CGFloat(scrollY), sameOrigin: sameOrigin)
                        }
                    }
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 1.2)
        
        // 스크롤 비율 계산
        let scrollHeight = DispatchQueue.main.sync { () -> CGFloat in
            return webView.scrollView.contentSize.height
        }
        let scrollRatio = scrollHeight > 0 ? captureData.scrollPosition.y / scrollHeight : 0.0
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil && anchorData != nil && itemData != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = (jsState != nil || anchorData != nil || itemData != nil) ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 버전 증가 (스레드 안전)
        let version: Int = nextVersion(for: pageRecord.id)

        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            scrollRatio: scrollRatio,
            jsState: jsState,
            timestamp: Date(),
            webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
            captureStatus: captureStatus,
            version: version,
            anchor: anchorData,
            item: itemData,
            containers: containers,
            viewport: viewportData,
            insets: insetsData,
            iframes: iframeScrolls
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🎯 **핵심 개선: 앵커/아이템 기반 캡처 JavaScript 생성**
    private func generateEnhancedCaptureScript() -> String {
        return """
        (function() {
            try {
                function H(s){let x=0;for(let i=0;i<s.length;i++)x=(x*31+s.charCodeAt(i))|0;return x;}
                
                // 🎯 앵커 캡처
                function captureAnchor() {
                    const hints = ['#app', '#root', 'main', '[role="main"]', 'article', '[data-key]', '[data-id]'];
                    let anchor = null;
                    
                    // 힌트 우선
                    for (const hint of hints) {
                        const el = document.querySelector(hint);
                        if (el) {
                            anchor = el;
                            break;
                        }
                    }
                    
                    // 없으면 뷰포트 중앙 근처
                    if (!anchor) {
                        const center = window.innerHeight / 2;
                        const candidates = document.querySelectorAll('article, section, [id], a[href]');
                        let best = null, dist = 1e9;
                        
                        for (const el of candidates) {
                            const r = el.getBoundingClientRect();
                            const mid = r.top + r.height / 2;
                            const d = Math.abs(mid - center);
                            if (d < dist) {
                                best = el;
                                dist = d;
                            }
                        }
                        anchor = best;
                    }
                    
                    if (!anchor) return null;
                    
                    const selector = anchor.id ? '#' + CSS.escape(anchor.id) : null;
                    const key = anchor.getAttribute('data-key') || anchor.getAttribute('data-id') || 
                               anchor.getAttribute('href') || null;
                    const textHash = H((anchor.textContent || '').trim().slice(0, 256));
                    
                    return {selector, key, textHash};
                }
                
                // 🎯 아이템 캡처
                function captureItem() {
                    const center = (window.visualViewport?.height || window.innerHeight) / 2;
                    const q = 'li,article,[role="article"],[data-key],[data-id],a[href],[data-item-id]';
                    const cands = document.querySelectorAll(q);
                    let best = null, dist = 1e9;
                    
                    for (const el of cands) {
                        const r = el.getBoundingClientRect();
                        const mid = r.top + r.height / 2;
                        const d = Math.abs(mid - center);
                        if (d < dist) {
                            best = el;
                            dist = d;
                        }
                    }
                    
                    if (!best) return null;
                    
                    const sel = best.id ? '#' + CSS.escape(best.id) : null;
                    const key = best.getAttribute('data-key') || best.getAttribute('data-id') ||
                               best.getAttribute('data-item-id') || best.getAttribute('href') ||
                               best.getAttribute('src') || null;
                    const txt = (best.textContent || '').trim().slice(0, 256);
                    
                    // 스크롤 가능한 부모 찾기
                    function scrollableParent(el) {
                        let p = el.parentElement;
                        while (p) {
                            const s = getComputedStyle(p);
                            if ((/auto|scroll/).test(s.overflowY) || (/auto|scroll/).test(s.overflow)) return p;
                            p = p.parentElement;
                        }
                        return document.scrollingElement || document.documentElement;
                    }
                    
                    const parent = scrollableParent(best);
                    const idx = (() => {
                        if (!parent || parent === document.documentElement) return null;
                        const sib = Array.from(parent.children).filter(n => n.tagName === best.tagName);
                        const i = sib.indexOf(best);
                        return i >= 0 ? i : null;
                    })();
                    
                    return {
                        selector: sel,
                        key: key,
                        textHash: H(txt),
                        parentSelector: parent && parent !== document.documentElement
                                        ? (parent.id ? '#' + CSS.escape(parent.id) : null) : null,
                        indexHint: idx
                    };
                }
                
                // 컨테이너 스크롤 캡처
                function captureContainers() {
                    const selectors = ['.content', '.container', '.scroll', '.scrollable', '.list', '.feed', '[data-scroll]'];
                    const containers = [];
                    
                    for (const sel of selectors) {
                        const elements = document.querySelectorAll(sel);
                        for (const el of elements) {
                            if (el.scrollTop > 0 || el.scrollLeft > 0) {
                                containers.push({
                                    selector: sel,
                                    top: el.scrollTop,
                                    left: el.scrollLeft
                                });
                            }
                        }
                    }
                    
                    return containers;
                }
                
                // iframe 스크롤 캡처
                function captureIframes() {
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
                                        selector: iframe.id ? '#' + CSS.escape(iframe.id) : 
                                                 `iframe[src*="${iframe.src.split('/').pop()}"]`,
                                        scrollX: scrollX,
                                        scrollY: scrollY,
                                        sameOrigin: true
                                    });
                                }
                            }
                        } catch(e) {
                            // Cross-origin iframe
                            iframes.push({
                                selector: iframe.src ? `iframe[src*="${iframe.src.split('/').pop()}"]` : 'iframe',
                                scrollX: 0,
                                scrollY: 0,
                                sameOrigin: false
                            });
                        }
                    }
                    
                    return iframes;
                }
                
                // 메인 실행
                const docHeight = document.documentElement.scrollHeight;
                const viewportHeight = window.visualViewport?.height || window.innerHeight;
                
                return {
                    scroll: { 
                        y: window.scrollY,
                        ratio: docHeight > viewportHeight ? window.scrollY / (docHeight - viewportHeight) : 0
                    },
                    anchor: captureAnchor(),
                    item: captureItem(),
                    containers: captureContainers(),
                    viewport: {
                        innerH: window.innerHeight,
                        visualH: window.visualViewport?.height || window.innerHeight
                    },
                    insets: {
                        safeBottom: window.visualViewport ? window.innerHeight - window.visualViewport.height : 0,
                        adjustedBottom: 0
                    },
                    iframes: captureIframes(),
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now()
                };
            } catch(e) { 
                console.error('캡처 실패:', e);
                return {
                    scroll: { y: window.scrollY, ratio: 0 },
                    anchor: null,
                    item: null,
                    containers: [],
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
            
            // 5. 스냅샷 업데이트 알림 발송
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .BFCacheSnapshotDidUpdate,
                    object: nil,
                    userInfo: ["pageID": pageID]
                )
            }
            
            // 6. 이전 버전 정리 (최신 3개만 유지)
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
                self.clearVersion(for: pageID)

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
    
    // MARK: - 🎬 스냅샷 업데이트 옵저버 (정보카드 동적 교체용)
    
    private func setupSnapshotUpdateObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSnapshotUpdate(_:)),
            name: .BFCacheSnapshotDidUpdate,
            object: nil
        )
    }
    
    @objc private func handleSnapshotUpdate(_ notification: Notification) {
        guard let pageID = notification.userInfo?["pageID"] as? UUID else { return }
        
        // 활성 전환 중인 것들에서 해당 페이지의 미리보기 업데이트
        for (_, context) in activeTransitions {
            if let targetIndex = context.direction == .back ?
                context.stateModel?.dataModel.currentPageIndex.advanced(by: -1) :
                context.stateModel?.dataModel.currentPageIndex.advanced(by: 1),
               targetIndex >= 0,
               targetIndex < (context.stateModel?.dataModel.pageHistory.count ?? 0),
               context.stateModel?.dataModel.pageHistory[targetIndex].id == pageID {
                
                // 스냅샷 다시 로드하고 미리보기 업데이트
                if let snapshot = retrieveSnapshot(for: pageID),
                   let image = snapshot.loadImage(),
                   let previewContainer = context.previewContainer,
                   let targetView = previewContainer.viewWithTag(1002) {
                    
                    DispatchQueue.main.async {
                        // 정보카드를 이미지로 교체
                        if let imageView = targetView as? UIImageView {
                            imageView.image = image
                        } else {
                            // 정보카드를 제거하고 이미지뷰로 교체
                            let newImageView = UIImageView(image: image)
                            newImageView.frame = targetView.frame
                            newImageView.tag = 1002
                            newImageView.contentMode = .scaleAspectFill
                            newImageView.clipsToBounds = true
                            
                            targetView.removeFromSuperview()
                            previewContainer.addSubview(newImageView)
                        }
                        
                        self.dbg("🎬 미리보기 동적 업데이트: \(snapshot.pageRecord.title)")
                    }
                }
            }
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
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
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
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryAdaptiveBFCacheRestore(stateModel: stateModel, direction: .back, navigationStartTime: Date()) { _ in
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
        TabPersistenceManager.debugMessages.append("[BFCache] \(msg)")
    }
}

// MARK: - UIGestureRecognizerDelegate
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - 스냅샷 업데이트 노티피케이션
extension Notification.Name {
    static let BFCacheSnapshotDidUpdate = Notification.Name("BFCacheSnapshotDidUpdate")
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

    // 메인스레드 재진입 안전 래퍼 (메인이면 즉시, 아니면 동기 디스패치)
@inline(__always)
private func mainSyncOrNow<T>(_ work: () -> T) -> T {
    if Thread.isMainThread { return work() }
    return DispatchQueue.main.sync { work() }
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
                        scrollRatio: 0.0,
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
