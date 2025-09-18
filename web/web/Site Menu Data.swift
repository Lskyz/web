//
//  Site Menu Data.swift
//  🧩 사이트 메뉴 시스템 - 데이터 로직 및 관리자
//  📋 데스크탑 모드, 팝업 차단, 다운로드, 히스토리, 개인정보, 성능 등 모든 기능 통합
//  🖥️ 데스크탑 모드 델리게이트 연결 강화
//  🚫 팝업 차단 동기화 개선
//

import SwiftUI
import Foundation
import WebKit
import AVFoundation

// MARK: - 📋 Data Models
struct HistoryFilter: Identifiable, Codable {
    var id = UUID()
    let type: FilterType
    var value: String
    var isEnabled: Bool
    let createdAt: Date

    enum FilterType: String, Codable, CaseIterable {
        case keyword = "keyword"
        case domain = "domain"

        var displayName: String {
            switch self {
            case .keyword: return "키워드"
            case .domain: return "도메인"
            }
        }

        var icon: String {
            switch self {
            case .keyword: return "textformat"
            case .domain: return "globe"
            }
        }
    }

    init(type: FilterType, value: String) {
        self.type = type
        self.value = value
        self.isEnabled = true
        self.createdAt = Date()
    }
}

struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    let filename: String
    let url: String
    let date: Date
    let size: String
    let fileURL: URL?

    init(filename: String, url: String, size: String = "알 수 없음", fileURL: URL? = nil) {
        self.id = UUID()
        self.filename = filename
        self.url = url
        self.date = Date()
        self.size = size
        self.fileURL = fileURL
    }
}

// MARK: - 🚫 Enhanced PopupBlockManager with Notification System (수정됨 - 동기화 개선)
class PopupBlockManager: ObservableObject {
    static let shared = PopupBlockManager()
    
    @Published var isPopupBlocked: Bool = true {
        didSet {
            UserDefaults.standard.set(isPopupBlocked, forKey: "popupBlocked")
            NotificationCenter.default.post(name: .popupBlockStateChanged, object: nil)
        }
    }
    
    @Published var blockedPopupCount: Int = 0 {
        didSet {
            UserDefaults.standard.set(blockedPopupCount, forKey: "blockedPopupCount")
        }
    }
    
    @Published var lastBlockedDomain: String = ""
    @Published var lastBlockedURL: String = ""
    
    private var allowedDomains: Set<String> = []
    private var blockedPopups: [BlockedPopup] = []
    
    struct BlockedPopup {
        let domain: String
        let url: String
        let date: Date
        let sourceURL: String
    }
    
    private init() {
        self.isPopupBlocked = UserDefaults.standard.object(forKey: "popupBlocked") as? Bool ?? true
        self.blockedPopupCount = UserDefaults.standard.object(forKey: "blockedPopupCount") as? Int ?? 0
        loadAllowedDomains()
        loadBlockedPopups()
    }
    
    // MARK: - 🚫 Core Blocking Logic
    func shouldBlockPopup(from sourceURL: URL?, targetURL: URL?) -> Bool {
        guard isPopupBlocked else { return false }
        
        // 소스 도메인이 허용 목록에 있으면 허용
        if let sourceDomain = sourceURL?.host, allowedDomains.contains(sourceDomain) {
            return false
        }
        
        // 타겟 도메인이 허용 목록에 있으면 허용
        if let targetDomain = targetURL?.host, allowedDomains.contains(targetDomain) {
            return false
        }
        
        return true
    }
    
    func blockPopup(from sourceURL: URL?, targetURL: URL?) {
        guard let sourceDomain = sourceURL?.host else { return }
        
        DispatchQueue.main.async {
            self.blockedPopupCount += 1
            self.lastBlockedDomain = sourceDomain
            self.lastBlockedURL = targetURL?.absoluteString ?? ""
            
            let blockedPopup = BlockedPopup(
                domain: sourceDomain,
                url: targetURL?.absoluteString ?? "",
                date: Date(),
                sourceURL: sourceURL?.absoluteString ?? ""
            )
            self.blockedPopups.append(blockedPopup)
            self.saveBlockedPopups()
            
            // 팝업 차단 알림 전송
            NotificationCenter.default.post(
                name: .popupBlocked,
                object: nil,
                userInfo: [
                    "domain": sourceDomain,
                    "url": targetURL?.absoluteString ?? "",
                    "count": self.blockedPopupCount
                ]
            )
        }
    }
    
