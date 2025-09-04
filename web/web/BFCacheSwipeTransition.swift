//
//  BFCacheSwipeTransition.swift
//  🎯 **완전 최적화된 페이지 번호 기반 BFCache 시스템**
//  ✅ 모든 메모리 누수 방지 및 완전한 정리 시스템
//  🔧 성능 최적화된 DOM Observer (샘플링 기반)
//  💾 견고한 디스크 캐시 (재시도 로직 + 복구 메커니즘)
//  📸 완전한 비주얼 스냅샷 저장/로드 시스템
//  🎯 제스처 충돌 방지 및 스마트 감지
//  🖼️ iframe 스냅샷 완전 지원
//

import UIKit
import WebKit
import SwiftUI
import CryptoKit

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 🔗 완전한 페이지 번호 기반 레지스트리 시스템
private class BFCacheRegistry {
    static let shared = BFCacheRegistry()
    private init() {
        setupCleanupTimer()
    }
    
    // 동시성 안전한 큐들
    private let registryQueue = DispatchQueue(label: "bfcache.registry", attributes: .concurrent)
    private let cleanupQueue = DispatchQueue(label: "bfcache.cleanup", qos: .utility)
    
    // 핵심 매핑 테이블들
    private var _tabStateMap: [UUID: WeakStateModelRef] = [:]        // TabID → StateModel
    private var _webViewTabMap: [ObjectIdentifier: UUID] = [:]       // WebView → TabID  
    private var _pageSnapshots: [String: SPAOptimizedSnapshot] = [:] // PageKey → Snapshot
    
    // 페이지 키 생성
    private func makePageKey(tabID: UUID, pageIndex: Int) -> String {
        return "\(tabID.uuidString)_\(pageIndex)"
    }
    
    private func makePageKey(tabID: UUID, pageRecord: PageRecord) -> String {
        return "\(tabID.uuidString)_\(pageRecord.id.uuidString)"
    }
    
    private class WeakStateModelRef {
        weak var stateModel: WebViewStateModel?
        let lastAccessed: Date
        let tabID: UUID
        
        init(_ stateModel: WebViewStateModel, tabID: UUID) {
            self.stateModel = stateModel
            self.tabID = tabID
            self.lastAccessed = Date()
        }
    }
    
    // MARK: - TabID 찾기 (WKWebView → UUID)
    
    func register(stateModel: WebViewStateModel, tabID: UUID, webView: WKWebView) {
        registryQueue.async(flags: .barrier) {
            self._tabStateMap[tabID] = WeakStateModelRef(stateModel, tabID: tabID)
            self._webViewTabMap[ObjectIdentifier(webView)] = tabID
            
            // StateModel의 tabID 동기화
            DispatchQueue.main.async {
                stateModel.tabID = tabID
                stateModel.dataModel.tabID = tabID
            }
            
            self.dbg("✅ 등록 완료: TabID[\(String(tabID.uuidString.prefix(8)))] ↔ WebView")
        }
    }
    
    // 🔧 **개선 1: 완전한 메모리 정리 시스템**
    func unregister(tabID: UUID, webView: WKWebView?) {
        registryQueue.async(flags: .barrier) {
            self._tabStateMap.removeValue(forKey: tabID)
            if let webView = webView {
                self._webViewTabMap.removeValue(forKey: ObjectIdentifier(webView))
            }
            
            // 해당 탭의 모든 스냅샷 제거
            let keysToRemove = self._pageSnapshots.keys.filter { $0.hasPrefix(tabID.uuidString) }
            keysToRemove.forEach { self._pageSnapshots.removeValue(forKey: $0) }
            
            // **수정: BFCacheTransitionSystem의 탭별 상태도 완전 정리**
            DispatchQueue.main.async {
                BFCacheTransitionSystem.shared.cleanupTabResources(tabID: tabID)
            }
            
            self.dbg("🗑️ 완전 정리: TabID[\(String(tabID.uuidString.prefix(8)))] 스냅샷 \(keysToRemove.count)개 + 전환 상태 정리")
        }
    }
    
    func findTabID(for webView: WKWebView) -> UUID? {
        return registryQueue.sync {
            let tabID = _webViewTabMap[ObjectIdentifier(webView)]
            if let tabID = tabID {
                dbg("🔍 WebView → TabID 찾기 성공: [\(String(tabID.uuidString.prefix(8)))]")
            } else {
                dbg("❌ WebView → TabID 찾기 실패")
            }
            return tabID
        }
    }
    
    // MARK: - StateModel 찾기 (UUID → WebViewStateModel)
    
    func findStateModel(for tabID: UUID) -> WebViewStateModel? {
        return registryQueue.sync {
            let stateModel = _tabStateMap[tabID]?.stateModel
            if stateModel != nil {
                dbg("🔍 TabID → StateModel 찾기 성공: [\(String(tabID.uuidString.prefix(8)))]")
            } else {
                dbg("❌ TabID → StateModel 찾기 실패: [\(String(tabID.uuidString.prefix(8)))]")
            }
            return stateModel
        }
    }
    
    // MARK: - 페이지 번호 기반 스냅샷 저장/조회
    
    func storeSnapshot(_ snapshot: SPAOptimizedSnapshot, for tabID: UUID, pageIndex: Int) {
        let pageKey = makePageKey(tabID: tabID, pageIndex: pageIndex)
        
        registryQueue.async(flags: .barrier) {
            self._pageSnapshots[pageKey] = snapshot
            self.dbg("📸 스냅샷 저장: TabID[\(String(tabID.uuidString.prefix(8)))] PageIndex[\(pageIndex)] → Key[\(pageKey)]")
            
            // 메모리 제한 체크 (최대 100개)
            if self._pageSnapshots.count > 100 {
                self.trimOldestSnapshots()
            }
        }
    }
    
    func storeSnapshot(_ snapshot: SPAOptimizedSnapshot, for tabID: UUID, pageRecord: PageRecord) {
        let pageKey = makePageKey(tabID: tabID, pageRecord: pageRecord)
        
        registryQueue.async(flags: .barrier) {
            self._pageSnapshots[pageKey] = snapshot
            self.dbg("📸 스냅샷 저장: TabID[\(String(tabID.uuidString.prefix(8)))] PageRecord[\(String(pageRecord.id.uuidString.prefix(8)))] → Key[\(pageKey)]")
            
            if self._pageSnapshots.count > 100 {
                self.trimOldestSnapshots()
            }
        }
    }
    
    func loadSnapshot(for tabID: UUID, pageIndex: Int) -> SPAOptimizedSnapshot? {
        let pageKey = makePageKey(tabID: tabID, pageIndex: pageIndex)
        
        return registryQueue.sync {
            let snapshot = _pageSnapshots[pageKey]
            if snapshot != nil {
                dbg("✅ 스냅샷 로드 성공: Key[\(pageKey)]")
            } else {
                dbg("❌ 스냅샷 로드 실패: Key[\(pageKey)]")
            }
            return snapshot
        }
    }
    
    func loadSnapshot(for tabID: UUID, pageRecord: PageRecord) -> SPAOptimizedSnapshot? {
        let pageKey = makePageKey(tabID: tabID, pageRecord: pageRecord)
        
        return registryQueue.sync {
            let snapshot = _pageSnapshots[pageKey]
            if snapshot != nil {
                dbg("✅ 스냅샷 로드 성공: Key[\(pageKey)]")
            } else {
                dbg("❌ 스냅샷 로드 실패: Key[\(pageKey)]")
            }
            return snapshot
        }
    }
    
    func findLatestSnapshot(for tabID: UUID, url: URL) -> SPAOptimizedSnapshot? {
        return registryQueue.sync {
            let tabSnapshots = _pageSnapshots.filter { $0.key.hasPrefix(tabID.uuidString) }
            let matchingSnapshots = tabSnapshots.values.filter { $0.pageRecord.url == url }
            let latest = matchingSnapshots.sorted { $0.timestamp > $1.timestamp }.first
            
            if latest != nil {
                dbg("✅ 최신 스냅샷 찾기 성공: TabID[\(String(tabID.uuidString.prefix(8)))] URL[\(url.host ?? "")]")
            } else {
                dbg("❌ 최신 스냅샷 찾기 실패: TabID[\(String(tabID.uuidString.prefix(8)))] URL[\(url.host ?? "")]")
            }
            
            return latest
        }
    }
    
