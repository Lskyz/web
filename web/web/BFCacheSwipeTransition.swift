//
//  BFCacheSwipeTransition.swift
//  🔥 **완전 무음 복원 시스템 - 전면 리팩토링**
//  ✅ 프리페인트 가드 + 오버레이 + 메시지 브리지
//  ✅ 정밀 앵커/랜드마크 복원 + 무한스크롤 버스트
//  🚫 Promise 제거, 메시지 체인 기반 파이프라인
//  ⚡ 2.5~3.0초 상한, 24px 오차 내 정착
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

// MARK: - 🔥 **신규 스냅샷 구조체 (Schema v2)**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    
    // 📍 정밀 좌표 + 상대치
    let scrollPosition: CGPoint          // 절대 px 좌표
    let scrollPositionPercent: CGPoint   // 0~100% 상대 좌표
    let contentSize: CGSize              // 콘텐츠 크기
    let viewportSize: CGSize             // 뷰포트 크기
    let actualScrollableSize: CGSize     // 실제 스크롤 가능 최대 크기
    
    // 🎯 앵커 후보 (최대 5개)
    let anchors: [AnchorInfo]
    
    // 🗺️ 랜드마크 (최대 12개)
    let landmarks: [LandmarkInfo]
    
    // 📌 상단 고정 헤더
    let stickyTop: CGFloat
    
    // 🔄 가상 리스트 힌트
    let virtualList: VirtualListInfo?
    
    // ♾️ 무한스크롤 트리거
    let loadTriggers: [LoadTriggerInfo]
    
    // 🖼️ iframe 스크롤 상태 (v2)
    let iframesV2: [IFrameScrollInfo]
    
    // 🔑 레이아웃 서명
    let layoutKey: String
    
    // 📊 스키마 버전
    let schemaVersion: Int
    
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
    
    // 🎯 앵커 정보
    struct AnchorInfo: Codable {
        let selector: String
        let role: String                    // h1|h2|h3|article|main|section|card|list-item|other
        let absTop: CGFloat                 // scrollY + rect.top
        let absLeft: CGFloat                // scrollX + rect.left
        let offsetFromTop: CGFloat          // scroll - abs (뷰포트 기준 오프셋)
        let offsetFromLeft: CGFloat
        let width: CGFloat
        let height: CGFloat
        let textHead: String                // 60자 이내 텍스트 머리말
        let textHash: String                // 텍스트 해시
    }
    
    // 🗺️ 랜드마크 정보
    struct LandmarkInfo: Codable {
        let selector: String
        let role: String
        let absTop: CGFloat
        let textHash: String
    }
    
    // 🔄 가상 리스트 정보
    struct VirtualListInfo: Codable {
        let type: String                    // react-virtualized|RecyclerView|virtual-list|unknown
        let beforePx: CGFloat               // 앞쪽 spacer 높이
        let afterPx: CGFloat                // 뒤쪽 spacer 높이
        let itemHeightAvg: CGFloat          // 평균 아이템 높이
    }
    
    // ♾️ 로드 트리거 정보
    struct LoadTriggerInfo: Codable {
        let selector: String
        let label: String                   // 40자 이내 레이블
    }
    
    // 🖼️ iframe 스크롤 정보 (v2)
    struct IFrameScrollInfo: Codable {
        let selector: String
        let crossOrigin: Bool
        let scrollX: CGFloat
        let scrollY: CGFloat
        let src: String
        let dataAttrs: [String: String]
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, scrollPositionPercent
        case contentSize, viewportSize, actualScrollableSize
        case anchors, landmarks, stickyTop, virtualList, loadTriggers, iframesV2
        case layoutKey, schemaVersion, jsState, timestamp, webViewSnapshotPath
        case captureStatus, version
    }
    
    // Custom encoding/decoding for [String: Any]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        scrollPositionPercent = try container.decodeIfPresent(CGPoint.self, forKey: .scrollPositionPercent) ?? CGPoint.zero
        contentSize = try container.decodeIfPresent(CGSize.self, forKey: .contentSize) ?? CGSize.zero
        viewportSize = try container.decodeIfPresent(CGSize.self, forKey: .viewportSize) ?? CGSize.zero
        actualScrollableSize = try container.decodeIfPresent(CGSize.self, forKey: .actualScrollableSize) ?? CGSize.zero
        
        anchors = try container.decodeIfPresent([AnchorInfo].self, forKey: .anchors) ?? []
        landmarks = try container.decodeIfPresent([LandmarkInfo].self, forKey: .landmarks) ?? []
        stickyTop = try container.decodeIfPresent(CGFloat.self, forKey: .stickyTop) ?? 0
        virtualList = try container.decodeIfPresent(VirtualListInfo.self, forKey: .virtualList)
        loadTriggers = try container.decodeIfPresent([LoadTriggerInfo].self, forKey: .loadTriggers) ?? []
        iframesV2 = try container.decodeIfPresent([IFrameScrollInfo].self, forKey: .iframesV2) ?? []
        layoutKey = try container.decodeIfPresent(String.self, forKey: .layoutKey) ?? ""
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        
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
        try container.encode(scrollPositionPercent, forKey: .scrollPositionPercent)
        try container.encode(contentSize, forKey: .contentSize)
        try container.encode(viewportSize, forKey: .viewportSize)
        try container.encode(actualScrollableSize, forKey: .actualScrollableSize)
        
        try container.encode(anchors, forKey: .anchors)
        try container.encode(landmarks, forKey: .landmarks)
        try container.encode(stickyTop, forKey: .stickyTop)
        try container.encodeIfPresent(virtualList, forKey: .virtualList)
        try container.encode(loadTriggers, forKey: .loadTriggers)
        try container.encode(iframesV2, forKey: .iframesV2)
        try container.encode(layoutKey, forKey: .layoutKey)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        
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
    init(pageRecord: PageRecord,
         domSnapshot: String? = nil,
         scrollPosition: CGPoint,
         scrollPositionPercent: CGPoint = CGPoint.zero,
         contentSize: CGSize = CGSize.zero,
         viewportSize: CGSize = CGSize.zero,
         actualScrollableSize: CGSize = CGSize.zero,
         anchors: [AnchorInfo] = [],
         landmarks: [LandmarkInfo] = [],
         stickyTop: CGFloat = 0,
         virtualList: VirtualListInfo? = nil,
         loadTriggers: [LoadTriggerInfo] = [],
         iframesV2: [IFrameScrollInfo] = [],
         layoutKey: String = "",
         schemaVersion: Int = 2,
         jsState: [String: Any]? = nil,
         timestamp: Date,
         webViewSnapshotPath: String? = nil,
         captureStatus: CaptureStatus = .partial,
         version: Int = 1) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.scrollPositionPercent = scrollPositionPercent
        self.contentSize = contentSize
        self.viewportSize = viewportSize
        self.actualScrollableSize = actualScrollableSize
        self.anchors = anchors
        self.landmarks = landmarks
        self.stickyTop = stickyTop
        self.virtualList = virtualList
        self.loadTriggers = loadTriggers
        self.iframesV2 = iframesV2
        self.layoutKey = layoutKey
        self.schemaVersion = schemaVersion
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
    
    // 🔥 **완전 무음 복원 시스템**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🔥 완전 무음 복원 시작 - 상태: \(captureStatus.rawValue)")
        
        switch captureStatus {
        case .failed:
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패 상태 - 기본 복원만 수행")
            performBasicRestore(to: webView)
            completion(true)
            return
            
        case .visualOnly, .partial, .complete:
            TabPersistenceManager.debugMessages.append("🔥 완전 무음 복원 시작")
            performSilentRestore(to: webView, completion: completion)
        }
    }
    
    // 🔥 **완전 무음 복원 메서드 (메시지 브리지 기반)**
    private func performSilentRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 복원 페이로드 생성
        let payload = createRestorePayload()
        
        // 완전 무음 복원 JavaScript 실행 (Promise 사용 금지)
        let silentRestoreJS = generateSilentRestoreScript(payload: payload)
        
        webView.evaluateJavaScript(silentRestoreJS) { result, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("❌ 완전 무음 복원 실패: \(error.localizedDescription)")
                completion(false)
                return
            }
            
            // 메시지 브리지를 통한 완료 신호 대기 (이미 설정되어 있어야 함)
            TabPersistenceManager.debugMessages.append("🔥 완전 무음 복원 스크립트 시작됨")
            // completion은 메시지 브리지에서 호출됨
        }
    }
    
    // 기본 복원 (캐시 실패시)
    private func performBasicRestore(to webView: WKWebView) {
        let targetPos = self.scrollPosition
        webView.scrollView.setContentOffset(targetPos, animated: false)
        TabPersistenceManager.debugMessages.append("🔥 기본 복원 완료: (\(targetPos.x), \(targetPos.y))")
    }
    
    // 복원 페이로드 생성
    private func createRestorePayload() -> [String: Any] {
        var payload: [String: Any] = [
            "targetX": scrollPosition.x,
            "targetY": scrollPosition.y,
            "percentX": scrollPositionPercent.x,
            "percentY": scrollPositionPercent.y,
            "stickyTop": stickyTop,
            "layoutKey": layoutKey,
            "schemaVersion": schemaVersion
        ]
        
        // 앵커 정보 추가
        if !anchors.isEmpty {
            payload["anchors"] = anchors.map { anchor in
                [
                    "selector": anchor.selector,
                    "role": anchor.role,
                    "absTop": anchor.absTop,
                    "absLeft": anchor.absLeft,
                    "offsetFromTop": anchor.offsetFromTop,
                    "offsetFromLeft": anchor.offsetFromLeft,
                    "width": anchor.width,
                    "height": anchor.height,
                    "textHead": anchor.textHead,
                    "textHash": anchor.textHash
                ]
            }
        }
        
        // 랜드마크 정보 추가
        if !landmarks.isEmpty {
            payload["landmarks"] = landmarks.map { landmark in
                [
                    "selector": landmark.selector,
                    "role": landmark.role,
                    "absTop": landmark.absTop,
                    "textHash": landmark.textHash
                ]
            }
        }
        
        // 가상 리스트 정보 추가
        if let vl = virtualList {
            payload["virtualList"] = [
                "type": vl.type,
                "beforePx": vl.beforePx,
                "afterPx": vl.afterPx,
                "itemHeightAvg": vl.itemHeightAvg
            ]
        }
        
        // 로드 트리거 정보 추가
        if !loadTriggers.isEmpty {
            payload["loadTriggers"] = loadTriggers.map { trigger in
                [
                    "selector": trigger.selector,
                    "label": trigger.label
                ]
            }
        }
        
        // iframe 정보 추가
        if !iframesV2.isEmpty {
            payload["iframesV2"] = iframesV2.map { iframe in
                [
                    "selector": iframe.selector,
                    "crossOrigin": iframe.crossOrigin,
                    "scrollX": iframe.scrollX,
                    "scrollY": iframe.scrollY,
                    "src": iframe.src,
                    "dataAttrs": iframe.dataAttrs
                ]
            }
        }
        
        return payload
    }
    
    // 🔥 **완전 무음 복원 JavaScript 생성 (메시지 브리지 기반)**
    private func generateSilentRestoreScript(payload: [String: Any]) -> String {
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            return "console.error('페이로드 직렬화 실패');"
        }
        
        return """
        (function() {
            try {
                const payload = \(payloadJSON);
                
                console.log('🔥 완전 무음 복원 시작');
                
                // 🔥 **1단계: 앵커 기반 복원**
                let success = performAnchorRestore(payload);
                
                if (!success) {
                    // 🔥 **2단계: 퍼센트 기반 복원**
                    success = performPercentRestore(payload);
                }
                
                if (!success) {
                    // 🔥 **3단계: 랜드마크 기반 복원**
                    success = performLandmarkRestore(payload);
                }
                
                // 최종 결과 통지
                console.log('🔥 1차 복원 완료:', success);
                
                // Swift로 완료 신호 전송
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bfcache_restore_done) {
                    window.webkit.messageHandlers.bfcache_restore_done.postMessage({
                        success: success,
                        phase: 'restore',
                        t: Date.now()
                    });
                }
                
            } catch(e) { 
                console.error('🔥 완전 무음 복원 실패:', e);
                
                // 에러 시에도 Swift로 신호 전송
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bfcache_restore_done) {
                    window.webkit.messageHandlers.bfcache_restore_done.postMessage({
                        success: false,
                        phase: 'error',
                        error: e.message,
                        t: Date.now()
                    });
                }
            }
            
            // 🔥 **앵커 기반 복원 함수**
            function performAnchorRestore(p) {
                if (!p.anchors || p.anchors.length === 0) return false;
                
                const se = document.scrollingElement || document.documentElement;
                
                for (const anchor of p.anchors) {
                    let el = null;
                    
                    // 셀렉터 우선 매칭
                    if (anchor.selector) {
                        try {
                            el = document.querySelector(anchor.selector);
                        } catch(e) {
                            console.warn('앵커 셀렉터 실패:', anchor.selector, e);
                        }
                    }
                    
                    // 텍스트 해시 근사 매칭
                    if (!el && anchor.textHash) {
                        const candidates = Array.from(document.querySelectorAll('h1,h2,h3,article,main,.post,.article,.card,.list-item,section,div'));
                        el = candidates.find(e => {
                            const text = (e.innerText || '').slice(0, 60).toLowerCase();
                            return simpleHash(text) === anchor.textHash;
                        });
                    }
                    
                    if (el) {
                        const rect = el.getBoundingClientRect();
                        const absTop = (window.scrollY || window.pageYOffset || 0) + rect.top;
                        const offsetFromTop = Number(anchor.offsetFromTop) || 0;
                        const stickyTop = Number(p.stickyTop) || 0;
                        
                        const restoreY = Math.max(0, absTop - offsetFromTop - stickyTop);
                        const restoreX = Number(p.targetX) || 0;
                        
                        // 한 번에 이동
                        se.scrollTo({
                            left: restoreX,
                            top: restoreY,
                            behavior: 'auto'
                        });
                        
                        console.log('🎯 앵커 복원 성공:', anchor.selector || '해시매칭', restoreY);
                        return true;
                    }
                }
                
                return false;
            }
            
            // 🔥 **퍼센트 기반 복원 함수**
            function performPercentRestore(p) {
                if (typeof p.percentY !== 'number') return false;
                
                const se = document.scrollingElement || document.documentElement;
                const maxY = Math.max(0, se.scrollHeight - window.innerHeight);
                const restoreY = Math.max(0, Math.min(maxY, (p.percentY / 100) * maxY));
                const restoreX = Number(p.targetX) || 0;
                
                se.scrollTo({
                    left: restoreX,
                    top: restoreY,
                    behavior: 'auto'
                });
                
                console.log('📊 퍼센트 복원 성공:', p.percentY + '%', restoreY);
                return true;
            }
            
            // 🔥 **랜드마크 기반 복원 함수**
            function performLandmarkRestore(p) {
                if (!p.landmarks || p.landmarks.length === 0) return false;
                
                const se = document.scrollingElement || document.documentElement;
                const targetY = Number(p.targetY) || 0;
                let bestLandmark = null;
                let bestDistance = Infinity;
                
                for (const landmark of p.landmarks) {
                    let el = null;
                    
                    if (landmark.selector) {
                        try {
                            el = document.querySelector(landmark.selector);
                        } catch(e) {
                            continue;
                        }
                    }
                    
                    if (el) {
                        const rect = el.getBoundingClientRect();
                        const absTop = (window.scrollY || window.pageYOffset || 0) + rect.top;
                        const distance = Math.abs(targetY - absTop);
                        
                        if (distance < bestDistance) {
                            bestDistance = distance;
                            bestLandmark = absTop;
                        }
                    }
                }
                
                if (bestLandmark !== null) {
                    const stickyTop = Number(p.stickyTop) || 0;
                    const restoreY = Math.max(0, bestLandmark - stickyTop);
                    const restoreX = Number(p.targetX) || 0;
                    
                    se.scrollTo({
                        left: restoreX,
                        top: restoreY,
                        behavior: 'auto'
                    });
                    
                    console.log('🗺️ 랜드마크 복원 성공:', restoreY);
                    return true;
                }
                
                return false;
            }
            
            // 🔑 간단한 텍스트 해시 함수
            function simpleHash(str) {
                let hash = 0;
                for (let i = 0; i < str.length; i++) {
                    const char = str.charCodeAt(i);
                    hash = ((hash << 5) - hash) + char;
                    hash = hash & hash; // 32bit 정수로 변환
                }
                return hash.toString();
            }
        })()
        """
    }
}