    func resetBlockedCount() {
        blockedPopupCount = 0
        blockedPopups.removeAll()
        saveBlockedPopups()
    }
    
    // 🚫 수정: 도메인 허용 시 알림 추가
    func allowPopupsForDomain(_ domain: String) {
        allowedDomains.insert(domain)
        saveAllowedDomains()
        NotificationCenter.default.post(name: .popupBlockStateChanged, object: nil)
        // 🚫 새로운 알림 추가 - 도메인 목록 변경 전용
        NotificationCenter.default.post(name: .popupDomainAllowListChanged, object: nil)
    }
    
    // 🚫 수정: 도메인 제거 시 알림 추가
    func removeAllowedDomain(_ domain: String) {
        allowedDomains.remove(domain)
        saveAllowedDomains()
        NotificationCenter.default.post(name: .popupBlockStateChanged, object: nil)
        // 🚫 새로운 알림 추가 - 도메인 목록 변경 전용
        NotificationCenter.default.post(name: .popupDomainAllowListChanged, object: nil)
    }
    
    func isDomainAllowed(_ domain: String) -> Bool {
        return allowedDomains.contains(domain)
    }
    
    func getAllowedDomains() -> [String] {
        return Array(allowedDomains).sorted()
    }
    
    func getRecentBlockedPopups(limit: Int = 10) -> [BlockedPopup] {
        return Array(blockedPopups.sorted { $0.date > $1.date }.prefix(limit))
    }
    
    // MARK: - 💾 Persistence
    private func loadAllowedDomains() {
        if let domains = UserDefaults.standard.array(forKey: "allowedPopupDomains") as? [String] {
            allowedDomains = Set(domains)
        }
    }
    
    private func saveAllowedDomains() {
        UserDefaults.standard.set(Array(allowedDomains), forKey: "allowedPopupDomains")
    }
    
    private func loadBlockedPopups() {
        if let data = UserDefaults.standard.data(forKey: "blockedPopups"),
           let decoded = try? JSONDecoder().decode([BlockedPopupData].self, from: data) {
            blockedPopups = decoded.map { data in
                BlockedPopup(domain: data.domain, url: data.url, date: data.date, sourceURL: data.sourceURL)
            }
        }
    }
    
    private func saveBlockedPopups() {
        let data = blockedPopups.map { popup in
            BlockedPopupData(domain: popup.domain, url: popup.url, date: popup.date, sourceURL: popup.sourceURL)
        }
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: "blockedPopups")
        }
    }
    
    private struct BlockedPopupData: Codable {
        let domain: String
        let url: String
        let date: Date
        let sourceURL: String
    }
}

// MARK: - 📢 Notification Names (수정됨 - 새로운 알림 추가)
extension Notification.Name {
    static let popupBlocked = Notification.Name("PopupBlocked")
    static let popupBlockStateChanged = Notification.Name("PopupBlockStateChanged")
    static let popupDomainAllowListChanged = Notification.Name("PopupDomainAllowListChanged") // 🚫 새로 추가
}

// MARK: - 🎯 Main System (Complete modules)
enum SiteMenuSystem {
    
    // MARK: - 🖥️ Enhanced Desktop Module with Delegate Connection
    enum Desktop {
        private static let desktopModeKey = "isDesktopModeEnabled"
        private static let zoomLevelKey = "currentZoomLevel"
        
        static func getDesktopModeEnabled(for stateModel: WebViewStateModel) -> Bool {
            return stateModel.isDesktopMode
        }
        
        static func setDesktopModeEnabled(_ enabled: Bool, for stateModel: WebViewStateModel) {
            stateModel.isDesktopMode = enabled
            UserDefaults.standard.set(enabled, forKey: desktopModeKey)
            
            // 🖥️ 델리게이트 연결: 웹뷰에 직접 설정 적용
            if let webView = stateModel.webView {
                applyDesktopModeToWebView(webView, enabled: enabled)
            }
        }
        
        static func toggleDesktopMode(for stateModel: WebViewStateModel) {
            let newMode = !stateModel.isDesktopMode
            setDesktopModeEnabled(newMode, for: stateModel)
        }
        
        static func getZoomLevel(for stateModel: WebViewStateModel) -> Double {
            return stateModel.currentZoomLevel
        }
        