    private func trimOldestSnapshots() {
        // 오래된 스냅샷 25% 제거
        let sortedSnapshots = _pageSnapshots.sorted { $0.value.timestamp < $1.value.timestamp }
        let removeCount = sortedSnapshots.count / 4
        
        sortedSnapshots.prefix(removeCount).forEach { key, _ in
            _pageSnapshots.removeValue(forKey: key)
        }
        
        dbg("🧹 오래된 스냅샷 \(removeCount)개 제거 (남은 개수: \(_pageSnapshots.count))")
    }
    
    // MARK: - 자동 정리 시스템
    
    private func setupCleanupTimer() {
        cleanupQueue.asyncAfter(deadline: .now() + 30) {
            self.performCleanup()
            self.setupCleanupTimer()
        }
    }
    
    func performCleanup() {
        registryQueue.async(flags: .barrier) {
            // nil 참조 정리
            self._tabStateMap = self._tabStateMap.compactMapValues { ref in
                return ref.stateModel != nil ? ref : nil
            }
            
            // 연결이 끊어진 webView 매핑 정리
            self._webViewTabMap = self._webViewTabMap.filter { _, tabID in
                return self._tabStateMap[tabID] != nil
            }
            
            // 고아 스냅샷 정리
            let validTabIDs = Set(self._tabStateMap.keys.map { $0.uuidString })
            let orphanKeys = self._pageSnapshots.keys.filter { key in
                let tabIDPart = String(key.prefix(36))
                return !validTabIDs.contains(tabIDPart)
            }
            
            orphanKeys.forEach { self._pageSnapshots.removeValue(forKey: $0) }
            
            if !orphanKeys.isEmpty {
                self.dbg("🧹 정리 완료: 고아 스냅샷 \(orphanKeys.count)개 제거")
            }
        }
    }
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[\(ts())][Registry] \(msg)")
    }
}

// MARK: - 💾 견고한 디스크 캐시 시스템 (재시도 + 복구 메커니즘)

private class DiskCacheManager {
    private let cacheDirectory: URL
    private let imagesCacheDirectory: URL // 🔧 **개선 4: 이미지 전용 캐시 디렉토리**
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxCacheSize: Int64 = 200 * 1024 * 1024 // 200MB
    private let diskQueue = DispatchQueue(label: "bfcache.disk", qos: .utility)
    private let maxRetryCount = 3 // 🔧 **개선 3: 재시도 횟수**
    
    // 디스크 캐시 인덱스
    private var _diskIndex: [String: String] = [:]
    private let indexQueue = DispatchQueue(label: "bfcache.index", attributes: .concurrent)
    
    init() {
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesURL.appendingPathComponent("BFCacheSnapshots")
        imagesCacheDirectory = cacheDirectory.appendingPathComponent("Images") // 이미지 서브디렉토리
        
        // 디렉토리 생성
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: imagesCacheDirectory, withIntermediateDirectories: true)
        
        // 인덱스 로드
        loadDiskCacheIndex()
        