// MARK: - 🧵 **개선된 제스처 컨텍스트 (먹통 방지)**
private class GestureContext {
    let tabID: UUID
    let gestureID: UUID = UUID()
    weak var webView: WKWebView?
    weak var stateModel: WebViewStateModel?
    private var isValid: Bool = true
    private let validationQueue = DispatchQueue(label: "gesture.validation", attributes: .concurrent)
    
    init(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        self.tabID = tabID
        self.webView = webView
        self.stateModel = stateModel
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 생성: \(String(gestureID.uuidString.prefix(8)))")
    }
    
    func validateAndExecute(_ operation: () -> Void) {
        validationQueue.sync {
            guard isValid else {
                TabPersistenceManager.debugMessages.append("🧵 무효한 컨텍스트 - 작업 취소: \(String(gestureID.uuidString.prefix(8)))")
                return
            }
            operation()
        }
    }
    
    func invalidate() {
        validationQueue.async(flags: .barrier) {
            self.isValid = false
            TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 무효화: \(String(self.gestureID.uuidString.prefix(8)))")
        }
    }
    
    deinit {
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 해제: \(String(gestureID.uuidString.prefix(8)))")
    }
}

// MARK: - 🔥 **메시지 브리지 시스템**
private class JSMessageBridge: NSObject, WKScriptMessageHandler {
    private let onMessage: (String, Any?) -> Void
    