        static func setZoomLevel(_ level: Double, for stateModel: WebViewStateModel) {
            let clampedLevel = max(0.3, min(3.0, level))
            stateModel.setZoomLevel(clampedLevel)
            UserDefaults.standard.set(clampedLevel, forKey: zoomLevelKey)
            
            // 🖥️ 델리게이트 연결: 웹뷰에 직접 줌 적용
            if let webView = stateModel.webView, stateModel.isDesktopMode {
                applyZoomToWebView(webView, level: clampedLevel)
            }
        }
        
        static func getZoomPresets() -> [Double] {
            return [0.3, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
        }
        
        static func resetToDefault(for stateModel: WebViewStateModel) {
            setDesktopModeEnabled(false, for: stateModel)
            setZoomLevel(1.0, for: stateModel)
        }
        
        // 🖥️ 핵심 델리게이트 메서드들: 웹뷰와 직접 연결
        private static func applyDesktopModeToWebView(_ webView: WKWebView, enabled: Bool) {
            // 사용자 에이전트 설정
            if enabled {
                let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
                webView.customUserAgent = desktopUA
            } else {
                webView.customUserAgent = nil
            }
            
            // JavaScript 환경 설정
            let script = """
            if (window.toggleDesktopMode) { 
                window.toggleDesktopMode(\(enabled)); 
            }
            """
            
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🖥️ 데스크탑 모드 적용 실패: \(error.localizedDescription)")
                } else {
                    TabPersistenceManager.debugMessages.append("🖥️ 데스크탑 모드 적용 완료: \(enabled)")
                }
            }
        }
        