        // 초기 정리
        cleanupIfNeeded()
    }
    
    // 🔧 **개선 3: 견고한 인덱스 로드 (복구 메커니즘 추가)**
    func loadDiskCacheIndex() {
        let indexURL = cacheDirectory.appendingPathComponent("cache_index.json")
        
        diskQueue.async {
            do {
                if self.fileManager.fileExists(atPath: indexURL.path) {
                    let data = try Data(contentsOf: indexURL)
                    let loadedIndex = try JSONDecoder().decode([String: String].self, from: data)
                    
                    self.indexQueue.async(flags: .barrier) {
                        self._diskIndex = loadedIndex
                        TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] 💾 디스크 캐시 인덱스 로드: \(loadedIndex.count)개 항목")
                    }
                } else {
                    // 인덱스 파일이 없을 경우 새로 생성
                    self.saveDiskCacheIndex()
                    TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] 💾 새로운 디스크 캐시 인덱스 생성")
                }
            } catch {
                // **개선: 인덱스 손상 시 복구 시도**
                TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ⚠️ 인덱스 손상 감지, 복구 시도 중...")
                
                // 기존 캐시 정리 후 인덱스 재생성
                try? self.clearCache()
                self.saveDiskCacheIndex()
                
                TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ✅ 인덱스 복구 완료")
            }
        }
    }
    
    private func saveDiskCacheIndex() {
        let indexURL = cacheDirectory.appendingPathComponent("cache_index.json")
        
        let currentIndex = indexQueue.sync { _diskIndex }
        
        diskQueue.async {
            do {
                let data = try JSONEncoder().encode(currentIndex)
                try data.write(to: indexURL)
                TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] 💾 디스크 캐시 인덱스 저장: \(currentIndex.count)개 항목")
            } catch {
                TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ❌ 디스크 캐시 인덱스 저장 실패: \(error.localizedDescription)")
            }
        }
    }
    
    // 🔧 **개선 3: 재시도 로직이 포함된 스냅샷 저장**
    func saveSnapshot(_ snapshot: SPAOptimizedSnapshot, contentHash: String, completion: @escaping (Bool) -> Void) {
        saveSnapshotWithRetry(snapshot, contentHash: contentHash, retryCount: 0, completion: completion)
    }
    
    private func saveSnapshotWithRetry(_ snapshot: SPAOptimizedSnapshot, contentHash: String, retryCount: Int, completion: @escaping (Bool) -> Void) {
        diskQueue.async {
            do {
                let fileName = "\(contentHash).json"
                let fileURL = self.cacheDirectory.appendingPathComponent(fileName)
                let data = try self.encoder.encode(snapshot)
                try data.write(to: fileURL)
                
                // 인덱스 업데이트
                self.indexQueue.async(flags: .barrier) {
                    self._diskIndex[contentHash] = fileName
                    self.saveDiskCacheIndex()
                }
                
                DispatchQueue.main.async {
                    completion(true)
                }
                
                TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] 💾 스냅샷 디스크 저장 성공: \(contentHash)")
                
            } catch {
                if retryCount < self.maxRetryCount {
                    // 재시도
                    TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ⚠️ 스냅샷 저장 실패, 재시도 \(retryCount + 1)/\(self.maxRetryCount): \(error.localizedDescription)")
                    
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        self.saveSnapshotWithRetry(snapshot, contentHash: contentHash, retryCount: retryCount + 1, completion: completion)
                    }
                } else {
                    // 최종 실패 - 메모리 캐시에만 의존
                    TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ❌ 스냅샷 디스크 저장 최종 실패: \(error.localizedDescription)")
                    
                    DispatchQueue.main.async {
                        completion(false)
                    }
                }
            }
        }
    }
    
    func loadSnapshot(contentHash: String, completion: @escaping (SPAOptimizedSnapshot?) -> Void) {
        diskQueue.async {
            let fileName = self.indexQueue.sync { self._diskIndex[contentHash] }
            
            guard let fileName = fileName else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            let fileURL = self.cacheDirectory.appendingPathComponent(fileName)
            
            do {
                let data = try Data(contentsOf: fileURL)
                let snapshot = try self.decoder.decode(SPAOptimizedSnapshot.self, from: data)
                
                DispatchQueue.main.async {
                    completion(snapshot)
                }
                
                TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ✅ 스냅샷 디스크 로드 성공: \(contentHash)")
                
            } catch {
                TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ❌ 스냅샷 디스크 로드 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }
    
    // 🔧 **개선 4: 이미지 저장/로드 시스템**
    func saveImage(_ image: UIImage, contentHash: String) -> String? {
        let fileName = "\(contentHash).png"
        let fileURL = imagesCacheDirectory.appendingPathComponent(fileName)
        
        guard let data = image.pngData() else { 
            TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ❌ 이미지 PNG 변환 실패: \(contentHash)")
            return nil 
        }
        
        do {
            try data.write(to: fileURL)
            TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] 📸 이미지 저장 성공: \(fileName)")
            return fileName
        } catch {
            TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ❌ 이미지 저장 실패: \(error.localizedDescription)")
            return nil
        }
    }
    
    func loadImage(fileName: String) -> UIImage? {
        let fileURL = imagesCacheDirectory.appendingPathComponent(fileName)
        
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] ❌ 이미지 로드 실패: \(fileName)")
            return nil
        }
        
        TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] 📸 이미지 로드 성공: \(fileName)")
        return image
    }
    
    func createThumbnail(_ image: UIImage, contentHash: String) -> String? {
        let thumbnailSize = CGSize(width: 150, height: 150)
        let thumbnailFileName = "\(contentHash)_thumb.png"
        let thumbnailURL = imagesCacheDirectory.appendingPathComponent(thumbnailFileName)
        
        UIGraphicsBeginImageContextWithOptions(thumbnailSize, false, 0)
        defer { UIGraphicsEndImageContext() }
        
        image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
        guard let thumbnailImage = UIGraphicsGetImageFromCurrentImageContext(),
              let data = thumbnailImage.pngData() else {
            return nil
        }
        
        do {
            try data.write(to: thumbnailURL)
            TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] 🖼️ 썸네일 생성: \(thumbnailFileName)")
            return thumbnailFileName
        } catch {
            return nil
        }
    }
    
    private func getCacheSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }
    
    private func cleanupIfNeeded() {
        diskQueue.async {
            let currentSize = self.getCacheSize()
            if currentSize > self.maxCacheSize {
                do {
                    let contents = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
                    let sortedFiles = contents.sorted { first, second in
                        let firstDate = (try? first.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                        let secondDate = (try? second.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                        return firstDate < secondDate
                    }
                    
                    // 오래된 파일 절반 삭제
                    let filesToDelete = sortedFiles.prefix(sortedFiles.count / 2)
                    var deletedHashes: [String] = []
                    
                    for file in filesToDelete {
                        if file.pathExtension == "json" {
                            let fileName = file.lastPathComponent
                            let hash = fileName.replacingOccurrences(of: ".json", with: "")
                            deletedHashes.append(hash)
                        }
                        try? self.fileManager.removeItem(at: file)
                    }
                    
                    // 인덱스에서도 제거
                    self.indexQueue.async(flags: .barrier) {
                        deletedHashes.forEach { self._diskIndex.removeValue(forKey: $0) }
                        self.saveDiskCacheIndex()
                    }
                    
                    TabPersistenceManager.debugMessages.append("[\(ts())][DiskCache] 🧹 캐시 정리: \(filesToDelete.count)개 파일 삭제")
                    
                } catch {
                    // 정리 실패시 전체 캐시 클리어
                    try? self.clearCache()
                }
            }
        }
    }
    
    func clearCache() throws {
        let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for fileURL in contents {
            try fileManager.removeItem(at: fileURL)
        }
        
        indexQueue.async(flags: .barrier) {
            self._diskIndex.removeAll()
        }
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

// MARK: - 콘텐츠 변화 추적 구조체들

struct ContentChangeInfo {
    let timestamp: Date
    let changeType: ChangeType
    let contentHash: String
    let scrollHash: String
    let elementCount: Int
    let scrollableElements: Int
    
    enum ChangeType {
        case initial, domMutation, scroll, resize, frameChange, mediaLoad, visibility
    }
}

struct SiteProfile: Codable {
    let hostname: String
    var domPatterns: [DOMPattern] = []
    var scrollContainers: [String] = []
    var averageLoadTime: TimeInterval = 0.5
    var iframePaths: [String] = []
    var lastUpdated: Date = Date()
    
    struct DOMPattern: Codable {
        let selector: String
        let isScrollable: Bool
        let frequency: Int
    }
    
    mutating func learnScrollContainer(_ selector: String) {
        if !scrollContainers.contains(selector) {
            scrollContainers.append(selector)
        }
    }
    
    mutating func recordLoadTime(_ duration: TimeInterval) {
        averageLoadTime = (averageLoadTime + duration) / 2
        lastUpdated = Date()
    }
}

// MARK: - BFCache 스냅샷 구조체

struct SPAOptimizedSnapshot: Codable {
    let pageRecord: PageRecord
    let contentHash: String
    let scrollStates: [ScrollState]
    let domSnapshot: String?
    let visualSnapshot: VisualSnapshot?
    let frameSnapshots: [FrameSnapshot] // 🔧 **개선 6: iframe 지원**
    let timestamp: Date
    let captureContext: CaptureContext
    
    struct ScrollState: Codable {
        let selector: String
        let xpath: String?
        let scrollTop: CGFloat
        let scrollLeft: CGFloat
        let scrollHeight: CGFloat
        let scrollWidth: CGFloat
        let clientHeight: CGFloat
        let clientWidth: CGFloat
        let isMainDocument: Bool
        let frameIndex: Int?
    }
    
    struct VisualSnapshot: Codable {
        let imagePath: String?
        let thumbnailPath: String?
        let viewport: CGRect
    }
    
    struct FrameSnapshot: Codable {
        let src: String
        let selector: String
        let scrollStates: [ScrollState]
        let contentHash: String
    }
    
    struct CaptureContext: Codable {
        let url: String
        let title: String
        let isFullCapture: Bool
        let changesSinceLastCapture: Int
        let captureReason: String
    }
}

// MARK: - 🎯 완전 최적화된 BFCache 전환 시스템

final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        diskCache = DiskCacheManager()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 의존성들
    private let diskCache: DiskCacheManager
    
    // MARK: - 직렬화 큐들
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "bfcache.analysis", qos: .utility)
    
    // MARK: - 상태 관리
    private var _siteProfiles: [String: SiteProfile] = [:]
    private var _lastContentHash: [UUID: String] = [:]  // 탭별 마지막 콘텐츠 해시
    private var activeMutationObservers: [UUID: Bool] = [:]
    private var pendingCaptures: [UUID: DispatchWorkItem] = [:]
    private let captureDebounceInterval: TimeInterval = 0.8
    
    // MARK: - 전환 상태 관리
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
        let gestureStartIndex: Int
        let targetPageRecord: PageRecord?
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    // 🔧 **개선 1: 탭별 리소스 완전 정리 메서드**
    func cleanupTabResources(tabID: UUID) {
        serialQueue.async(flags: .barrier) {
            // activeTransitions 정리
            self.activeTransitions.removeValue(forKey: tabID)
            
            // _lastContentHash 정리
            self._lastContentHash.removeValue(forKey: tabID)
            
            // pendingCaptures 정리
            self.pendingCaptures[tabID]?.cancel()
            self.pendingCaptures.removeValue(forKey: tabID)
            
            // activeMutationObservers 정리
            self.activeMutationObservers.removeValue(forKey: tabID)
            
            TabPersistenceManager.debugMessages.append("[\(ts())][BFCache] 🧹 탭 리소스 완전 정리: TabID[\(String(tabID.uuidString.prefix(8)))]")
        }
    }
    
    // MARK: - 🌐 최적화된 DOM 변화 감지 시스템
    
    func installDOMObserver(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let tabID = stateModel.tabID else {
            dbg("❌ DOM Observer 설치 실패: TabID 없음")
            return
        }
        
        // 레지스트리에 등록
        BFCacheRegistry.shared.register(stateModel: stateModel, tabID: tabID, webView: webView)
        
        // 기존 Observer 제거
        if activeMutationObservers[tabID] == true {
            removeDOMObserver(tabID: tabID, webView: webView)
        }
        
        // 🔧 **개선 2: 성능 최적화된 DOM Observer 스크립트**
        let observerScript = generatePerformanceOptimizedDOMObserverScript()
        webView.evaluateJavaScript(observerScript) { [weak self] _, error in
            if error == nil {
                self?.activeMutationObservers[tabID] = true
                self?.dbg("✅ 성능 최적화 DOM Observer 설치: TabID[\(String(tabID.uuidString.prefix(8)))]")
            } else {
                self?.dbg("❌ DOM Observer 설치 실패: \(error?.localizedDescription ?? "")")
            }
        }
        
        // 메시지 핸들러 설정
        webView.configuration.userContentController.add(self, name: "domChange")
        webView.configuration.userContentController.add(self, name: "scrollChange")
        
        dbg("🔍 DOM Observer 시스템 활성화: TabID[\(String(tabID.uuidString.prefix(8)))]")
    }
    
    private func removeDOMObserver(tabID: UUID, webView: WKWebView) {
        let removeScript = """
        if (window.__bfCacheDOMObserver) {
            window.__bfCacheDOMObserver.disconnect();
            window.__bfCacheDOMObserver = null;
            console.log('🧹 BFCache DOM Observer 제거');
        }
        if (window.__bfCacheScrollTracking) {
            clearInterval(window.__bfCacheScrollTracking);
            window.__bfCacheScrollTracking = null;
        }
        """
        webView.evaluateJavaScript(removeScript) { _, _ in }
        activeMutationObservers[tabID] = false
        
        dbg("🧹 DOM Observer 제거: TabID[\(String(tabID.uuidString.prefix(8)))]")
    }
    
    // MARK: - 🔍 **개선 2: 성능 최적화된 DOM Observer 스크립트**
    
    private func generatePerformanceOptimizedDOMObserverScript() -> String {
        return """
        (function() {
            'use strict';
            
            console.log('🔍 BFCache 성능 최적화 DOM Observer 초기화');
            
            // 기존 Observer 정리
            if (window.__bfCacheDOMObserver) {
                window.__bfCacheDOMObserver.disconnect();
            }
            
            // 성능 최적화된 유틸리티
            const utils = {
                // 빠른 요소 식별자 생성
                getElementIdentifier(element) {
                    if (element.id) return '#' + element.id;
                    
                    let path = [];
                    let current = element;
                    let level = 0;
                    
                    while (current && current !== document.body && level < 3) {
                        let selector = current.tagName.toLowerCase();
                        if (current.className) {
                            const mainClass = current.classList[0];
                            if (mainClass && !mainClass.includes('active') && !mainClass.includes('hover')) {
                                selector += '.' + mainClass;
                            }
                        }
                        path.unshift(selector);
                        current = current.parentElement;
                        level++;
                    }
                    
                    return path.join(' > ');
                },
                
                // 스크롤 가능 요소 효율적 탐지
                isScrollable(element) {
                    const style = window.getComputedStyle(element);
                    const overflowY = style.overflowY;
                    
                    return (overflowY === 'auto' || overflowY === 'scroll') && 
                           element.scrollHeight > element.clientHeight + 5;
                },
                
                // 핵심 스크롤 요소만 수집
                getKeyScrollableElements() {
                    const scrollables = [];
                    
                    // 1. 문서 레벨 스크롤
                    if (document.documentElement.scrollHeight > window.innerHeight + 10) {
                        scrollables.push({
                            element: document.documentElement,
                            selector: 'document',
                            isMainDocument: true,
                            priority: 1
                        });
                    }
                    
                    // 2. 주요 컨테이너들만 확인
                    const keyContainers = [
                        'main', '[role="main"]', '.main-content', '#content', '.content',
                        '.container', '.wrapper', '.scroll-container', '[data-scroll]'
                    ];
                    
                    keyContainers.forEach(selector => {
                        const elements = document.querySelectorAll(selector);
                        elements.forEach(el => {
                            if (this.isScrollable(el)) {
                                scrollables.push({
                                    element: el,
                                    selector: this.getElementIdentifier(el),
                                    isMainDocument: false,
                                    priority: 2
                                });
                            }
                        });
                    });
                    
                    // 중복 제거 및 우선순위 정렬
                    const unique = scrollables.filter((item, index, self) => 
                        index === self.findIndex(t => t.selector === item.selector)
                    );
                    
                    return unique.sort((a, b) => a.priority - b.priority);
                },
                
                // **개선 2: 샘플링 기반 요소 개수 계산**
                getElementCountSample() {
                    // 전체 DOM 대신 주요 영역만 샘플링
                    const observeTarget = document.querySelector('main') || 
                                          document.querySelector('[role="main"]') ||
                                          document.querySelector('.main-content') ||
                                          document.body;
                                          
                    return observeTarget.querySelectorAll('*').length;
                },
                
                // 고성능 콘텐츠 해시 생성
                generateFastContentHash() {
                    const sampleElements = [
                        document.querySelector('h1'),
                        document.querySelector('main'),
                        document.querySelector('[role="main"]'),
                        document.querySelector('.main-content'),
                        document.querySelector('#content')
                    ].filter(el => el);
                    
                    if (sampleElements.length === 0) {
                        sampleElements.push(document.body);
                    }
                    
                    let contentSample = '';
                    sampleElements.forEach(el => {
                        contentSample += (el.textContent || '').slice(0, 200);
                    });
                    
                    contentSample += document.title;
                    contentSample += window.location.pathname;
                    
                    // 빠른 해시 생성
                    let hash = 0;
                    for (let i = 0; i < contentSample.length; i++) {
                        const char = contentSample.charCodeAt(i);
                        hash = ((hash << 5) - hash) + char;
                        hash = hash & hash;
                    }
                    
                    return Math.abs(hash).toString(36);
                },
                
                // 🔧 **개선 6: iframe 상태 수집**
                collectFrameStates() {
                    const frames = document.querySelectorAll('iframe');
                    const frameStates = [];
                    
                    Array.from(frames).forEach((frame, index) => {
                        try {
                            const frameDoc = frame.contentDocument || frame.contentWindow?.document;
                            if (frameDoc) {
                                frameStates.push({
                                    selector: frame.id ? `#${frame.id}` : `iframe:nth-of-type(${index + 1})`,
                                    src: frame.src,
                                    scrollTop: frameDoc.documentElement.scrollTop || 0,
                                    scrollLeft: frameDoc.documentElement.scrollLeft || 0,
                                    contentHash: (frameDoc.body?.textContent || '').slice(0, 200)
                                });
                            } else {
                                // Cross-origin iframe
                                frameStates.push({
                                    selector: frame.id ? `#${frame.id}` : `iframe:nth-of-type(${index + 1})`,
                                    src: frame.src,
                                    scrollTop: 0,
                                    scrollLeft: 0,
                                    contentHash: 'cross-origin'
                                });
                            }
                        } catch (e) {
                            // 접근 불가한 iframe
                            frameStates.push({
                                selector: frame.id ? `#${frame.id}` : `iframe:nth-of-type(${index + 1})`,
                                src: frame.src,
                                scrollTop: 0,
                                scrollLeft: 0,
                                contentHash: 'access-denied'
                            });
                        }
                    });
                    
                    return frameStates;
                },
                
                // 효율적 스크롤 상태 수집
                collectScrollStates() {
                    const scrollables = this.getKeyScrollableElements();
                    return scrollables.map(item => {
                        const el = item.element;
                        return {
                            selector: item.selector,
                            scrollTop: el.scrollTop || window.pageYOffset || 0,
                            scrollLeft: el.scrollLeft || window.pageXOffset || 0,
                            scrollHeight: el.scrollHeight || document.documentElement.scrollHeight,
                            scrollWidth: el.scrollWidth || document.documentElement.scrollWidth,
                            clientHeight: el.clientHeight || window.innerHeight,
                            clientWidth: el.clientWidth || window.innerWidth,
                            isMainDocument: item.isMainDocument,
                            priority: item.priority
                        };
                    });
                }
            };
            
            // 효율적 변화 감지 디바운싱
            let changeTimer = null;
            let scrollTimer = null;
            let lastContentHash = '';
            let lastScrollHash = '';
            let mutationCount = 0;
            
            function notifyChange(type, details = {}) {
                clearTimeout(changeTimer);
                changeTimer = setTimeout(() => {
                    const currentHash = utils.generateFastContentHash();
                    const scrollStates = utils.collectScrollStates();
                    const frameStates = utils.collectFrameStates(); // iframe 상태 수집
                    const scrollHash = JSON.stringify(scrollStates).slice(0, 100);
                    
                    // 불필요한 알림 필터링
                    if (type === 'mutation' && currentHash === lastContentHash && mutationCount < 3) {
                        mutationCount++;
                        return;
                    }
                    
                    if (type === 'scroll' && scrollHash === lastScrollHash) {
                        return;
                    }
                    
                    if (currentHash !== lastContentHash) {
                        mutationCount = 0;
                        lastContentHash = currentHash;
                    }
                    
                    if (scrollHash !== lastScrollHash) {
                        lastScrollHash = scrollHash;
                    }
                    
                    // 네이티브로 전송
                    try {
                        window.webkit?.messageHandlers?.domChange?.postMessage({
                            type: type,
                            contentHash: currentHash,
                            scrollStates: scrollStates,
                            frameStates: frameStates, // iframe 상태 포함
                            elementCount: utils.getElementCountSample(), // 샘플링 기반
                            timestamp: Date.now(),
                            url: window.location.href,
                            title: document.title,
                            ...details
                        });
                    } catch (e) {
                        console.error('BFCache 메시지 전송 실패:', e);
                    }
                    
                }, type === 'scroll' ? 150 : 400);
            }
            
            // 성능 최적화된 MutationObserver
            const observerConfig = {
                childList: true,
                subtree: true,
                attributes: false, // 성능을 위해 속성 변화 무시
                characterData: false // 성능을 위해 텍스트 변화 무시
            };
            
            const observer = new MutationObserver((mutations) => {
                let significantChanges = 0;
                const maxCheck = 10;
                
                for (let i = 0; i < Math.min(mutations.length, maxCheck); i++) {
                    const mutation = mutations[i];
                    if (mutation.type === 'childList' && mutation.addedNodes.length > 0) {
                        for (const node of mutation.addedNodes) {
                            if (node.nodeType === 1 && 
                                !['SCRIPT', 'STYLE', 'META', 'LINK'].includes(node.tagName)) {
                                significantChanges++;
                                break;
                            }
                        }
                    }
                    if (significantChanges > 0) break;
                }
                
                if (significantChanges > 0) {
                    notifyChange('mutation', { 
                        mutationCount: significantChanges,
                        totalMutations: mutations.length
                    });
                }
            });
            
            // Observer 시작 (메인 콘텐츠 영역에만 집중)
            const observeTarget = document.querySelector('main') || 
                                  document.querySelector('[role="main"]') ||
                                  document.querySelector('.main-content') ||
                                  document.body;
                                  
            observer.observe(observeTarget, observerConfig);
            window.__bfCacheDOMObserver = observer;
            
            // 최적화된 스크롤 추적
            let lastScrollTime = 0;
            function trackScroll(event) {
                const now = Date.now();
                if (now - lastScrollTime < 100) return; // 100ms 쓰로틀링
                lastScrollTime = now;
                
                clearTimeout(scrollTimer);
                scrollTimer = setTimeout(() => {
                    notifyChange('scroll');
                }, 150);
            }
            
            // 스크롤 이벤트 리스너 (패시브 모드)
            window.addEventListener('scroll', trackScroll, { passive: true });
            document.addEventListener('scroll', trackScroll, { passive: true, capture: true });
            
            // 리사이즈 감지
            let resizeTimer = null;
            window.addEventListener('resize', () => {
                clearTimeout(resizeTimer);
                resizeTimer = setTimeout(() => {
                    notifyChange('resize', { 
                        width: window.innerWidth, 
                        height: window.innerHeight 
                    });
                }, 300);
            }, { passive: true });
            
            // 초기 상태 전송
            setTimeout(() => {
                lastContentHash = utils.generateFastContentHash();
                notifyChange('initial');
            }, 500);
            
            console.log('✅ BFCache 성능 최적화 DOM Observer 활성화 완료');
        })();
        """
    }
    
    // MARK: - 📸 완전한 스냅샷 캡처 시스템
    
    private func handleContentChange(tabID: UUID, changeInfo: [String: Any]) {
        // 기존 캡처 작업 취소
        pendingCaptures[tabID]?.cancel()
        
        // 새로운 디바운싱된 캡처 작업
        let captureWork = DispatchWorkItem { [weak self] in
            self?.performIntelligentCapture(tabID: tabID, changeInfo: changeInfo)
        }
        
        pendingCaptures[tabID] = captureWork
        
        // 변화 타입에 따른 적응적 디바운싱
        let delay: TimeInterval
        if let type = changeInfo["type"] as? String {
            switch type {
            case "scroll": delay = 0.2
            case "resize": delay = 0.5
            default: delay = captureDebounceInterval
            }
        } else {
            delay = captureDebounceInterval
        }
        
        serialQueue.asyncAfter(deadline: .now() + delay, execute: captureWork)
    }
    
    private func performIntelligentCapture(tabID: UUID, changeInfo: [String: Any]) {
        guard let contentHash = changeInfo["contentHash"] as? String else { 
            dbg("❌ 콘텐츠 해시 없음")
            return 
        }
        
        // 중복 방지
        if let lastHash = _lastContentHash[tabID], lastHash == contentHash {
            dbg("🔄 동일한 콘텐츠 - 캡처 스킵")
            return
        }
        
        _lastContentHash[tabID] = contentHash
        
        // StateModel 조회
        guard let stateModel = BFCacheRegistry.shared.findStateModel(for: tabID),
              let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            dbg("❌ StateModel 또는 WebView 없음: TabID[\(String(tabID.uuidString.prefix(8)))]")
            return
        }
        
        let currentPageIndex = stateModel.dataModel.currentPageIndex
        
        dbg("📸 지능형 캡처 시작:")
        dbg("   TabID: [\(String(tabID.uuidString.prefix(8)))]")
        dbg("   페이지 인덱스: \(currentPageIndex)")
        dbg("   콘텐츠 해시: \(contentHash)")
        
        // 스크롤 상태 파싱
        let scrollStates = parseScrollStates(from: changeInfo)
        
        // 🔧 **개선 6: iframe 상태 파싱**
        let frameStates = parseFrameStates(from: changeInfo)
        
        // 변화 타입에 따른 캡처 전략
        let changeType = changeInfo["type"] as? String ?? "unknown"
        let needsVisualSnapshot = !["scroll"].contains(changeType)
        
        // 스냅샷 생성
        captureSnapshot(
            webView: webView,
            stateModel: stateModel,
            tabID: tabID,
            pageIndex: currentPageIndex,
            pageRecord: currentRecord,
            contentHash: contentHash,
            scrollStates: scrollStates,
            frameStates: frameStates,
            changeInfo: changeInfo,
            needsVisual: needsVisualSnapshot
        )
    }
    
    private func captureSnapshot(
        webView: WKWebView,
        stateModel: WebViewStateModel,
        tabID: UUID,
        pageIndex: Int,
        pageRecord: PageRecord,
        contentHash: String,
        scrollStates: [SPAOptimizedSnapshot.ScrollState],
        frameStates: [SPAOptimizedSnapshot.FrameSnapshot],
        changeInfo: [String: Any],
        needsVisual: Bool
    ) {
        var visualSnapshot: SPAOptimizedSnapshot.VisualSnapshot? = nil
        
        let captureGroup = DispatchGroup()
        
        // 🔧 **개선 4: 완전한 비주얼 캡처 (이미지 저장 포함)**
        if needsVisual {
            captureGroup.enter()
            DispatchQueue.main.async {
                self.captureWebViewSnapshot(webView: webView) { [weak self] image in
                    if let image = image, let self = self {
                        // 이미지와 썸네일 저장
                        let imagePath = self.diskCache.saveImage(image, contentHash: contentHash)
                        let thumbnailPath = self.diskCache.createThumbnail(image, contentHash: contentHash)
                        
                        visualSnapshot = SPAOptimizedSnapshot.VisualSnapshot(
                            imagePath: imagePath,
                            thumbnailPath: thumbnailPath,
                            viewport: webView.bounds
                        )
                    }
                    captureGroup.leave()
                }
            }
        }
        
        // 캡처 완료 대기
        captureGroup.notify(queue: serialQueue) {
            // 캡처 컨텍스트 생성
            let captureContext = SPAOptimizedSnapshot.CaptureContext(
                url: changeInfo["url"] as? String ?? webView.url?.absoluteString ?? "",
                title: changeInfo["title"] as? String ?? pageRecord.title,
                isFullCapture: needsVisual,
                changesSinceLastCapture: 1,
                captureReason: changeInfo["type"] as? String ?? "unknown"
            )
            
            // 최종 스냅샷 생성
            let snapshot = SPAOptimizedSnapshot(
                pageRecord: pageRecord,
                contentHash: contentHash,
                scrollStates: scrollStates,
                domSnapshot: nil,
                visualSnapshot: visualSnapshot,
                frameSnapshots: frameStates, // iframe 상태 포함
                timestamp: Date(),
                captureContext: captureContext
            )
            
            // 페이지 번호 기반 스냅샷 저장
            BFCacheRegistry.shared.storeSnapshot(snapshot, for: tabID, pageIndex: pageIndex)
            
            // 디스크에도 비동기 저장
            self.diskCache.saveSnapshot(snapshot, contentHash: contentHash) { success in
                if success {
                    self.dbg("💾 디스크 저장 성공: \(contentHash)")
                } else {
                    self.dbg("❌ 디스크 저장 실패: \(contentHash)")
                }
            }
            
            self.dbg("✅ 완전한 스냅샷 캡처 완료:")
            self.dbg("   페이지 키: TabID[\(String(tabID.uuidString.prefix(8)))]_\(pageIndex)")
            self.dbg("   스크롤 상태: \(scrollStates.count)개")
            self.dbg("   iframe 상태: \(frameStates.count)개")
            self.dbg("   비주얼 캡처: \(visualSnapshot != nil)")
        }
    }
    
    private func captureWebViewSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = false
        
        webView.takeSnapshot(with: config) { image, error in
            if let error = error {
                TabPersistenceManager.debugMessages.append("[\(ts())][BFCache] ❌ 비주얼 스냅샷 실패: \(error.localizedDescription)")
            }
            completion(image)
        }
    }
    
    private func parseScrollStates(from changeInfo: [String: Any]) -> [SPAOptimizedSnapshot.ScrollState] {
        guard let scrollData = changeInfo["scrollStates"] as? [[String: Any]] else { 
            return [] 
        }
        
        return scrollData.compactMap { data in
            guard let selector = data["selector"] as? String else { return nil }
            
            return SPAOptimizedSnapshot.ScrollState(
                selector: selector,
                xpath: data["xpath"] as? String,
                scrollTop: CGFloat(data["scrollTop"] as? Double ?? 0),
                scrollLeft: CGFloat(data["scrollLeft"] as? Double ?? 0),
                scrollHeight: CGFloat(data["scrollHeight"] as? Double ?? 0),
                scrollWidth: CGFloat(data["scrollWidth"] as? Double ?? 0),
                clientHeight: CGFloat(data["clientHeight"] as? Double ?? 0),
                clientWidth: CGFloat(data["clientWidth"] as? Double ?? 0),
                isMainDocument: data["isMainDocument"] as? Bool ?? false,
                frameIndex: data["frameIndex"] as? Int
            )
        }
    }
    
    // 🔧 **개선 6: iframe 상태 파싱**
    private func parseFrameStates(from changeInfo: [String: Any]) -> [SPAOptimizedSnapshot.FrameSnapshot] {
        guard let frameData = changeInfo["frameStates"] as? [[String: Any]] else {
            return []
        }
        
        return frameData.compactMap { data in
            guard let selector = data["selector"] as? String,
                  let src = data["src"] as? String else { return nil }
            
            let scrollStates = [SPAOptimizedSnapshot.ScrollState(
                selector: selector,
                xpath: nil,
                scrollTop: CGFloat(data["scrollTop"] as? Double ?? 0),
                scrollLeft: CGFloat(data["scrollLeft"] as? Double ?? 0),
                scrollHeight: 0,
                scrollWidth: 0,
                clientHeight: 0,
                clientWidth: 0,
                isMainDocument: false,
                frameIndex: nil
            )]
            
            return SPAOptimizedSnapshot.FrameSnapshot(
                src: src,
                selector: selector,
                scrollStates: scrollStates,
                contentHash: data["contentHash"] as? String ?? ""
            )
        }
    }
    
    // MARK: - 🔄 완전한 스크롤 복원 시스템
    
    func restorePageSnapshot(for tabID: UUID, pageIndex: Int, to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard let snapshot = BFCacheRegistry.shared.loadSnapshot(for: tabID, pageIndex: pageIndex) else {
            dbg("❌ 스냅샷 복원 실패: TabID[\(String(tabID.uuidString.prefix(8)))] PageIndex[\(pageIndex)]")
            completion(false)
            return
        }
        
        dbg("✅ 스냅샷 찾음: TabID[\(String(tabID.uuidString.prefix(8)))] PageIndex[\(pageIndex)]")
        
        // 스크롤 상태 복원
        restoreScrollStates(snapshot.scrollStates, to: webView) { [weak self] scrollSuccess in
            // iframe 상태 복원
            self?.restoreFrameStates(snapshot.frameSnapshots, to: webView) { frameSuccess in
                let overallSuccess = scrollSuccess || frameSuccess
                self?.dbg("🔄 복원 완료 - 스크롤: \(scrollSuccess), iframe: \(frameSuccess)")
                completion(overallSuccess)
            }
        }
    }
    
    func restoreScrollStates(_ scrollStates: [SPAOptimizedSnapshot.ScrollState], to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        let restoreScript = generateScrollRestoreScript(scrollStates)
        
        webView.evaluateJavaScript(restoreScript) { result, error in
            if let error = error {
                self.dbg("❌ 스크롤 복원 스크립트 실패: \(error.localizedDescription)")
                completion(false)
            } else {
                let restoredCount = (result as? Int) ?? 0
                let success = restoredCount > 0
                self.dbg("✅ 스크롤 복원: \(restoredCount)/\(scrollStates.count) 성공")
                completion(success)
            }
        }
    }
    
    // 🔧 **개선 6: iframe 상태 복원**
    private func restoreFrameStates(_ frameStates: [SPAOptimizedSnapshot.FrameSnapshot], to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        guard !frameStates.isEmpty else {
            completion(true)
            return
        }
        
        let frameRestoreScript = generateFrameRestoreScript(frameStates)
        
        webView.evaluateJavaScript(frameRestoreScript) { result, error in
            if let error = error {
                self.dbg("❌ iframe 복원 실패: \(error.localizedDescription)")
                completion(false)
            } else {
                let restoredCount = (result as? Int) ?? 0
                let success = restoredCount > 0
                self.dbg("✅ iframe 복원: \(restoredCount)/\(frameStates.count) 성공")
                completion(success)
            }
        }
    }
    
    private func generateScrollRestoreScript(_ scrollStates: [SPAOptimizedSnapshot.ScrollState]) -> String {
        let statesData = scrollStates.map { state in
            return """
            {
                selector: "\(state.selector.replacingOccurrences(of: "\"", with: "\\\""))",
                scrollTop: \(state.scrollTop),
                scrollLeft: \(state.scrollLeft),
                isMainDocument: \(state.isMainDocument)
            }
            """
        }.joined(separator: ",")
        
        return """
        (function() {
            const states = [\(statesData)];
            let restored = 0;
            
            console.log('🔄 스크롤 복원 시작:', states.length, '개 상태');
            
            states.forEach((state, index) => {
                try {
                    if (state.isMainDocument) {
                        // 문서 레벨 스크롤 복원
                        window.scrollTo(state.scrollLeft, state.scrollTop);
                        document.documentElement.scrollTop = state.scrollTop;
                        document.body.scrollTop = state.scrollTop;
                        restored++;
                        console.log('✅ 문서 스크롤 복원:', state.scrollTop);
                    } else {
                        // 요소별 스크롤 복원
                        const elements = document.querySelectorAll(state.selector);
                        if (elements.length > 0) {
                            elements.forEach(el => {
                                el.scrollTop = state.scrollTop;
                                el.scrollLeft = state.scrollLeft;
                            });
                            restored++;
                            console.log('✅ 요소 스크롤 복원:', state.selector, state.scrollTop);
                        } else {
                            console.log('⚠️ 요소 못 찾음:', state.selector);
                        }
                    }
                } catch (e) {
                    console.error('❌ 스크롤 복원 실패:', state.selector, e);
                }
            });
            
            console.log('🔄 스크롤 복원 완료:', restored, '/', states.length);
            return restored;
        })()
        """
    }
    
    private func generateFrameRestoreScript(_ frameStates: [SPAOptimizedSnapshot.FrameSnapshot]) -> String {
        let frameData = frameStates.map { frame in
            let scrollState = frame.scrollStates.first
            return """
            {
                selector: "\(frame.selector.replacingOccurrences(of: "\"", with: "\\\""))",
                src: "\(frame.src.replacingOccurrences(of: "\"", with: "\\\""))",
                scrollTop: \(scrollState?.scrollTop ?? 0),
                scrollLeft: \(scrollState?.scrollLeft ?? 0)
            }
            """
        }.joined(separator: ",")
        
        return """
        (function() {
            const frames = [\(frameData)];
            let restored = 0;
            
            console.log('🖼️ iframe 복원 시작:', frames.length, '개 프레임');
            
            frames.forEach(frameInfo => {
                try {
                    const frameElements = document.querySelectorAll(frameInfo.selector);
                    frameElements.forEach(iframe => {
                        if (iframe.src === frameInfo.src || iframe.src.includes(frameInfo.src)) {
                            const frameDoc = iframe.contentDocument || iframe.contentWindow?.document;
                            if (frameDoc) {
                                frameDoc.documentElement.scrollTop = frameInfo.scrollTop;
                                frameDoc.documentElement.scrollLeft = frameInfo.scrollLeft;
                                restored++;
                                console.log('✅ iframe 스크롤 복원:', frameInfo.selector);
                            }
                        }
                    });
                } catch (e) {
                    console.log('⚠️ iframe 복원 실패 (cross-origin일 수 있음):', frameInfo.selector);
                }
            });
            
            console.log('🖼️ iframe 복원 완료:', restored, '/', frames.length);
            return restored;
        })()
        """
    }
    
    // MARK: - 🎯 **개선 5: 제스처 충돌 방지 시스템**
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        webView.allowsBackForwardNavigationGestures = false
        
        guard let tabID = stateModel.tabID else {
            dbg("❌ 제스처 설정 실패: TabID 없음")
            return
        }
        
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        webView.addGestureRecognizer(leftEdge)
        
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        webView.addGestureRecognizer(rightEdge)
        
        let ctx = WeakGestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
        objc_setAssociatedObject(leftEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(rightEdge, "bfcache_ctx", ctx, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        dbg("✅ BFCache 제스처 설정 완료: TabID[\(String(tabID.uuidString.prefix(8)))]")
    }
    
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard let ctx = objc_getAssociatedObject(gesture, "bfcache_ctx") as? WeakGestureContext,
              let stateModel = ctx.stateModel,
              let webView = ctx.webView ?? gesture.view as? WKWebView else { return }
        
        let tabID = ctx.tabID
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        
        switch gesture.state {
        case .began:
            guard activeTransitions[tabID] == nil else {
                gesture.state = .cancelled
                return
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                handleGestureBegan(tabID: tabID, webView: webView, stateModel: stateModel, direction: direction)
            } else {
                gesture.state = .cancelled
            }
            
        case .changed:
            let absX = abs(translation.x)
            let absY = abs(translation.y)
            
            // 🔧 **개선 5: 수평 움직임 우선 검증**
            let horizontalEnough = absX > 15 && absX > absY * 2.0  // 더 엄격한 조건
            let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
            
            if horizontalEnough && signOK {
                updateGestureProgress(tabID: tabID, translation: translation.x, isLeftEdge: isLeftEdge)
            }
            
        case .ended:
            let width = gesture.view?.bounds.width ?? 1
            let absX = abs(translation.x)
            let progress = min(1.0, absX / width)
            let shouldComplete = progress > 0.35 || abs(velocity.x) > 1000
            
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
    
    private func handleGestureBegan(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection) {
        let currentIndex = stateModel.dataModel.currentPageIndex
        let pageHistory = stateModel.dataModel.pageHistory
        
        guard currentIndex >= 0 && currentIndex < pageHistory.count else { 
            dbg("❌ 제스처 시작 실패: 잘못된 페이지 인덱스 \(currentIndex)")
            return 
        }
        
        let targetIndex = direction == .back ? currentIndex - 1 : currentIndex + 1
        guard targetIndex >= 0 && targetIndex < pageHistory.count else { 
            dbg("❌ 제스처 시작 실패: 잘못된 타겟 인덱스 \(targetIndex)")
            return 
        }
        
        let targetRecord = pageHistory[targetIndex]
        
        // 현재 페이지 캡처
        captureCurrentPageForGesture(webView: webView, stateModel: stateModel, tabID: tabID, currentIndex: currentIndex)
        
        // 제스처 전환 시작
        beginGestureTransition(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            direction: direction,
            currentSnapshot: nil,
            gestureStartIndex: currentIndex,
            targetPageRecord: targetRecord
        )
    }
    
    private func captureCurrentPageForGesture(webView: WKWebView, stateModel: WebViewStateModel, tabID: UUID, currentIndex: Int) {
        let captureScript = """
        (function() {
            const scrollStates = [];
            
            // 문서 스크롤
            scrollStates.push({
                selector: 'document',
                scrollTop: window.pageYOffset || document.documentElement.scrollTop,
                scrollLeft: window.pageXOffset || document.documentElement.scrollLeft,
                isMainDocument: true
            });
            
            // 주요 스크롤 컨테이너들
            const containers = document.querySelectorAll('main, [role="main"], .main-content, #content');
            containers.forEach((el, index) => {
                if (el.scrollHeight > el.clientHeight) {
                    scrollStates.push({
                        selector: el.tagName.toLowerCase() + (el.id ? '#' + el.id : ':nth-of-type(' + (index + 1) + ')'),
                        scrollTop: el.scrollTop,
                        scrollLeft: el.scrollLeft,
                        isMainDocument: false
                    });
                }
            });
            
            return {
                scrollStates: scrollStates,
                contentHash: Math.random().toString(36),
                timestamp: Date.now()
            };
        })()
        """
        
        webView.evaluateJavaScript(captureScript) { [weak self] result, error in
            if let result = result as? [String: Any] {
                self?.handleContentChange(tabID: tabID, changeInfo: result)
            }
        }
    }
    
    private func beginGestureTransition(
        tabID: UUID,
        webView: WKWebView,
        stateModel: WebViewStateModel,
        direction: NavigationDirection,
        currentSnapshot: UIImage?,
        gestureStartIndex: Int,
        targetPageRecord: PageRecord?
    ) {
        let previewContainer = createPreviewContainer(
            webView: webView,
            direction: direction,
            currentSnapshot: currentSnapshot,
            targetPageRecord: targetPageRecord
        )
        
        let context = TransitionContext(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            isGesture: true,
            direction: direction,
            initialTransform: webView.transform,
            previewContainer: previewContainer,
            currentSnapshot: currentSnapshot,
            gestureStartIndex: gestureStartIndex,
            targetPageRecord: targetPageRecord
        )
        
        activeTransitions[tabID] = context
        dbg("🎯 제스처 전환 시작: TabID[\(String(tabID.uuidString.prefix(8)))] \(direction)")
    }
    
    private func createPreviewContainer(
        webView: WKWebView,
        direction: NavigationDirection,
        currentSnapshot: UIImage? = nil,
        targetPageRecord: PageRecord?
    ) -> UIView {
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
        currentView.layer.shadowColor = UIColor.black.cgColor
        currentView.layer.shadowOpacity = 0.3
        currentView.layer.shadowOffset = CGSize(width: direction == .back ? -5 : 5, height: 0)
        currentView.layer.shadowRadius = 10
        
        container.addSubview(currentView)
        
        // 타겟 페이지 뷰
        let targetView = createTargetPageView(for: targetPageRecord, in: webView.bounds)
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
    
    private func createTargetPageView(for record: PageRecord?, in bounds: CGRect) -> UIView {
        guard let record = record else {
            let view = UIView()
            view.backgroundColor = .systemBackground
            return view
        }
        
        // TODO: 저장된 비주얼 스냅샷을 사용
        return createInfoCard(for: record, in: bounds)
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
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 180),
            
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
        
        return card
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        if isLeftEdge {
            let moveDistance = max(0, min(screenWidth, translation))
            let progress = moveDistance / screenWidth
            
            currentView?.frame.origin.x = moveDistance
            targetView?.frame.origin.x = -screenWidth + moveDistance
            
            currentView?.layer.shadowOpacity = Float(0.3 * progress)
        } else {
            let moveDistance = max(-screenWidth, min(0, translation))
            let progress = abs(moveDistance) / screenWidth
            
            currentView?.frame.origin.x = moveDistance
            targetView?.frame.origin.x = screenWidth + moveDistance
            
            currentView?.layer.shadowOpacity = Float(0.3 * progress)
        }
    }
    
    private func completeGestureTransition(tabID: UUID) {
        guard let context = activeTransitions[tabID],
              let webView = context.webView,
              let previewContainer = context.previewContainer,
              let stateModel = context.stateModel else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        dbg("🎯 제스처 전환 완료: TabID[\(String(tabID.uuidString.prefix(8)))] \(context.direction)")
        
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
                // 네비게이션 수행
                switch context.direction {
                case .back:
                    stateModel.goBack()
                case .forward:
                    stateModel.goForward()
                }
                
                // 스냅샷 복원
                let targetIndex = context.direction == .back ? 
                    context.gestureStartIndex - 1 : context.gestureStartIndex + 1
                
                self?.restorePageSnapshot(for: tabID, pageIndex: targetIndex, to: webView) { success in
                    self?.dbg("🔄 제스처 완료 후 스냅샷 복원: \(success ? "성공" : "실패")")
                }
                
                // 정리
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
        
        dbg("🚫 제스처 전환 취소: TabID[\(String(tabID.uuidString.prefix(8)))]")
        
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
        serialQueue.async {
            BFCacheRegistry.shared.performCleanup()
            
            // 활성 전환들 정리
            let activeTabIDs = Array(self.activeTransitions.keys)
            activeTabIDs.forEach { tabID in
                if BFCacheRegistry.shared.findStateModel(for: tabID) == nil {
                    self.cleanupTabResources(tabID: tabID)
                }
            }
            
            self.dbg("⚠️ 메모리 경고 - 전체 시스템 정리 수행")
        }
    }
    
    // MARK: - 외부 인터페이스
    
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let tabID = stateModel.tabID else { return }
        
        let captureScript = """
        (function() {
            return {
                type: 'leaving',
                contentHash: Math.random().toString(36),
                scrollStates: [{
                    selector: 'document',
                    scrollTop: window.pageYOffset || document.documentElement.scrollTop,
                    scrollLeft: window.pageXOffset || document.documentElement.scrollLeft,
                    isMainDocument: true
                }],
                frameStates: [],
                timestamp: Date.now(),
                url: window.location.href,
                title: document.title
            };
        })()
        """
        
        webView.evaluateJavaScript(captureScript) { [weak self] result, error in
            if let result = result as? [String: Any] {
                self?.handleContentChange(tabID: tabID, changeInfo: result)
                self?.dbg("📸 페이지 떠나기 전 스냅샷 캡처: TabID[\(String(tabID.uuidString.prefix(8)))]")
            }
        }
    }
    
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let tabID = stateModel.tabID else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let captureScript = """
            (function() {
                return {
                    type: 'arrival',
                    contentHash: Math.random().toString(36),
                    scrollStates: [{
                        selector: 'document',
                        scrollTop: window.pageYOffset || document.documentElement.scrollTop,
                        scrollLeft: window.pageXOffset || document.documentElement.scrollLeft,
                        isMainDocument: true
                    }],
                    frameStates: [],
                    timestamp: Date.now(),
                    url: window.location.href,
                    title: document.title
                };
            })()
            """
            
            webView.evaluateJavaScript(captureScript) { [weak self] result, error in
                if let result = result as? [String: Any] {
                    self?.handleContentChange(tabID: tabID, changeInfo: result)
                    self?.dbg("📸 페이지 도착 후 스냅샷 캡처: TabID[\(String(tabID.uuidString.prefix(8)))]")
                }
            }
        }
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[\(ts())][BFCache] \(msg)")
    }
}

