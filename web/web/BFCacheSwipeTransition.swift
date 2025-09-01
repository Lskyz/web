private func createEmptyImage(size: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            // 중앙에 "로딩 중" 표시
            let text = "페이지 로딩 중..."
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }

    // MARK: - 🗂️ 캐시 메타데이터 구조체
    
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
                
                // 🔧 **실패 복구 //
//  BFCacheSwipeTransition.swift
//  🎯 **안정성 강화된 BFCache 전환 시스템**
//  ✅ 직렬화 큐로 레이스 컨디션 완전 제거
//  🔄 원자적 연산으로 데이터 일관성 보장
//  📸 실패 복구 메커니즘 추가
//  ♾️ 무제한 영구 캐싱 (탭별 관리)
//  💾 스마트 메모리 관리 
//  🔧 **StateModel과 완벽 동기화**
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
    var formData: [String: Any]?
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
        case formData
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
        if let formDataRaw = try container.decodeIfPresent(Data.self, forKey: .formData) {
            formData = try JSONSerialization.jsonObject(with: formDataRaw) as? [String: Any]
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
        if let form = formData {
            let formDataRaw = try JSONSerialization.data(withJSONObject: form)
            try container.encode(formDataRaw, forKey: .formData)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
    }
    
    // 직접 초기화용 init
    init(pageRecord: PageRecord, domSnapshot: String? = nil, scrollPosition: CGPoint, jsState: [String: Any]? = nil, formData: [String: Any]? = nil, timestamp: Date, webViewSnapshotPath: String? = nil, captureStatus: CaptureStatus = .partial, version: Int = 1) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.jsState = jsState
        self.formData = formData
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
    
    // 🔧 **개선된 복원 메서드 - URL 로드 제거**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 캡처 상태에 따른 복원 전략
        switch captureStatus {
        case .failed:
            // ✅ URL 로드 제거! StateModel이 이미 처리
            // 캐처 실패시 그냥 실패 리턴
            TabPersistenceManager.debugMessages.append("BFCache 캡처 실패 - StateModel이 URL 로드 처리")
            completion(false)
            return
            
        case .visualOnly:
            // ✅ URL 로드 제거! 스크롤 위치만 복원
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                webView.scrollView.setContentOffset(self.scrollPosition, animated: false)
                TabPersistenceManager.debugMessages.append("BFCache 스크롤 위치만 복원")
                completion(true)
            }
            return
            
        case .partial, .complete:
            // 정상적인 복원 진행 (URL 로드 없이)
            break
        }
        
        // ✅ URL 로드 제거! StateModel이 이미 처리
        // 바로 상태 복원으로 진행
        TabPersistenceManager.debugMessages.append("BFCache 상태 복원 시작 (URL 로드 스킵)")
        
        // 페이지가 이미 로드되었다고 가정하고 상태만 복원
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
    
    // MARK: - 🔧 **강화된 원자적 캡처 시스템**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
        let captureKey: String
        
        init(pageRecord: PageRecord, tabID: UUID?, type: CaptureType, webView: WKWebView?) {
            self.pageRecord = pageRecord
            self.tabID = tabID
            self.type = type
            self.webView = webView
            // URL + 타임스탬프로 고유키 생성 (동일 페이지 중복 방지)
            self.captureKey = "\(pageRecord.url.absoluteString)-\(Int(Date().timeIntervalSince1970 * 1000))"
        }
    }
    
    // 🔧 **강화된 중복 방지 시스템**
    private let captureStateQueue = DispatchQueue(label: "bfcache.captureState", attributes: .concurrent)
    private var _pendingCaptures: Set<String> = []  // captureKey로 관리
    private var _failedCaptures: [UUID: Date] = [:]  // 실패한 캐처 추적
    private var _lastCaptureTime: [UUID: Date] = [:]  // 마지막 캡처 시간
    
    private func isPendingCapture(_ key: String) -> Bool {
        return captureStateQueue.sync { _pendingCaptures.contains(key) }
    }
    
    private func addPendingCapture(_ key: String) {
        captureStateQueue.async(flags: .barrier) { self._pendingCaptures.insert(key) }
    }
    
    private func removePendingCapture(_ key: String) {
        captureStateQueue.async(flags: .barrier) { self._pendingCaptures.remove(key) }
    }
    
    private func shouldSkipCapture(pageID: UUID) -> Bool {
        return captureStateQueue.sync {
            // 최근 1초 이내에 같은 페이지 캡처했으면 스킵
            if let lastTime = _lastCaptureTime[pageID],
               Date().timeIntervalSince(lastTime) < 1.0 {
                return true
            }
            return false
        }
    }
    
    private func recordCaptureTime(pageID: UUID) {
        captureStateQueue.async(flags: .barrier) {
            self._lastCaptureTime[pageID] = Date()
        }
    }
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        // 🔧 **중복 캐처 방지 강화**
        if shouldSkipCapture(pageID: pageRecord.id) {
            dbg("⏸️ 최근 캡처됨 - 스킵: \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        // 같은 captureKey가 진행중이면 스킵
        if isPendingCapture(task.captureKey) {
            dbg("⏸️ 동일 작업 진행중 - 스킵: \(pageRecord.title)")
            return
        }
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 진행 중 등록
        addPendingCapture(task.captureKey)
        dbg("🎯 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type)) [키: \(task.captureKey.suffix(8))]")
        
        defer {
            // 항상 진행 중 해제
            removePendingCapture(task.captureKey)
            recordCaptureTime(pageID: pageID)
        }
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 🔧 **웹뷰 상태 안정성 검사**
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 기본 조건 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            // 🔧 **추가 안정성 검사**
            guard webView.url != nil else {
                self.dbg("⚠️ 웹뷰 URL 없음 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            return
        }
        
        // 🔧 **로딩 중이면 잠시 대기 (빠른 리다이렉트 대응)**
        if data.isLoading && task.type == .immediate {
            dbg("⏳ 로딩 중 - 0.3초 대기: \(task.pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.3)
        }
        
        // 🔧 **강화된 캐처 로직 - 컨텍스트별 재시도**
        let retryCount = task.type == .immediate ? 2 : 1
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: retryCount
        )
        
        // 🔧 **실패 추적**
        if captureResult.snapshot.captureStatus == .failed {
            captureStateQueue.async(flags: .barrier) {
                self._failedCaptures[pageID] = Date()
            }
            dbg("❌ 캐처 실패 기록: \(task.pageRecord.title)")
        } else {
            captureStateQueue.async(flags: .barrier) {
                self._failedCaptures.removeValue(forKey: pageID)
            }
        }
        
        // 캐처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        dbg("✅ 직렬 캐처 완료: \(task.pageRecord.title) [상태: \(captureResult.snapshot.captureStatus)]")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔧 **강화된 실패 복구 캡처 시스템**
    private func performRobustCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptCaptureWithTimeout(pageRecord: pageRecord, webView: webView, captureData: captureData, attempt: attempt)
            
            // 🔧 **성공 조건 강화**
            let isSuccessful = result.snapshot.captureStatus != .failed && 
                              (result.image != nil || result.snapshot.domSnapshot != nil)
            
            if isSuccessful || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1)) [상태: \(result.snapshot.captureStatus)]")
                }
                return result
            }
            
            // 재시도 전 대기 시간 증가 (지수 백오프)
            let waitTime = Double(attempt + 1) * 0.2  // 0.2s, 0.4s, 0.6s
            dbg("⏳ 캐처 실패 - \(waitTime)초 후 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: waitTime)
        }
        
        // 모든 시도 실패
        dbg("❌ 모든 캐처 시도 실패: \(pageRecord.title)")
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptCaptureWithTimeout(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, attempt: Int) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        var formData: [String: Any]? = nil
        
        let group = DispatchGroup()
        var captureErrors: [String] = []
        
        // 1. 비주얼 스냅샷 (타임아웃 강화)
        group.enter()
        DispatchQueue.main.async {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = attempt > 0  // 재시도시 화면 업데이트 대기
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    captureErrors.append("스냅샷: \(error.localizedDescription)")
                    // 🔧 **Fallback 강화**
                    visualSnapshot = self.renderWebViewToImage(webView)
                    if visualSnapshot == nil {
                        visualSnapshot = self.createEmptyImage(size: captureData.bounds.size)
                    }
                } else {
                    visualSnapshot = image
                }
                group.leave()
            }
        }
        
        // 2. DOM 캡처 (병렬 실행)
        group.enter()
        DispatchQueue.main.async {
            let domScript = """
            (function() {
                try {
                    if (document.readyState === 'loading') return 'loading';
                    const html = document.documentElement.outerHTML;
                    return html.length > 200000 ? html.substring(0, 200000) : html;
                } catch(e) { return 'error: ' + e.message; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                if let error = error {
                    captureErrors.append("DOM: \(error.localizedDescription)")
                } else if let htmlString = result as? String, !htmlString.hasPrefix("error:") && htmlString != "loading" {
                    domSnapshot = htmlString
                }
                group.leave()
            }
        }
        
        // 3. JS 상태 캡처 (병렬 실행)
        group.enter()
        DispatchQueue.main.async {
            let jsScript = """
            (function() {
                try {
                    const formData = {};
                    const inputs = document.querySelectorAll('input:not([type="password"]), textarea, select');
                    inputs.forEach((el, i) => {
                        if (i >= 100) return; // 최대 100개
                        if (el.name || el.id) {
                            const key = el.name || el.id;
                            if (el.type === 'checkbox' || el.type === 'radio') {
                                formData[key] = el.checked;
                            } else {
                                formData[key] = el.value || '';
                            }
                        }
                    });
                    
                    const scrollElements = [];
                    document.querySelectorAll('[data-scroll], .scrollable, .scroll-container').forEach((el, i) => {
                        if (i >= 20 && el.scrollTop > 0) {  // 스크롤된 요소만
                            const selector = el.id ? `#${el.id}` : el.className ? `.${el.className.split(' ')[0]}` : `${el.tagName}:nth-child(${i})`;
                            scrollElements.push({
                                selector: selector,
                                top: el.scrollTop,
                                left: el.scrollLeft
                            });
                        }
                    });
                    
                    return {
                        forms: formData,
                        scroll: { 
                            x: window.scrollX, 
                            y: window.scrollY,
                            elements: scrollElements
                        },
                        href: window.location.href,
                        title: document.title,
                        ready: document.readyState === 'complete'
                    };
                } catch(e) { 
                    return { error: e.message };
                }
            })()
            """
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    captureErrors.append("JS: \(error.localizedDescription)")
                } else if let data = result as? [String: Any], data["error"] == nil {
                    jsState = data
                    formData = data["forms"] as? [String: Any]
                }
                group.leave()
            }
        }
        
        // 🔧 **타임아웃 설정 (시도별로 증가)**
        let timeout = DispatchTime.now() + Double(3 + attempt * 2)  // 3s, 5s, 7s
        let result = group.wait(timeout: timeout)
        
        if result == .timedOut {
            captureErrors.append("타임아웃 (\(3 + attempt * 2)초)")
            dbg("⏰ 캐처 타임아웃: \(pageRecord.title) - \(captureErrors.joined(separator: ", "))")
            
            // 타임아웃 시에도 fallback 시도
            if visualSnapshot == nil {
                visualSnapshot = renderWebViewToImage(webView)
            }
        }
        
        // 🔧 **캐처 상태 세밀한 결정**
        let captureStatus: BFCacheSnapshot.CaptureStatus
        let hasVisual = visualSnapshot != nil
        let hasDOM = domSnapshot != nil && !domSnapshot!.isEmpty
        let hasJS = jsState != nil && !(jsState!.isEmpty)
        
        if hasVisual && hasDOM && hasJS {
            captureStatus = .complete
        } else if hasVisual && (hasDOM || hasJS) {
            captureStatus = .partial
        } else if hasVisual {
            captureStatus = .visualOnly
        } else {
            captureStatus = .failed
            if !captureErrors.isEmpty {
                dbg("❌ 캐처 오류들: \(captureErrors.joined(separator: ", "))")
            }
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
            formData: formData,
            timestamp: Date(),
            webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
            captureStatus: captureStatus,
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🔧 **빈 이미지 생성 헬퍼**
    // MARK: - 🔧 **자동 실패 복구 시스템**
    
    private func setupFailureRecoveryTimer() {
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.retryFailedCaptures()
        }
    }
    
    private func retryFailedCaptures() {
        let failedPageIDs: [UUID] = captureStateQueue.sync {
            // 10분 이내 실패한 것들만
            return _failedCaptures.compactMap { (pageID, failTime) in
                Date().timeIntervalSince(failTime) < 600 ? pageID : nil
            }
        }
        
        guard !failedPageIDs.isEmpty else { return }
        
        dbg("🔄 실패 복구 시작: \(failedPageIDs.count)개 항목")
        
        // 현재 활성화된 웹뷰에서만 재시도
        for pageID in failedPageIDs {
            // StateModel을 통해 현재 활성 페이지인지 확인 후 재시도
            // (실제 구현에서는 StateModel 참조 필요)
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
            var saveErrors: [String] = []
            
            // 1. 이미지 저장 (JPEG 압축) - 에러 처리 강화
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                
                // 🔧 **이미지 품질 적응형 압축**
                let compressionQualities: [CGFloat] = [0.8, 0.6, 0.4]  // 순차적 압축 시도
                var imageSaved = false
                
                for quality in compressionQualities {
                    if let jpegData = image.jpegData(compressionQuality: quality) {
                        do {
                            try jpegData.write(to: imagePath)
                            finalSnapshot.webViewSnapshotPath = imagePath.path
                            self.dbg("💾 이미지 저장 성공 (품질 \(Int(quality*100))%): \(imagePath.lastPathComponent)")
                            imageSaved = true
                            break
                        } catch {
                            saveErrors.append("이미지 저장 실패 (품질 \(Int(quality*100))%): \(error.localizedDescription)")
                        }
                    }
                }
                
                if !imageSaved {
                    saveErrors.append("모든 품질로 이미지 저장 실패")
                }
            }
            
            // 2. 상태 데이터 저장 (JSON) - 에러 처리 강화
            let statePath = pageDir.appendingPathComponent("state.json")
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted  // 디버깅 편의
                let stateData = try encoder.encode(finalSnapshot)
                try stateData.write(to: statePath)
                self.dbg("💾 상태 저장 성공: \(statePath.lastPathComponent)")
            } catch {
                saveErrors.append("상태 저장 실패: \(error.localizedDescription)")
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
            do {
                let metadataData = try JSONEncoder().encode(metadata)
                try metadataData.write(to: metadataPath)
            } catch {
                saveErrors.append("메타데이터 저장 실패: \(error.localizedDescription)")
            }
            
            // 4. 인덱스 업데이트 (원자적) - 저장 성공 시에만
            if saveErrors.isEmpty || finalSnapshot.webViewSnapshotPath != nil {
                self.setDiskIndex(pageDir.path, for: pageID)
                self.setMemoryCache(finalSnapshot, for: pageID)
                
                // 실패 기록에서 제거
                self.captureStateQueue.async(flags: .barrier) {
                    self._failedCaptures.removeValue(forKey: pageID)
                }
                
                self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            } else {
                self.dbg("❌ 디스크 저장 실패: \(saveErrors.joined(separator: ", "))")
                
                // 실패 기록 업데이트
                self.captureStateQueue.async(flags: .barrier) {
                    self._failedCaptures[pageID] = Date()
                }
            }
            
            // 5. 이전 버전 정리 (최신 3개만 유지)
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
        }
    }
    
    // MARK: - 🔍 **강화된 스냅샷 조회 시스템**
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        // 1. 먼저 메모리 캐시 확인 (스레드 안전)
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            // 🔧 **캐시 유효성 검사**
            if isSnapshotValid(snapshot) {
                dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title)")
                return snapshot
            } else {
                dbg("⚠️ 메모리 캐시 무효화: \(snapshot.pageRecord.title)")
                // 무효한 캐시 제거
                cacheAccessQueue.async(flags: .barrier) {
                    self._memoryCache.removeValue(forKey: pageID)
                }
            }
        }
        
        // 2. 디스크 캐시 확인 (스레드 안전)
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            do {
                let data = try Data(contentsOf: statePath)
                let snapshot = try JSONDecoder().decode(BFCacheSnapshot.self, from: data)
                
                // 🔧 **디스크 캐시 유효성 검사**
                if isSnapshotValid(snapshot) {
                    // 메모리 캐시에도 저장 (최적화)
                    setMemoryCache(snapshot, for: pageID)
                    
                    dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title)")
                    return snapshot
                } else {
                    dbg("⚠️ 디스크 캐시 무효화: \(snapshot.pageRecord.title)")
                    // 무효한 디스크 캐시 정리는 백그라운드에서
                    diskIOQueue.async {
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: diskPath))
                    }
                }
            } catch {
                dbg("❌ 디스크 캐시 로드 오류: \(error.localizedDescription)")
                // 손상된 캐시 제거
                cacheAccessQueue.async(flags: .barrier) {
                    self._diskCacheIndex.removeValue(forKey: pageID)
                }
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
    // 🔧 **캐시 유효성 검사**
    private func isSnapshotValid(_ snapshot: BFCacheSnapshot) -> Bool {
        // 1. 타임스탬프 검사 (1시간 이내)
        let age = Date().timeIntervalSince(snapshot.timestamp)
        if age > 3600 {  // 1시간
            return false
        }
        
        // 2. 이미지 파일 존재 확인
        if let imagePath = snapshot.webViewSnapshotPath {
            if !FileManager.default.fileExists(atPath: imagePath) {
                return false
            }
        }
        
        // 3. 캡처 상태 확인
        if snapshot.captureStatus == .failed {
            return false
        }
        
        return true
    }
    
    // MARK: - 🧹 **강화된 캐시 정리**
    
    // 탭 닫을 때만 호출 (무제한 캐시 정책)
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        // 메모리에서 제거 (스레드 안전)
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
                self._cacheVersion.removeValue(forKey: pageID)
                self._failedCaptures.removeValue(forKey: pageID)
                self._lastCaptureTime.removeValue(forKey: pageID)
            }
            
            // 진행 중인 캐처도 정리
            let tabPrefix = "\(tabID)-"
            self._pendingCaptures = self._pendingCaptures.filter { !$0.hasPrefix(tabPrefix) }
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
            
            // 메모리 캐시의 2/3 정리 (오래된 것부터)
            let sorted = self._memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count * 2 / 3
            
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            // 진행 중인 캐처도 일부 정리 (오래된 것)
            let cutoffTime = Date().timeIntervalSince1970 - 30  // 30초 이전
            self._pendingCaptures = self._pendingCaptures.filter { key in
                !key.hasSuffix("-\(Int(cutoffTime))")
            }
            
            self.dbg("⚠️ 메모리 경고 - 캐시 정리: \(beforeCount) → \(self._memoryCache.count), 진행중: \(self._pendingCaptures.count)")
        }
    }
    
    // MARK: - 🎯 **제스처 시스템 (기존 유지)**
    
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
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
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
    
    private func performNavigation(context: TransitionContext) {
        guard let stateModel = context.stateModel else { return }
        
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // BFCache 복원 시도
        tryBFCacheRestore(stateModel: stateModel, direction: context.direction)
    }
    
    // 🔧 **개선된 BFCache 복원 - URL 로드는 StateModel에 위임**
    private func tryBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else { return }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ BFCache 상태 복원 성공: \(currentRecord.title) [상태: \(snapshot.captureStatus)]")
                } else {
                    self?.dbg("⚠️ BFCache 상태 복원 실패: \(currentRecord.title) - StateModel이 처리")
                }
            }
        } else {
            dbg("❌ BFCache 미스: \(currentRecord.title) - StateModel이 처리")
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
        tryBFCacheRestore(stateModel: stateModel, direction: .back)
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
        tryBFCacheRestore(stateModel: stateModel, direction: .forward)
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

    /// 문서 로드 완료 후 **도착 페이지**를 저장
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 백그라운드 캡처 (일반 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
    }
}