        private static func applyZoomToWebView(_ webView: WKWebView, level: Double) {
            let script = """
            if (window.setPageZoom) {
                window.setPageZoom(\(level));
            }
            """
            
            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔍 줌 적용 실패: \(error.localizedDescription)")
                } else {
                    TabPersistenceManager.debugMessages.append("🔍 줌 레벨 적용: \(String(format: "%.1f", level))x")
                }
            }
        }
        
        // 🖥️ 웹뷰 연결 시 상태 동기화 (CustomWebView에서 호출)
        static func syncWebViewState(for stateModel: WebViewStateModel) {
            guard let webView = stateModel.webView else { return }
            
            // 현재 데스크탑 모드 상태 적용
            applyDesktopModeToWebView(webView, enabled: stateModel.isDesktopMode)
            
            // 데스크탑 모드가 켜져있고 줌 레벨이 기본값이 아니면 적용
            if stateModel.isDesktopMode && stateModel.currentZoomLevel != 1.0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    applyZoomToWebView(webView, level: stateModel.currentZoomLevel)
                }
            }
            
            TabPersistenceManager.debugMessages.append("🖥️ 웹뷰 상태 동기화 완료")
        }
    }
    
    // MARK: - ⚙️ Enhanced Settings Module
    enum Settings {
        static func togglePopupBlocking() -> Bool {
            PopupBlockManager.shared.isPopupBlocked.toggle()
            return PopupBlockManager.shared.isPopupBlocked
        }
        
        static func getPopupBlockedState() -> Bool {
            return PopupBlockManager.shared.isPopupBlocked
        }
        
        static func getPopupBlockedCount() -> Int {
            return PopupBlockManager.shared.blockedPopupCount
        }
        
        static func resetPopupBlockedCount() {
            PopupBlockManager.shared.resetBlockedCount()
        }
        
        static func getSiteSecurityInfo(for url: URL?) -> (icon: String, text: String, color: Color) {
            guard let url = url else { 
                return ("globe", "사이트 정보 없음", .secondary) 
            }
            
            if url.scheme == "https" {
                return ("lock.fill", "보안 연결", .green)
            } else if url.scheme == "http" {
                return ("exclamationmark.triangle.fill", "보안되지 않음", .orange)
            } else {
                return ("globe", "알 수 없음", .secondary)
            }
        }
        
        // 🔒 Privacy Settings
        static func clearAllCookies() {
            HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
            WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: Date.distantPast) { }
        }
        
        static func clearCache() {
            URLCache.shared.removeAllCachedResponses()
            WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: Date.distantPast) { }
        }
        
        static func clearWebsiteData() {
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) { }
        }
    }
    
    // MARK: - 📋 History Module (Existing)
    enum History {
        private static let userDefaults = UserDefaults.standard
        private static let filtersKey = "historyFilters"
        private static let enabledKey = "historyFilteringEnabled"
        
        static func getFilters() -> [HistoryFilter] {
            guard let data = userDefaults.data(forKey: filtersKey) else { return [] }
            do {
                return try JSONDecoder().decode([HistoryFilter].self, from: data)
            } catch {
                print("히스토리 필터 로드 실패: \(error)")
                return []
            }
        }
        
        static func saveFilters(_ filters: [HistoryFilter]) {
            do {
                let data = try JSONEncoder().encode(filters)
                userDefaults.set(data, forKey: filtersKey)
            } catch {
                print("히스토리 필터 저장 실패: \(error)")
            }
        }
        
        static func getFilteringEnabled() -> Bool {
            return userDefaults.object(forKey: enabledKey) as? Bool ?? true
        }
        
        static func setFilteringEnabled(_ enabled: Bool) {
            userDefaults.set(enabled, forKey: enabledKey)
        }
        
        static func addFilter(type: HistoryFilter.FilterType, value: String) -> [HistoryFilter] {
            var filters = getFilters()
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            guard !trimmedValue.isEmpty else { return filters }
            guard !filters.contains(where: { $0.type == type && $0.value == trimmedValue }) else { return filters }
            
            let newFilter = HistoryFilter(type: type, value: trimmedValue)
            filters.append(newFilter)
            saveFilters(filters)
            return filters
        }
        
        static func removeFilter(_ filter: HistoryFilter) -> [HistoryFilter] {
            var filters = getFilters()
            filters.removeAll { $0.id == filter.id }
            saveFilters(filters)
            return filters
        }
        
        static func updateFilter(_ filter: HistoryFilter, newValue: String) -> [HistoryFilter] {
            var filters = getFilters()
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            
            guard !trimmedValue.isEmpty else { return filters }
            guard !filters.contains(where: { $0.type == filter.type && $0.value == trimmedValue && $0.id != filter.id }) else { return filters }
            
            if let index = filters.firstIndex(where: { $0.id == filter.id }) {
                filters[index].value = trimmedValue
                saveFilters(filters)
            }
            return filters
        }
        
        static func toggleFilter(_ filter: HistoryFilter) -> [HistoryFilter] {
            var filters = getFilters()
            if let index = filters.firstIndex(where: { $0.id == filter.id }) {
                filters[index].isEnabled.toggle()
                saveFilters(filters)
            }
            return filters
        }
        
        static func clearAllFilters() -> [HistoryFilter] {
            let empty: [HistoryFilter] = []
            saveFilters(empty)
            return empty
        }
        
        private static func shouldFilterEntry(_ entry: HistoryEntry) -> Bool {
            guard getFilteringEnabled() else { return false }
            
            let filters = getFilters().filter { $0.isEnabled }
            guard !filters.isEmpty else { return false }
            
            let urlString = entry.url.absoluteString.lowercased()
            let title = entry.title.lowercased()
            let domain = entry.url.host?.lowercased() ?? ""
            
            for filter in filters {
                switch filter.type {
                case .keyword:
                    if title.contains(filter.value) || urlString.contains(filter.value) {
                        return true
                    }
                case .domain:
                    if domain.contains(filter.value) || domain == filter.value {
                        return true
                    }
                }
            }
            return false
        }
        
        static func getFilteredHistory() -> [HistoryEntry] {
            return WebViewDataModel.globalHistory.filter { !shouldFilterEntry($0) }
        }
        
        static func getRecentVisits(limit: Int = 5) -> [HistoryEntry] {
            return Array(getFilteredHistory()
                .sorted { $0.date > $1.date }
                .prefix(limit))
        }
        
        static func getAutocompleteEntries(for searchText: String, limit: Int = 10) -> [HistoryEntry] {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return [] }
            
            return getFilteredHistory()
                .filter { entry in
                    let urlString = entry.url.absoluteString.lowercased()
                    let title = entry.title.lowercased()
                    let domain = entry.url.host?.lowercased() ?? ""
                    
                    return urlString.contains(trimmed) || 
                           title.contains(trimmed) || 
                           domain.contains(trimmed)
                }
                .sorted { $0.date > $1.date }
                .prefix(limit)
                .map { $0 }
        }
    }
    
    // MARK: - 📁 Downloads Module (Existing) 
    enum Downloads {
        private static let userDefaultsKey = "downloadsList"
        
        static func loadExistingDownloads() -> [DownloadItem] {
            var downloads: [DownloadItem] = []
            
            // 실제 파일 시스템에서 로드
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let downloadsPath = documentsPath.appendingPathComponent("Downloads", isDirectory: true)
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: downloadsPath, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey], options: [])
                
                for fileURL in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    do {
                        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                        let fileSize = resourceValues.fileSize ?? 0
                        let sizeString = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
                        
                        let downloadItem = DownloadItem(
                            filename: fileURL.lastPathComponent,
                            url: "",
                            size: sizeString,
                            fileURL: fileURL
                        )
                        
                        downloads.append(downloadItem)
                    } catch {
                        print("파일 정보 읽기 실패: \(fileURL.lastPathComponent)")
                    }
                }
                
                downloads.sort { $0.date > $1.date }
            } catch {
                print("Downloads 폴더 읽기 실패: \(error.localizedDescription)")
            }
            
            // UserDefaults에서 추가 로드
            loadFromUserDefaults().forEach { savedDownload in
                if !downloads.contains(where: { $0.filename == savedDownload.filename }) {
                    downloads.append(savedDownload)
                }
            }
            
            downloads.sort { $0.date > $1.date }
            return downloads
        }
        
        private static func loadFromUserDefaults() -> [DownloadItem] {
            guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return [] }
            do {
                return try JSONDecoder().decode([DownloadItem].self, from: data)
            } catch {
                print("다운로드 목록 로드 실패: \(error)")
                return []
            }
        }
        
        static func saveDownloads(_ downloads: [DownloadItem]) {
            do {
                let data = try JSONEncoder().encode(downloads)
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            } catch {
                print("다운로드 목록 저장 실패: \(error)")
            }
        }
        
        static func addDownload(filename: String, url: String, size: String = "알 수 없음", fileURL: URL? = nil) -> [DownloadItem] {
            var downloads = loadExistingDownloads()
            let download = DownloadItem(filename: filename, url: url, size: size, fileURL: fileURL)
            downloads.insert(download, at: 0)
            
            if downloads.count > 50 {
                downloads = Array(downloads.prefix(50))
            }
            
            saveDownloads(downloads)
            return downloads
        }
        
        static func removeDownload(_ download: DownloadItem) -> [DownloadItem] {
            var downloads = loadExistingDownloads()
            downloads.removeAll { $0.id == download.id }
            saveDownloads(downloads)
            return downloads
        }
        
        static func deleteFile(_ download: DownloadItem) -> [DownloadItem] {
            let downloads = removeDownload(download)
            if let fileURL = download.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                do { try FileManager.default.removeItem(at: fileURL) } catch { print("파일 삭제 실패: \(error)") }
            }
            return downloads
        }
        
        static func clearAll() -> [DownloadItem] {
            saveDownloads([])
            return []
        }
        
        static func clearAllFiles() -> [DownloadItem] {
            let downloads = loadExistingDownloads()
            
            for download in downloads {
                if let fileURL = download.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                    do {
                        try FileManager.default.removeItem(at: fileURL)
                    } catch {
                        print("파일 삭제 실패: \(error)")
                    }
                }
            }
            
            return clearAll()
        }
    }
    
    // MARK: - ⚡ Performance Module
    enum Performance {
        private static let imageCompressionKey = "enableImageCompression"
        private static let memoryThresholdKey = "memoryCleanupThreshold"
        private static let webViewPoolSizeKey = "webViewPoolSize"
        
        static func getImageCompressionEnabled() -> Bool {
            return UserDefaults.standard.object(forKey: imageCompressionKey) as? Bool ?? false
        }
        
        static func setImageCompressionEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: imageCompressionKey)
        }
        
        static func getMemoryThreshold() -> Double {
            return UserDefaults.standard.object(forKey: memoryThresholdKey) as? Double ?? 0.8
        }
        
        static func setMemoryThreshold(_ threshold: Double) {
            let clamped = max(0.5, min(0.95, threshold))
            UserDefaults.standard.set(clamped, forKey: memoryThresholdKey)
        }
        
        static func getWebViewPoolSize() -> Int {
            return UserDefaults.standard.object(forKey: webViewPoolSizeKey) as? Int ?? 10
        }
        
        static func setWebViewPoolSize(_ size: Int) {
            let clamped = max(5, min(20, size))
            UserDefaults.standard.set(clamped, forKey: webViewPoolSizeKey)
        }
        
        static func clearWebViewPool() {
            WebViewPool.shared.clearPool()
        }
        
        static func getMemoryUsage() -> (used: Double, total: Double) {
            var info = mach_task_basic_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size) / 4

            let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
                infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    task_info(
                        mach_task_self_,
                        task_flavor_t(MACH_TASK_BASIC_INFO),
                        intPtr,
                        &count
                    )
                }
            }

            let totalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1024.0 / 1024.0
            guard kr == KERN_SUCCESS else { return (0, totalMB) }

            let usedMB = Double(info.resident_size) / 1024.0 / 1024.0
            return (usedMB, totalMB)
        }
    }
}