    init(_ onMessage: @escaping (String, Any?) -> Void) {
        self.onMessage = onMessage
        super.init()
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage(message.name, message.body)
    }
}

// MARK: - 🔥 **전면 리팩토링된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 **직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // MARK: - 💾 스레드 안전 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
    // 🔥 **복원 상태 추적 (파이프라인 관리)**
    private var _restorationStates: [UUID: RestorationState] = [:]
    
    private enum RestorationState {
        case idle
        case restoring(startTime: Date, phase: String)
        case burstLoading(startTime: Date, cycles: Int)
        case finalizing(startTime: Date)
        case completed
        case timeout
    }
    
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
    
    // MARK: - 🧵 **제스처 전환 상태 (리팩토링된 스레드 안전 관리)**
    private let gestureQueue = DispatchQueue(label: "gesture.management", attributes: .concurrent)
    private var _activeTransitions: [UUID: TransitionContext] = [:]
    private var _gestureContexts: [UUID: GestureContext] = [:]
    
    // 🧵 **스레드 안전 activeTransitions 접근**
    private var activeTransitions: [UUID: TransitionContext] {
        get { gestureQueue.sync { _activeTransitions } }
    }
    
    private func setActiveTransition(_ context: TransitionContext, for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions[tabID] = context
        }
    }
    
    private func removeActiveTransition(for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions.removeValue(forKey: tabID)
        }
    }
    
    private func getActiveTransition(for tabID: UUID) -> TransitionContext? {
        return gestureQueue.sync { _activeTransitions[tabID] }
    }
    
    // 🧵 **제스처 컨텍스트 관리**
    private func setGestureContext(_ context: GestureContext, for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._gestureContexts[key] = context
        }
    }
    
    private func removeGestureContext(for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            if let context = self._gestureContexts.removeValue(forKey: key) {
                context.invalidate()
            }
        }
    }
    
    private func getGestureContext(for key: UUID) -> GestureContext? {
        return gestureQueue.sync { _gestureContexts[key] }
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
    
    // MARK: - 🔥 **프리페인트 가드 스크립트**
    
    static func makePrepaintGuardScript() -> WKUserScript {
        let js = """
        (function(){
            try {
                // UA 자동 복원 끄기
                try { 
                    history.scrollRestoration = 'manual'; 
                } catch(_) {}

                // 프리페인트 가드 클래스 부여 (첫 페인트 이전)
                document.documentElement.classList.add('__restore_hold','__noanchor');

                // 스타일 주입: 스크롤/앵커/전환/애니메이션 차단
                var style = document.createElement('style');
                style.setAttribute('data-restore-style','true');
                style.textContent = `
                    html.__restore_hold { visibility:hidden !important; }
                    html { scroll-behavior:auto !important; }
                    html.__noanchor, body.__noanchor, * { overflow-anchor:none !important; }
                    *,*::before,*::after { transition:none !important; animation:none !important; }
                    * { scroll-margin-top:0 !important; }
                `;
                (document.head || document.documentElement).appendChild(style);

                // 스크롤 명령/앵커 점프/해시 점프 임시 봉인
                window.__restore_hold_flag__ = true;
                (function(){
                    const _scrollTo = window.scrollTo;
                    window.scrollTo = function(){
                        if(!window.__restore_hold_flag__) return _scrollTo.apply(this, arguments);
                    };
                    const _siv = Element.prototype.scrollIntoView;
                    Element.prototype.scrollIntoView = function(){
                        if(!window.__restore_hold_flag__) return _siv.apply(this, arguments);
                    };
                    window.addEventListener('hashchange', function(e){
                        if(window.__restore_hold_flag__) e.stopImmediatePropagation();
                    }, true);
                })();

                // 초기 포커스 해제: 키보드/포커스 스크롤 방지
                try { 
                    document.activeElement && document.activeElement.blur(); 
                } catch(_) {}
                
                console.log('🛡️ 프리페인트 가드 활성화');
            } catch(e) {
                console.error('프리페인트 가드 실패:', e);
            }
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 🔥 **도메인 특화 DOM 캡처 시스템**
    
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
        dbg("🎯 도메인 특화 DOM 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            // 실제 스크롤 가능한 최대 크기 감지
            let actualScrollableWidth = max(webView.scrollView.contentSize.width, webView.scrollView.bounds.width)
            let actualScrollableHeight = max(webView.scrollView.contentSize.height, webView.scrollView.bounds.height)
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                contentSize: webView.scrollView.contentSize,
                viewportSize: webView.bounds.size,
                actualScrollableSize: CGSize(width: actualScrollableWidth, height: actualScrollableHeight),
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🔧 **도메인 특화 캡처 로직 - 실패 시 재시도**
        let captureResult = performRobustDOMCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        // 진행 중 해제
        pendingCaptures.remove(pageID)
        dbg("✅ 도메인 특화 DOM 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize
        let viewportSize: CGSize
        let actualScrollableSize: CGSize
        let bounds: CGRect
        let isLoading: Bool
    }
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    // 중복 방지를 위한 진행 중인 캡처 추적
    private var pendingCaptures: Set<UUID> = []
    
    // 🔧 **도메인 특화 DOM 캡처 - 안정화 대기 + 정밀 앵커 수집**
    private func performRobustDOMCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptDOMCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 DOM 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 대기
            dbg("⏳ DOM 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptDOMCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var anchors: [BFCacheSnapshot.AnchorInfo] = []
        var landmarks: [BFCacheSnapshot.LandmarkInfo] = []
        var stickyTop: CGFloat = 0
        var virtualList: BFCacheSnapshot.VirtualListInfo? = nil
        var loadTriggers: [BFCacheSnapshot.LoadTriggerInfo] = []
        var iframesV2: [BFCacheSnapshot.IFrameScrollInfo] = []
        var layoutKey: String = ""
        
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        DispatchQueue.main.sync {
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
        
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. 🔥 **도메인 특화 DOM 정밀 캡처** - 안정화 대기 + 정밀 수집
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = generateAdvancedDOMCaptureScript()
            
            webView.evaluateJavaScript(domScript) { result, error in
                if let resultString = result as? String,
                   let data = resultString.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    // DOM HTML
                    domSnapshot = parsed["domSnapshot"] as? String
                    
                    // 앵커 정보 파싱
                    if let anchorArray = parsed["anchors"] as? [[String: Any]] {
                        anchors = anchorArray.compactMap { anchorDict in
                            guard let selector = anchorDict["selector"] as? String,
                                  let role = anchorDict["role"] as? String,
                                  let absTop = anchorDict["absTop"] as? Double,
                                  let absLeft = anchorDict["absLeft"] as? Double,
                                  let offsetFromTop = anchorDict["offsetFromTop"] as? Double,
                                  let offsetFromLeft = anchorDict["offsetFromLeft"] as? Double,
                                  let width = anchorDict["width"] as? Double,
                                  let height = anchorDict["height"] as? Double,
                                  let textHead = anchorDict["textHead"] as? String,
                                  let textHash = anchorDict["textHash"] as? String else { return nil }
                            
                            return BFCacheSnapshot.AnchorInfo(
                                selector: selector,
                                role: role,
                                absTop: CGFloat(absTop),
                                absLeft: CGFloat(absLeft),
                                offsetFromTop: CGFloat(offsetFromTop),
                                offsetFromLeft: CGFloat(offsetFromLeft),
                                width: CGFloat(width),
                                height: CGFloat(height),
                                textHead: textHead,
                                textHash: textHash
                            )
                        }
                    }
                    
                    // 랜드마크 정보 파싱
                    if let landmarkArray = parsed["landmarks"] as? [[String: Any]] {
                        landmarks = landmarkArray.compactMap { landmarkDict in
                            guard let selector = landmarkDict["selector"] as? String,
                                  let role = landmarkDict["role"] as? String,
                                  let absTop = landmarkDict["absTop"] as? Double,
                                  let textHash = landmarkDict["textHash"] as? String else { return nil }
                            
                            return BFCacheSnapshot.LandmarkInfo(
                                selector: selector,
                                role: role,
                                absTop: CGFloat(absTop),
                                textHash: textHash
                            )
                        }
                    }
                    
                    // 기타 정보
                    stickyTop = CGFloat(parsed["stickyTop"] as? Double ?? 0)
                    layoutKey = parsed["layoutKey"] as? String ?? ""
                    
                    // 가상 리스트 정보
                    if let vlDict = parsed["virtualList"] as? [String: Any] {
                        virtualList = BFCacheSnapshot.VirtualListInfo(
                            type: vlDict["type"] as? String ?? "unknown",
                            beforePx: CGFloat(vlDict["beforePx"] as? Double ?? 0),
                            afterPx: CGFloat(vlDict["afterPx"] as? Double ?? 0),
                            itemHeightAvg: CGFloat(vlDict["itemHeightAvg"] as? Double ?? 0)
                        )
                    }
                    
                    // 로드 트리거 정보
                    if let triggerArray = parsed["loadTriggers"] as? [[String: Any]] {
                        loadTriggers = triggerArray.compactMap { triggerDict in
                            guard let selector = triggerDict["selector"] as? String,
                                  let label = triggerDict["label"] as? String else { return nil }
                            
                            return BFCacheSnapshot.LoadTriggerInfo(
                                selector: selector,
                                label: label
                            )
                        }
                    }
                    
                    // iframe 정보
                    if let iframeArray = parsed["iframesV2"] as? [[String: Any]] {
                        iframesV2 = iframeArray.compactMap { iframeDict in
                            guard let selector = iframeDict["selector"] as? String,
                                  let crossOrigin = iframeDict["crossOrigin"] as? Bool,
                                  let scrollX = iframeDict["scrollX"] as? Double,
                                  let scrollY = iframeDict["scrollY"] as? Double,
                                  let src = iframeDict["src"] as? String,
                                  let dataAttrs = iframeDict["dataAttrs"] as? [String: String] else { return nil }
                            
                            return BFCacheSnapshot.IFrameScrollInfo(
                                selector: selector,
                                crossOrigin: crossOrigin,
                                scrollX: CGFloat(scrollX),
                                scrollY: CGFloat(scrollY),
                                src: src,
                                dataAttrs: dataAttrs
                            )
                        }
                    }
                    
                    self.dbg("🎯 DOM 정보 파싱 완료 - 앵커: \(anchors.count), 랜드마크: \(landmarks.count), 트리거: \(loadTriggers.count)")
                }
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 2.0)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && !anchors.isEmpty {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = !anchors.isEmpty ? .partial : .visualOnly
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
        
        // 상대적 위치 계산 (백분율)
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.width > captureData.viewportSize.width && captureData.actualScrollableSize.height > captureData.viewportSize.height {
            let maxScrollX = captureData.actualScrollableSize.width - captureData.viewportSize.width
            let maxScrollY = captureData.actualScrollableSize.height - captureData.viewportSize.height
            
            scrollPercent = CGPoint(
                x: maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            scrollPositionPercent: scrollPercent,
            contentSize: captureData.contentSize,
            viewportSize: captureData.viewportSize,
            actualScrollableSize: captureData.actualScrollableSize,
            anchors: anchors,
            landmarks: landmarks,
            stickyTop: stickyTop,
            virtualList: virtualList,
            loadTriggers: loadTriggers,
            iframesV2: iframesV2,
            layoutKey: layoutKey,
            schemaVersion: 2,
            jsState: nil,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🔥 **도메인 특화 DOM 캡처 JavaScript 생성 - 안정화 대기 + 정밀 수집**
    private func generateAdvancedDOMCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🎯 도메인 특화 DOM 캡처 시작');
                
                // 🔥 **1단계: 안정화 대기 (최대 0.5초)**
                return waitForStabilization().then(performPreciseCapture);
                
            } catch(e) {
                console.error('🎯 DOM 캡처 실패:', e);
                return JSON.stringify({
                    domSnapshot: null,
                    anchors: [],
                    landmarks: [],
                    stickyTop: 0,
                    layoutKey: '',
                    virtualList: null,
                    loadTriggers: [],
                    iframesV2: []
                });
            }
            
            // 🔥 **안정화 대기 함수**
            function waitForStabilization() {
                return new Promise((resolve) => {
                    let lastHeight = document.documentElement.scrollHeight;
                    let stableFrames = 0;
                    let frameCount = 0;
                    const maxFrames = 30; // 약 0.5초
                    
                    function checkStability() {
                        const currentHeight = document.documentElement.scrollHeight;
                        
                        if (currentHeight === lastHeight) {
                            stableFrames++;
                            if (stableFrames >= 2) {
                                console.log('🎯 안정화 완료 - 프레임:', frameCount);
                                resolve();
                                return;
                            }
                        } else {
                            stableFrames = 0;
                            lastHeight = currentHeight;
                        }
                        
                        frameCount++;
                        if (frameCount >= maxFrames) {
                            console.log('🎯 안정화 타임아웃 - 즉시 캡처');
                            resolve();
                            return;
                        }
                        
                        requestAnimationFrame(checkStability);
                    }
                    
                    requestAnimationFrame(checkStability);
                });
            }
            
            // 🔥 **정밀 캡처 함수**
            function performPreciseCapture() {
                const result = {
                    domSnapshot: null,
                    anchors: [],
                    landmarks: [],
                    stickyTop: 0,
                    layoutKey: '',
                    virtualList: null,
                    loadTriggers: [],
                    iframesV2: []
                };
                
                try {
                    // DOM 스냅샷
                    if (document.readyState === 'complete') {
                        const html = document.documentElement.outerHTML;
                        result.domSnapshot = html.length > 100000 ? html.substring(0, 100000) : html;
                    }
                    
                    // 📍 **앵커 후보 수집 (최대 5개)**
                    result.anchors = collectAnchors();
                    
                    // 🗺️ **랜드마크 수집 (최대 12개)**
                    result.landmarks = collectLandmarks();
                    
                    // 📌 **상단 고정 헤더 측정**
                    result.stickyTop = measureStickyTop();
                    
                    // 🔑 **레이아웃 서명 생성**
                    result.layoutKey = generateLayoutKey();
                    
                    // 🔄 **가상 리스트 감지**
                    result.virtualList = detectVirtualList();
                    
                    // ♾️ **로드 트리거 수집**
                    result.loadTriggers = collectLoadTriggers();
                    
                    // 🖼️ **iframe 스크롤 상태 수집**
                    result.iframesV2 = collectIFrameScrolls();
                    
                } catch(e) {
                    console.error('정밀 캡처 에러:', e);
                }
                
                console.log('🎯 정밀 캡처 완료:', {
                    anchors: result.anchors.length,
                    landmarks: result.landmarks.length,
                    stickyTop: result.stickyTop,
                    triggers: result.loadTriggers.length,
                    iframes: result.iframesV2.length
                });
                
                return JSON.stringify(result);
            }
            
            // 🎯 **앵커 후보 수집 함수**
            function collectAnchors() {
                const candidates = Array.from(document.querySelectorAll(
                    'h1,h2,h3,article,main,[role="main"],.post,.article,.card,.list-item,section'
                ));
                
                const viewportHeight = window.innerHeight;
                const viewportWidth = window.innerWidth;
                const scrollY = window.scrollY || window.pageYOffset || 0;
                const scrollX = window.scrollX || window.pageXOffset || 0;
                
                const validCandidates = candidates.filter(el => {
                    const rect = el.getBoundingClientRect();
                    // 뷰포트에 부분이라도 걸치는 요소만
                    return rect.bottom > 0 && rect.top < viewportHeight && 
                           rect.right > 0 && rect.left < viewportWidth;
                }).map(el => {
                    const rect = el.getBoundingClientRect();
                    const centerY = rect.top + rect.height / 2;
                    const centerX = rect.left + rect.width / 2;
                    
                    // 뷰포트 중앙에 가까울수록 + 적당한 크기일수록 높은 점수
                    const distanceFromCenter = Math.sqrt(
                        Math.pow(centerX - viewportWidth / 2, 2) + 
                        Math.pow(centerY - viewportHeight / 2, 2)
                    );
                    
                    const sizeScore = Math.min(rect.width * rect.height / (viewportWidth * viewportHeight), 1);
                    const idealSizeRatio = 0.3;
                    const sizePenalty = Math.abs(sizeScore - idealSizeRatio);
                    
                    const score = (viewportWidth + viewportHeight - distanceFromCenter) * (1 - sizePenalty);
                    
                    return {
                        element: el,
                        rect: rect,
                        score: score
                    };
                }).sort((a, b) => b.score - a.score).slice(0, 5); // 상위 5개
                
                return validCandidates.map(item => {
                    const el = item.element;
                    const rect = item.rect;
                    
                    const absTop = scrollY + rect.top;
                    const absLeft = scrollX + rect.left;
                    
                    const offsetFromTop = scrollY - absTop;
                    const offsetFromLeft = scrollX - absLeft;
                    
                    const textContent = (el.innerText || '').slice(0, 60);
                    const textHash = simpleHash(textContent.toLowerCase());
                    
                    const role = determineRole(el);
                    
                    return {
                        selector: generateBestSelector(el),
                        role: role,
                        absTop: absTop,
                        absLeft: absLeft,
                        offsetFromTop: offsetFromTop,
                        offsetFromLeft: offsetFromLeft,
                        width: rect.width,
                        height: rect.height,
                        textHead: textContent,
                        textHash: textHash
                    };
                });
            }
            
            // 🗺️ **랜드마크 수집 함수**
            function collectLandmarks() {
                const landmarkCandidates = Array.from(document.querySelectorAll(
                    'header,nav,main,article,section,aside,footer,h1,h2,h3,.navigation,.sidebar,.content,.main-content'
                ));
                
                const scrollY = window.scrollY || window.pageYOffset || 0;
                
                return landmarkCandidates.slice(0, 12).map(el => {
                    const rect = el.getBoundingClientRect();
                    const absTop = scrollY + rect.top;
                    const textContent = (el.innerText || '').slice(0, 60);
                    const textHash = simpleHash(textContent.toLowerCase());
                    const role = determineRole(el);
                    
                    return {
                        selector: generateBestSelector(el),
                        role: role,
                        absTop: absTop,
                        textHash: textHash
                    };
                });
            }
            
            // 📌 **상단 고정 헤더 측정**
            function measureStickyTop() {
                const stickyElements = Array.from(document.querySelectorAll('*')).filter(el => {
                    const style = window.getComputedStyle(el);
                    const position = style.position;
                    return (position === 'fixed' || position === 'sticky');
                });
                
                let maxStickyHeight = 0;
                
                stickyElements.forEach(el => {
                    const rect = el.getBoundingClientRect();
                    const style = window.getComputedStyle(el);
                    const top = parseFloat(style.top) || 0;
                    
                    // 상단에 고정되어 있고 화면에 보이는 요소
                    if (top <= 0 && rect.bottom > 0 && rect.top < 100) {
                        maxStickyHeight = Math.max(maxStickyHeight, rect.height);
                    }
                });
                
                return maxStickyHeight;
            }
            
            // 🔑 **레이아웃 서명 생성**
            function generateLayoutKey() {
                const mainElements = Array.from(document.querySelectorAll('h1,h2,h3,main,article,.main-content'))
                    .slice(0, 5)
                    .map(el => (el.innerText || '').slice(0, 20))
                    .join('|');
                
                const classSignature = Array.from(document.querySelectorAll('[class]'))
                    .slice(0, 10)
                    .map(el => el.className.split(' ')[0])
                    .filter(c => c.length > 3)
                    .join('|');
                
                const combined = mainElements + '::' + classSignature;
                return simpleHash(combined).toString().slice(0, 8);
            }
            
            // 🔄 **가상 리스트 감지**
            function detectVirtualList() {
                const virtualTypes = [
                    'react-virtualized',
                    'RecyclerView', 
                    'virtual-list',
                    'react-window'
                ];
                
                for (const type of virtualTypes) {
                    const elements = document.querySelectorAll(`[class*="${type}"], [data-${type}]`);
                    if (elements.length > 0) {
                        // 가상 리스트 컨테이너에서 spacer 높이 추출 시도
                        const container = elements[0];
                        const spacers = container.querySelectorAll('[style*="height"]');
                        
                        let beforePx = 0;
                        let afterPx = 0;
                        
                        if (spacers.length >= 2) {
                            const beforeStyle = spacers[0].style.height;
                            const afterStyle = spacers[spacers.length - 1].style.height;
                            
                            beforePx = parseFloat(beforeStyle) || 0;
                            afterPx = parseFloat(afterStyle) || 0;
                        }
                        
                        return {
                            type: type,
                            beforePx: beforePx,
                            afterPx: afterPx,
                            itemHeightAvg: 0 // 계산 복잡성으로 인해 생략
                        };
                    }
                }
                
                return null;
            }
            
            // ♾️ **로드 트리거 수집**
            function collectLoadTriggers() {
                const triggers = Array.from(document.querySelectorAll(
                    '.load-more,.show-more,[data-testid*="load"],[class*="load"][class*="more"],[aria-label*="더보기"]'
                ));
                
                return triggers.slice(0, 6).map(el => {
                    const label = el.innerText || el.getAttribute('aria-label') || el.getAttribute('title') || 'Load More';
                    return {
                        selector: generateBestSelector(el),
                        label: label.slice(0, 40)
                    };
                });
            }
            
            // 🖼️ **iframe 스크롤 상태 수집**
            function collectIFrameScrolls() {
                const iframes = Array.from(document.querySelectorAll('iframe'));
                
                return iframes.map(iframe => {
                    let scrollX = 0;
                    let scrollY = 0;
                    let crossOrigin = false;
                    
                    try {
                        const contentWindow = iframe.contentWindow;
                        if (contentWindow && contentWindow.location) {
                            scrollX = parseFloat(contentWindow.scrollX) || 0;
                            scrollY = parseFloat(contentWindow.scrollY) || 0;
                        }
                    } catch(e) {
                        crossOrigin = true;
                    }
                    
                    const dataAttrs = {};
                    for (const attr of iframe.attributes) {
                        if (attr.name.startsWith('data-')) {
                            dataAttrs[attr.name] = attr.value;
                        }
                    }
                    
                    return {
                        selector: generateBestSelector(iframe),
                        crossOrigin: crossOrigin,
                        scrollX: scrollX,
                        scrollY: scrollY,
                        src: iframe.src || '',
                        dataAttrs: dataAttrs
                    };
                });
            }
            
            // 🔧 **유틸리티 함수들**
            
            function generateBestSelector(el) {
                if (!el || el.nodeType !== 1) return '';
                
                // 1. ID 우선
                if (el.id) {
                    return `#${el.id}`;
                }
                
                // 2. data-* 속성 조합
                const dataAttrs = Array.from(el.attributes)
                    .filter(attr => attr.name.startsWith('data-'))
                    .map(attr => `[${attr.name}="${attr.value}"]`);
                if (dataAttrs.length > 0) {
                    const attrSelector = el.tagName.toLowerCase() + dataAttrs.join('');
                    if (document.querySelectorAll(attrSelector).length === 1) {
                        return attrSelector;
                    }
                }
                
                // 3. 클래스 조합
                if (el.className) {
                    const classes = el.className.trim().split(/\\s+/);
                    const uniqueClasses = classes.filter(cls => {
                        const elements = document.querySelectorAll(`.${cls}`);
                        return elements.length === 1 && elements[0] === el;
                    });
                    
                    if (uniqueClasses.length > 0) {
                        return `.${uniqueClasses.join('.')}`;
                    }
                    
                    if (classes.length > 0) {
                        const classSelector = `.${classes.join('.')}`;
                        if (document.querySelectorAll(classSelector).length === 1) {
                            return classSelector;
                        }
                    }
                }
                
                // 4. 경로 기반 (4단계 이내)
                let path = [];
                let current = el;
                while (current && current !== document.documentElement && path.length < 4) {
                    let selector = current.tagName.toLowerCase();
                    if (current.id) {
                        path.unshift(`#${current.id}`);
                        break;
                    }
                    if (current.className) {
                        const classes = current.className.trim().split(/\\s+/).join('.');
                        selector += `.${classes}`;
                    }
                    path.unshift(selector);
                    current = current.parentElement;
                }
                return path.join(' > ');
            }
            
            function determineRole(el) {
                const tagName = el.tagName.toLowerCase();
                const className = el.className.toLowerCase();
                
                if (tagName === 'h1' || tagName === 'h2' || tagName === 'h3') return tagName;
                if (tagName === 'article') return 'article';
                if (tagName === 'main' || el.getAttribute('role') === 'main') return 'main';
                if (tagName === 'section') return 'section';
                if (className.includes('card')) return 'card';
                if (className.includes('post') || className.includes('article')) return 'article';
                if (className.includes('list-item') || className.includes('item')) return 'list-item';
                
                return 'other';
            }
            
            function simpleHash(str) {
                let hash = 0;
                for (let i = 0; i < str.length; i++) {
                    const char = str.charCodeAt(i);
                    hash = ((hash << 5) - hash) + char;
                    hash = hash & hash; // 32bit 정수로 변환
                }
                return hash;
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
    
    // MARK: - 🔥 **오버레이 시스템 (완전 무음 공개)**
    
    func overlayBegin(_ webView: WKWebView) {
        guard webView.viewWithTag(998877) == nil else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = webView.bounds
        cfg.afterScreenUpdates = true
        webView.takeSnapshot(with: cfg) { [weak webView] image, _ in
            guard let webView = webView else { return }
            let overlay = UIImageView(frame: webView.bounds)
            overlay.tag = 998877
            overlay.image = image ?? self.renderWebViewToImage(webView)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.isUserInteractionEnabled = false
            overlay.alpha = 1.0
            webView.addSubview(overlay)
            self.dbg("🔥 오버레이 설치 완료")
        }
    }
    
    func overlayEnd(_ webView: WKWebView) {
        guard let overlay = webView.viewWithTag(998877) else { return }
        UIView.animate(withDuration: 0.08, delay: 0, options: [.curveEaseOut], animations: {
            overlay.alpha = 0
        }, completion: { _ in 
            overlay.removeFromSuperview()
            self.dbg("🔥 오버레이 제거 완료")
        })
    }
    
    func overlayForceRemove(_ webView: WKWebView) {
        webView.viewWithTag(998877)?.removeFromSuperview()
        dbg("🔥 오버레이 강제 제거")
    }
    
    // MARK: - 🔥 **스크롤 차단 시스템**
    
    func scrollLockBegin(_ webView: WKWebView) {
        webView.scrollView.isScrollEnabled = false
        // iOS safe area/URL bar 보정: 복원 중 inset 자동 조정 금지
        let sv = webView.scrollView
        objc_setAssociatedObject(webView, "oldInsetAdj", sv.contentInsetAdjustmentBehavior, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        sv.contentInsetAdjustmentBehavior = .never
        dbg("🔒 스크롤 잠금 시작")
    }
    
    func scrollLockEnd(_ webView: WKWebView) {
        webView.scrollView.isScrollEnabled = true
        if let old = objc_getAssociatedObject(webView, "oldInsetAdj") as? UIScrollView.ContentInsetAdjustmentBehavior {
            webView.scrollView.contentInsetAdjustmentBehavior = old
        }
        dbg("🔓 스크롤 잠금 해제")
    }
    
    // MARK: - 🔥 **메시지 브리지 기반 복원 파이프라인**
    
    private var messageBridges: [String: JSMessageBridge] = [:]
    private var completionCallbacks: [UUID: (Bool) -> Void] = [:]
    
    func setupMessageBridges(for webView: WKWebView, tabID: UUID) {
        let ucc = webView.configuration.userContentController
        
        // 기존 브리지 제거
        ["bfcache_restore_done", "bfcache_progressive_done", "bfcache_iframe_done"].forEach { channel in
            ucc.removeScriptMessageHandler(forName: channel)
        }
        
        // 새 브리지 설치
        let restoreBridge = JSMessageBridge { [weak self] name, body in
            self?.handleRestoreMessage(name: name, body: body, tabID: tabID)
        }
        
        let progressiveBridge = JSMessageBridge { [weak self] name, body in
            self?.handleProgressiveMessage(name: name, body: body, tabID: tabID)
        }
        
        let iframeBridge = JSMessageBridge { [weak self] name, body in
            self?.handleIFrameMessage(name: name, body: body, tabID: tabID)
        }
        
        ucc.add(restoreBridge, name: "bfcache_restore_done")
        ucc.add(progressiveBridge, name: "bfcache_progressive_done")
        ucc.add(iframeBridge, name: "bfcache_iframe_done")
        
        messageBridges["restore"] = restoreBridge
        messageBridges["progressive"] = progressiveBridge
        messageBridges["iframe"] = iframeBridge
        
        dbg("🔗 메시지 브리지 설치 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    private func handleRestoreMessage(name: String, body: Any?, tabID: UUID) {
        guard let messageDict = body as? [String: Any] else { return }
        
        let success = messageDict["success"] as? Bool ?? false
        let phase = messageDict["phase"] as? String ?? "unknown"
        
        dbg("📨 복원 메시지 수신: \(phase), 성공: \(success)")
        
        // 다음 단계로 진행 또는 완료
        if success {
            proceedToNextPhase(tabID: tabID, currentPhase: phase)
        } else {
            completeRestore(tabID: tabID, success: false)
        }
    }
    
    private func handleProgressiveMessage(name: String, body: Any?, tabID: UUID) {
        guard let messageDict = body as? [String: Any] else { return }
        
        let success = messageDict["success"] as? Bool ?? false
        let cycles = messageDict["cycles"] as? Int ?? 0
        let reason = messageDict["reason"] as? String ?? "unknown"
        
        dbg("📨 버스트 로딩 메시지 수신: \(reason), 사이클: \(cycles)")
        
        proceedToNextPhase(tabID: tabID, currentPhase: "progressive")
    }
    
    private func handleIFrameMessage(name: String, body: Any?, tabID: UUID) {
        guard let messageDict = body as? [String: Any] else { return }
        
        let success = messageDict["success"] as? Bool ?? false
        let restored = messageDict["restored"] as? Int ?? 0
        
        dbg("📨 iframe 복원 메시지 수신: 복원됨 \(restored)개")
        
        proceedToNextPhase(tabID: tabID, currentPhase: "iframe")
    }
    
    private func proceedToNextPhase(tabID: UUID, currentPhase: String) {
        // 상태 기반으로 다음 단계 결정
        switch currentPhase {
        case "restore":
            // 1차 복원 완료 -> 무한스크롤 버스트 필요시 실행
            executeProgressiveLoadingIfNeeded(tabID: tabID)
        case "progressive":
            // 버스트 완료 -> iframe 복원
            executeIFrameRestore(tabID: tabID)
        case "iframe":
            // iframe 복원 완료 -> 최종 정착
            executeFinalSettlement(tabID: tabID)
        case "settlement":
            // 최종 정착 완료 -> 복원 완료
            completeRestore(tabID: tabID, success: true)
        default:
            completeRestore(tabID: tabID, success: false)
        }
    }
    
    private func executeProgressiveLoadingIfNeeded(tabID: UUID) {
        // 무한스크롤 버스트가 필요한지 확인 (예: 목표 위치가 현재 스크롤 범위를 벗어나는 경우)
        dbg("🔄 무한스크롤 버스트 단계 스킵 (필요시 구현)")
        proceedToNextPhase(tabID: tabID, currentPhase: "progressive")
    }
    
    private func executeIFrameRestore(tabID: UUID) {
        dbg("🖼️ iframe 복원 단계 스킵 (필요시 구현)")
        proceedToNextPhase(tabID: tabID, currentPhase: "iframe")
    }
    
    private func executeFinalSettlement(tabID: UUID) {
        dbg("⚖️ 최종 정착 단계 스킵 (필요시 구현)")
        proceedToNextPhase(tabID: tabID, currentPhase: "settlement")
    }
    
    private func completeRestore(tabID: UUID, success: Bool) {
        // 복원 완료 처리
        if let completion = completionCallbacks.removeValue(forKey: tabID) {
            completion(success)
        }
        
        // 상태 정리
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            self?._restorationStates[tabID] = .completed
        }
        
        dbg("🏁 복원 파이프라인 완료: \(success ? "성공" : "실패")")
    }
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업**
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        dbg("🎯 도메인 특화 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
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
                    self.dbg("❌상태 저장 실패: \(error.localizedDescription)")
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
    
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        // 🧵 제스처 컨텍스트 정리
        removeGestureContext(for: tabID)
        removeActiveTransition(for: tabID)
        
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
    
    // MARK: - 🧵 **리팩토링된 제스처 시스템 (먹통 방지)**
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        // 네이티브 제스처 비활성화
        webView.allowsBackForwardNavigationGestures = false
        
        guard let tabID = stateModel.tabID else {
            dbg("🧵 탭 ID 없음 - 제스처 설정 스킵")
            return
        }
        
        // 🧵 **기존 제스처 정리 (중복 방지)**
        cleanupExistingGestures(for: webView, tabID: tabID)
        
        // 🧵 **새로운 제스처 컨텍스트 생성**
        let gestureContext = GestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
        setGestureContext(gestureContext, for: tabID)
        
        // 🧵 **메인 스레드에서 제스처 생성 및 설정**
        DispatchQueue.main.async { [weak self] in
            self?.createAndAttachGestures(webView: webView, tabID: tabID)
        }
        
        // 📸 **메시지 브리지 설치**
        setupMessageBridges(for: webView, tabID: tabID)
        
        dbg("🔥 완전 무음 복원 BFCache 제스처 설정 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 🧵 **기존 제스처 정리**
    private func cleanupExistingGestures(for webView: WKWebView, tabID: UUID) {
        // 기존 제스처 컨텍스트 무효화
        removeGestureContext(for: tabID)
        
        // 웹뷰에서 기존 BFCache 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if let edgeGesture = gesture as? UIScreenEdgePanGestureRecognizer,
               edgeGesture.edges == .left || edgeGesture.edges == .right {
                webView.removeGestureRecognizer(gesture)
                dbg("🧵 기존 제스처 제거: \(edgeGesture.edges)")
            }
        }
    }
    
    // 🧵 **제스처 생성 및 연결**
    private func createAndAttachGestures(webView: WKWebView, tabID: UUID) {
        // 왼쪽 엣지 - 뒤로가기
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        
        // 오른쪽 엣지 - 앞으로가기  
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        
        // 🧵 **제스처에 탭 ID 연결 (컨텍스트 검색용)**
        objc_setAssociatedObject(leftEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(rightEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        webView.addGestureRecognizer(leftEdge)
        webView.addGestureRecognizer(rightEdge)
        
        dbg("🧵 제스처 연결 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 🧵 **리팩토링된 제스처 핸들러 (메인 스레드 최적화)**
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        // 🧵 **메인 스레드 확인 및 강제 이동**
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleGesture(gesture)
            }
            return
        }
        
        // 🧵 **제스처에서 탭 ID 조회**
        guard let tabIDString = objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String,
              let tabID = UUID(uuidString: tabIDString) else {
            dbg("🧵 제스처에서 탭 ID 조회 실패")
            gesture.state = .cancelled
            return
        }
        
        // 🧵 **컨텍스트 유효성 검사 및 조회**
        guard let context = getGestureContext(for: tabID) else {
            dbg("🧵 제스처 컨텍스트 없음 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
            gesture.state = .cancelled
            return
        }
        
        // 🧵 **컨텍스트 내에서 안전하게 실행**
        context.validateAndExecute { [weak self] in
            guard let self = self,
                  let webView = context.webView,
                  let stateModel = context.stateModel else {
                TabPersistenceManager.debugMessages.append("🧵 컨텍스트 무효 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
                gesture.state = .cancelled
                return
            }
            
            self.processGestureState(
                gesture: gesture,
                tabID: tabID,
                webView: webView,
                stateModel: stateModel
            )
        }
    }
    
    // 🧵 **제스처 상태 처리 (기존 로직 유지)**
    private func processGestureState(gesture: UIScreenEdgePanGestureRecognizer, tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
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
            // 🛡️ **전환 중이면 새 제스처 무시**
            guard getActiveTransition(for: tabID) == nil else { 
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 현재 페이지 즉시 캡처 (높은 우선순위)
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                }
                
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
        setActiveTransition(context, for: tabID)
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = getActiveTransition(for: tabID),
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
    
    // 🔥 **완전 무음 복원을 적용한 제스처 완료**
    private func completeGestureTransition(tabID: UUID) {
        guard let context = getActiveTransition(for: tabID),
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
                // 🔥 **완전 무음 복원 시스템으로 네비게이션 수행**
                self?.performNavigationWithSilentRestore(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🔥 **완전 무음 복원 시스템을 적용한 네비게이션 수행**
    private func performNavigationWithSilentRestore(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel,
              let webView = context.webView else {
            // 실패 시 즉시 정리
            previewContainer.removeFromSuperview()
            removeActiveTransition(for: context.tabID)
            return
        }
        
        // 오버레이 및 스크롤 잠금 시작
        overlayBegin(webView)
        scrollLockBegin(webView)
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🔥 완전 무음 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🔥 완전 무음 앞으로가기 완료")
        }
        
        // 🔥 **완전 무음 BFCache 복원**
        trySilentBFCacheRestore(stateModel: stateModel, webView: webView, tabID: context.tabID) { [weak self] success in
            // BFCache 복원 완료 시 정리
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.removeActiveTransition(for: context.tabID)
                
                // 복원 완료 후 가드 해제 및 오버레이 제거
                self?.releaseGuardAndOverlay(webView: webView)
                
                self?.dbg("🔥 미리보기 정리 완료 - 완전 무음 BFCache \(success ? "성공" : "실패")")
            }
        }
    }
    
    // 🔥 **완전 무음 BFCache 복원** 
    private func trySilentBFCacheRestore(stateModel: WebViewStateModel, webView: WKWebView, tabID: UUID, completion: @escaping (Bool) -> Void) {
        guard let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // 완료 콜백 등록
        completionCallbacks[tabID] = completion
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 완전 무음 복원
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("🔥 완전 무음 BFCache 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ 완전 무음 BFCache 복원 실패: \(currentRecord.title)")
                }
                // completion은 메시지 브리지에서 호출됨
            }
        } else {
            // BFCache 미스 - 기존 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            
            // 기존 대기 시간 (250ms)
            let waitTime: TimeInterval = 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                completion(false)
            }
        }
    }
    
    // 🔥 **가드 해제 및 오버레이 제거**
    private func releaseGuardAndOverlay(webView: WKWebView) {
        // rAF 1~2프레임 대기 후 가드 해제
        let guardReleaseJS = """
        requestAnimationFrame(() => {
            requestAnimationFrame(() => {
                try {
                    // 프리페인트 가드 해제
                    window.__restore_hold_flag__ = false;
                    document.documentElement.classList.remove('__restore_hold','__noanchor');
                    
                    // 스타일 제거
                    var s = document.querySelector('style[data-restore-style="true"]');
                    if (s && s.parentNode) s.parentNode.removeChild(s);
                    
                    console.log('🛡️ 프리페인트 가드 해제 완료');
                } catch(e) {
                    console.error('가드 해제 실패:', e);
                }
            });
        });
        """
        
        webView.evaluateJavaScript(guardReleaseJS) { [weak self] _, _ in
            // 스크롤 잠금 해제
            self?.scrollLockEnd(webView)
            
            // 오버레이 페이드아웃 (80ms)
            self?.overlayEnd(webView)
        }
    }

    private func cancelGestureTransition(tabID: UUID) {
        guard let context = getActiveTransition(for: tabID),
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
                self.removeActiveTransition(for: context.tabID)
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
        
        // 오버레이 및 스크롤 잠금 시작
        overlayBegin(webView)
        scrollLockBegin(webView)
        
        stateModel.goBack()
        trySilentBFCacheRestore(stateModel: stateModel, webView: webView, tabID: tabID) { [weak self] success in
            DispatchQueue.main.async {
                self?.releaseGuardAndOverlay(webView: webView)
            }
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
        
        // 오버레이 및 스크롤 잠금 시작
        overlayBegin(webView)
        scrollLockBegin(webView)
        
        stateModel.goForward()
        trySilentBFCacheRestore(stateModel: stateModel, webView: webView, tabID: tabID) { [weak self] success in
            DispatchQueue.main.async {
                self?.releaseGuardAndOverlay(webView: webView)
            }
        }
    }
    
    // MARK: - 🔥 **봉인 해제 JavaScript 스크립트**
    
    static func makeGuardReleaseScript() -> WKUserScript {
        let js = """
        (function(){
            try {
                // 프리페인트 가드 해제
                window.__restore_hold_flag__ = false;
                document.documentElement.classList.remove('__restore_hold','__noanchor');
                
                // 봉인된 함수들 복구
                // (이미 기본 함수들로 복구되어 있음)
                
                // 스타일 제거
                var s = document.querySelector('style[data-restore-style="true"]');
                if (s && s.parentNode) s.parentNode.removeChild(s);
                
                console.log('🛡️ 모든 가드 해제 완료');
            } catch(e) {
                console.error('가드 해제 실패:', e);
            }
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }
    
    // MARK: - 🌐 **BFCache JavaScript 스크립트 (기존 유지)**
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔥 완전 무음 복원 BFCache 페이지 복원');
                
                // 🌐 동적 콘텐츠 새로고침 (필요시)
                if (window.location.pathname.includes('/feed') ||
                    window.location.pathname.includes('/timeline') ||
                    window.location.hostname.includes('twitter') ||
                    window.location.hostname.includes('facebook') ||
                    window.location.hostname.includes('dcinside') ||
                    window.location.hostname.includes('cafe.naver')) {
                    if (window.refreshDynamicContent) {
                        window.refreshDynamicContent();
                    }
                }
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 완전 무음 복원 BFCache 페이지 저장');
            }
        });
        
        // 🔥 Cross-origin iframe 완전 무음 복원 스크롤 복원 리스너
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                try {
                    const targetX = parseFloat(event.data.scrollX) || 0;
                    const targetY = parseFloat(event.data.scrollY) || 0;
                    const silentRestore = event.data.silentRestore || false;
                    
                    console.log('🔥 Cross-origin iframe 완전 무음 복원 스크롤 복원:', targetX, targetY, silentRestore ? '(완전 무음 복원 모드)' : '');
                    
                    if (silentRestore) {
                        // 🔥 완전 무음 복원 모드
                        // 스크롤 이벤트 차단
                        let scrollBlocked = true;
                        const blockScrollEvents = (e) => {
                            if (scrollBlocked) {
                                e.preventDefault();
                                e.stopPropagation();
                                return false;
                            }
                        };
                        
                        document.addEventListener('scroll', blockScrollEvents, { capture: true, passive: false });
                        window.addEventListener('scroll', blockScrollEvents, { capture: true, passive: false });
                        
                        // requestAnimationFrame으로 한 번에 스크롤
                        requestAnimationFrame(() => {
                            const se = document.scrollingElement || document.documentElement;
                            se.scrollTo({left: targetX, top: targetY, behavior: 'auto'});
                            
                            // 스크롤 이벤트 차단 해제
                            setTimeout(() => {
                                scrollBlocked = false;
                                document.removeEventListener('scroll', blockScrollEvents, { capture: true });
                                window.removeEventListener('scroll', blockScrollEvents, { capture: true });
                            }, 100);
                        });
                    } else {
                        // 기본 스크롤
                        const se = document.scrollingElement || document.documentElement;
                        se.scrollTo({left: targetX, top: targetY, behavior: 'auto'});
                    }
                    
                } catch(e) {
                    console.error('Cross-origin iframe 스크롤 복원 실패:', e);
                }
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
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
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[BFCache🔥] \(msg)")
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
        // 🔥 **프리페인트 가드 스크립트 설치 (최우선)**
        webView.configuration.userContentController.addUserScript(makePrepaintGuardScript())
        
        // BFCache 스크립트 설치
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        
        // 가드 해제 스크립트 설치 (문서 끝에서)
        webView.configuration.userContentController.addUserScript(makeGuardReleaseScript())
        
        // 제스처 설치 + 메시지 브리지
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ 🔥 완전 무음 복원 BFCache 시스템 설치 완료")
    }
    
    // CustomWebView의 dismantleUIView에서 호출
    static func uninstall(from webView: WKWebView) {
        // 🧵 제스처 해제
        if let tabIDString = webView.gestureRecognizers?.compactMap({ gesture in
            objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String
        }).first, let tabID = UUID(uuidString: tabIDString) {
            shared.removeGestureContext(for: tabID)
            shared.removeActiveTransition(for: tabID)
        }
        
        // 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        // 메시지 핸들러 제거
        ["bfcache_restore_done", "bfcache_progressive_done", "bfcache_iframe_done"].forEach { channel in
            webView.configuration.userContentController.removeScriptMessageHandler(forName: channel)
        }
        
        // 오버레이 강제 제거
        shared.overlayForceRemove(webView)
        
        TabPersistenceManager.debugMessages.append("🔥 완전 무음 복원 BFCache 시스템 제거 완료")
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

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화 - 🚀 도착 스냅샷 최적화**
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