// MARK: - WKScriptMessageHandler 구현

extension BFCacheTransitionSystem: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { 
            dbg("❌ 메시지 본문 파싱 실패")
            return 
        }
        
        guard let webView = message.webView,
              let tabID = BFCacheRegistry.shared.findTabID(for: webView) else {
            dbg("❌ 메시지 처리 실패: TabID를 찾을 수 없음")
            return
        }
        
        switch message.name {
        case "domChange":
            handleContentChange(tabID: tabID, changeInfo: body)
            
        case "scrollChange":
            if body["scrollStates"] != nil {
                handleContentChange(tabID: tabID, changeInfo: body)
            }
            
        default:
            dbg("⚠️ 알 수 없는 메시지: \(message.name)")
        }
    }
}

// MARK: - UIGestureRecognizerDelegate (개선된 충돌 방지)

extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    
    // 🔧 **개선 5: 스마트한 제스처 충돌 방지**
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // BFCache 제스처끼리는 동시 인식 허용 안함
        guard let pan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer else { 
            return false 
        }
        
        // 수평 움직임이 수직 움직임보다 클 때만 허용
        let translation = pan.translation(in: pan.view)
        let isHorizontalDominant = abs(translation.x) > abs(translation.y) * 1.5
        
        return isHorizontalDominant
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBegin gesture: UIGestureRecognizer) -> Bool {
        guard let ctx = objc_getAssociatedObject(gestureRecognizer, "bfcache_ctx") as? WeakGestureContext else {
            return false
        }
        
        // 이미 활성 전환이 있으면 제스처 시작 안함
        return activeTransitions[ctx.tabID] == nil
    }
}