// MARK: - 🎯 Enhanced Unified Manager with Desktop Mode Delegate Connection (수정됨 - 팝업 도메인 동기화 추가)
class SiteMenuManager: ObservableObject {
    // MARK: - UI State
    @Published var showSiteMenu: Bool = false
    @Published var showDownloadsList: Bool = false  
    @Published var showHistoryFilterManager: Bool = false
    @Published var showPrivacySettings: Bool = false
    @Published var showPerformanceSettings: Bool = false
    
    // MARK: - 🚫 Popup Alert State
    @Published var showPopupBlockedAlert: Bool = false
    @Published var popupAlertDomain: String = ""
    @Published var popupAlertCount: Int = 0
    
    // MARK: - Settings State
    @Published var popupBlocked: Bool = SiteMenuSystem.Settings.getPopupBlockedState()
    
    // MARK: - 🖥️ Desktop Mode State with Strong Connection
    private weak var currentStateModel: WebViewStateModel? {
        didSet {
            // 🖥️ 상태 모델 변경 시 데스크탑 상태 동기화
            if let stateModel = currentStateModel {
                SiteMenuSystem.Desktop.syncWebViewState(for: stateModel)
            }
        }
    }
    
    func setCurrentStateModel(_ stateModel: WebViewStateModel) {
        self.currentStateModel = stateModel
        // 🖥️ 즉시 웹뷰 상태 동기화
        SiteMenuSystem.Desktop.syncWebViewState(for: stateModel)
    }
    