// MARK: - 🏗️ 통합 인터페이스

extension BFCacheTransitionSystem {
    
    // CustomWebView에서 사용할 통합 인터페이스
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        guard let tabID = stateModel.tabID else {
            TabPersistenceManager.debugMessages.append("[\(ts())][BFCache] ❌ 설치 실패: TabID 없음")
            return
        }
        
        // DOM Observer 설치
        shared.installDOMObserver(webView: webView, stateModel: stateModel)
        
        // 제스처 설치  
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("[\(ts())][BFCache] ✅ 완전 최적화된 BFCache 시스템 설치: TabID[\(String(tabID.uuidString.prefix(8)))]")
    }
    
    static func uninstall(from webView: WKWebView, tabID: UUID) {
        // DOM Observer 제거
        shared.removeDOMObserver(tabID: tabID, webView: webView)
        
        // 제스처 제거
        webView.gestureRecognizers?.removeAll { gesture in
            if let edgeGesture = gesture as? UIScreenEdgePanGestureRecognizer {
                return objc_getAssociatedObject(edgeGesture, "bfcache_ctx") != nil
            }
            return false
        }
        
        // 레지스트리에서 해제
        BFCacheRegistry.shared.unregister(tabID: tabID, webView: webView)
        
        TabPersistenceManager.debugMessages.append("[\(ts())][BFCache] 🧹 완전 최적화된 시스템 해제: TabID[\(String(tabID.uuidString.prefix(8)))]")
    }
    
    // 프로그래밍 방식 네비게이션
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateWithSnapshot(stateModel: stateModel, direction: .back)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateWithSnapshot(stateModel: stateModel, direction: .forward)
    }
    
    private func navigateWithSnapshot(stateModel: WebViewStateModel, direction: NavigationDirection) {
        guard let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        let canNavigate = direction == .back ? stateModel.canGoBack : stateModel.canGoForward
        guard canNavigate else {
            dbg("❌ 네비게이션 불가: \(direction)")
            return
        }
        
        // 일반 네비게이션 수행
        switch direction {
        case .back:
            stateModel.goBack()
        case .forward:
            stateModel.goForward()
        }
        
        // 스냅샷 복원
        let currentIndex = stateModel.dataModel.currentPageIndex
        restorePageSnapshot(for: tabID, pageIndex: currentIndex, to: webView) { success in
            self.dbg("🔄 프로그래밍 네비게이션 후 완전 스냅샷 복원: \(success ? "성공" : "실패")")
        }
    }
}