    // MARK: - Downloads State
    @Published var downloads: [DownloadItem] = []
    
    // MARK: - History State
    @Published var historyFilters: [HistoryFilter] = []
    @Published var isHistoryFilteringEnabled: Bool = true {
        didSet {
            SiteMenuSystem.History.setFilteringEnabled(isHistoryFilteringEnabled)
        }
    }
    
    // MARK: - Performance State
    @Published var imageCompressionEnabled: Bool = false {
        didSet {
            SiteMenuSystem.Performance.setImageCompressionEnabled(imageCompressionEnabled)
        }
    }
    
    @Published var memoryThreshold: Double = 0.8 {
        didSet {
            SiteMenuSystem.Performance.setMemoryThreshold(memoryThreshold)
        }
    }
    
    @Published var webViewPoolSize: Int = 10 {
        didSet {
            SiteMenuSystem.Performance.setWebViewPoolSize(webViewPoolSize)
        }
    }
    
    // MARK: - Computed Properties
    var recentVisits: [HistoryEntry] {
        SiteMenuSystem.History.getRecentVisits(limit: 5)
    }
    
    init() {
        // 초기 상태 로드
        popupBlocked = SiteMenuSystem.Settings.getPopupBlockedState()
        downloads = SiteMenuSystem.Downloads.loadExistingDownloads()
        historyFilters = SiteMenuSystem.History.getFilters()
        isHistoryFilteringEnabled = SiteMenuSystem.History.getFilteringEnabled()
        imageCompressionEnabled = SiteMenuSystem.Performance.getImageCompressionEnabled()
        memoryThreshold = SiteMenuSystem.Performance.getMemoryThreshold()
        webViewPoolSize = SiteMenuSystem.Performance.getWebViewPoolSize()
        
        // PopupBlockManager 상태 변경 알림 구독
        NotificationCenter.default.addObserver(
            forName: .popupBlockStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.popupBlocked = SiteMenuSystem.Settings.getPopupBlockedState()
        }
        
        // 🚫 팝업 차단 알림 구독
        NotificationCenter.default.addObserver(
            forName: .popupBlocked,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let domain = userInfo["domain"] as? String,
                  let count = userInfo["count"] as? Int else { return }
            
            self?.popupAlertDomain = domain
            self?.popupAlertCount = count
            self?.showPopupBlockedAlert = true
        }
        
        // 🚫 새로 추가: 팝업 도메인 허용 목록 변경 알림 구독
        NotificationCenter.default.addObserver(
            forName: .popupDomainAllowListChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 도메인 목록 변경 시 전체 상태 새로고침
            self?.objectWillChange.send()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UI Actions
    func toggleSiteMenu() {
        showSiteMenu.toggle()
    }
    
    func closeSiteMenu() {
        showSiteMenu = false
    }
    
    func showDownloads() {
        showDownloadsList = true
    }
    
    func showHistoryFilters() {
        showHistoryFilterManager = true
    }
    
    // MARK: - 🖥️ Enhanced Desktop Mode Actions with Strong Delegate Connection
    func getDesktopModeEnabled() -> Bool {
        guard let stateModel = currentStateModel else { return false }
        return SiteMenuSystem.Desktop.getDesktopModeEnabled(for: stateModel)
    }
    
    func toggleDesktopMode() {
        guard let stateModel = currentStateModel else { return }
        SiteMenuSystem.Desktop.toggleDesktopMode(for: stateModel)
        objectWillChange.send()
        TabPersistenceManager.debugMessages.append("🖥️ 데스크탑 모드 토글: \(getDesktopModeEnabled())")
    }
    
    func getZoomLevel() -> Double {
        guard let stateModel = currentStateModel else { return 1.0 }
        return SiteMenuSystem.Desktop.getZoomLevel(for: stateModel)
    }
    
    func setZoomLevel(_ level: Double) {
        guard let stateModel = currentStateModel else { return }
        SiteMenuSystem.Desktop.setZoomLevel(level, for: stateModel)
        objectWillChange.send()
        TabPersistenceManager.debugMessages.append("🔍 줌 레벨 설정: \(String(format: "%.1f", level))x")
    }
    
    func adjustZoom(_ delta: Double) {
        let currentLevel = getZoomLevel()
        let newLevel = max(0.3, min(3.0, currentLevel + delta))
        setZoomLevel(newLevel)
    }
    
    // MARK: - Settings Actions
    func togglePopupBlocking() {
        _ = SiteMenuSystem.Settings.togglePopupBlocking() // 스토어만 토글
        popupBlocked = SiteMenuSystem.Settings.getPopupBlockedState() // 상태 싱크
        if !popupBlocked { SiteMenuSystem.Settings.resetPopupBlockedCount() }
    }
    
    // MARK: - Downloads Actions
    func addDownload(filename: String, url: String, size: String = "알 수 없음", fileURL: URL? = nil) {
        downloads = SiteMenuSystem.Downloads.addDownload(filename: filename, url: url, size: size, fileURL: fileURL)
    }
    
    func removeDownload(_ download: DownloadItem) {
        downloads = SiteMenuSystem.Downloads.removeDownload(download)
    }
    
    func deleteDownloadFile(_ download: DownloadItem) {
        downloads = SiteMenuSystem.Downloads.deleteFile(download)
    }
    
    func clearDownloads() {
        downloads = SiteMenuSystem.Downloads.clearAll()
    }
    
    func clearAllDownloadFiles() {
        downloads = SiteMenuSystem.Downloads.clearAllFiles()
    }
    
    func refreshDownloads() {
        downloads = SiteMenuSystem.Downloads.loadExistingDownloads()
    }
    
    // MARK: - History Actions
    func getAutocompleteEntries(for searchText: String) -> [HistoryEntry] {
        return SiteMenuSystem.History.getAutocompleteEntries(for: searchText, limit: 10)
    }
    
    func addHistoryFilter(type: HistoryFilter.FilterType, value: String) {
        historyFilters = SiteMenuSystem.History.addFilter(type: type, value: value)
    }
    
    func removeHistoryFilter(_ filter: HistoryFilter) {
        historyFilters = SiteMenuSystem.History.removeFilter(filter)
    }
    
    func updateHistoryFilter(_ filter: HistoryFilter, newValue: String) {
        historyFilters = SiteMenuSystem.History.updateFilter(filter, newValue: newValue)
    }
    
    func toggleHistoryFilter(_ filter: HistoryFilter) {
        historyFilters = SiteMenuSystem.History.toggleFilter(filter)
    }
    
    func clearAllHistoryFilters() {
        historyFilters = SiteMenuSystem.History.clearAllFilters()
    }
    
    // MARK: - Performance Actions
    func clearWebViewPool() {
        SiteMenuSystem.Performance.clearWebViewPool()
    }
}
