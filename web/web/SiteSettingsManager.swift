//
//  SiteMenuSystem.swift
//  🧩 완전 통합 사이트 메뉴 시스템 - 모든 설정 기능 포함
//  📋 데스크탑 모드, 팝업 차단, 다운로드, 히스토리, 개인정보, 성능 등 모든 기능 통합
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

// MARK: - 🚫 Enhanced PopupBlockManager with Notification System
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
    
    func allowPopupsForDomain(_ domain: String) {
        allowedDomains.insert(domain)
        saveAllowedDomains()
        NotificationCenter.default.post(name: .popupBlockStateChanged, object: nil)
    }
    
    func removeAllowedDomain(_ domain: String) {
        allowedDomains.remove(domain)
        saveAllowedDomains()
        NotificationCenter.default.post(name: .popupBlockStateChanged, object: nil)
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

// MARK: - 📢 Notification Names
extension Notification.Name {
    static let popupBlocked = Notification.Name("PopupBlocked")
    static let popupBlockStateChanged = Notification.Name("PopupBlockStateChanged")
}

// MARK: - 🎯 Main System (Complete modules)
enum SiteMenuSystem {
    
    // MARK: - 🖥️ Desktop Module  
    enum Desktop {
        private static let desktopModeKey = "isDesktopModeEnabled"
        private static let zoomLevelKey = "currentZoomLevel"
        
        static func getDesktopModeEnabled(for stateModel: WebViewStateModel) -> Bool {
            return stateModel.isDesktopMode
        }
        
        static func setDesktopModeEnabled(_ enabled: Bool, for stateModel: WebViewStateModel) {
            stateModel.isDesktopMode = enabled
            UserDefaults.standard.set(enabled, forKey: desktopModeKey)
        }
        
        static func toggleDesktopMode(for stateModel: WebViewStateModel) {
            stateModel.toggleDesktopMode()
            UserDefaults.standard.set(stateModel.isDesktopMode, forKey: desktopModeKey)
        }
        
        static func getZoomLevel(for stateModel: WebViewStateModel) -> Double {
            return stateModel.currentZoomLevel
        }
        
        static func setZoomLevel(_ level: Double, for stateModel: WebViewStateModel) {
            let clampedLevel = max(0.3, min(3.0, level))
            stateModel.setZoomLevel(clampedLevel)
            UserDefaults.standard.set(clampedLevel, forKey: zoomLevelKey)
        }
        
        static func getZoomPresets() -> [Double] {
            return [0.3, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
        }
        
        static func resetToDefault(for stateModel: WebViewStateModel) {
            setDesktopModeEnabled(false, for: stateModel)
            setZoomLevel(1.0, for: stateModel)
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
    
    // MARK: - 🎨 UI Components Module (Complete with Enhanced Popup Blocking)
    enum UI {
        
        // MARK: - 🚫 Popup Block Alert View
        struct PopupBlockedAlert: View {
            let domain: String
            let blockedCount: Int
            @Binding var isPresented: Bool
            
            var body: some View {
                VStack(spacing: 16) {
                    // 아이콘
                    Image(systemName: "shield.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.red)
                    
                    // 제목
                    Text("팝업 차단됨")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    // 메시지
                    VStack(spacing: 8) {
                        Text("\(domain)에서 팝업을 차단했습니다")
                            .font(.body)
                            .multilineTextAlignment(.center)
                        
                        if blockedCount > 1 {
                            Text("총 \(blockedCount)개의 팝업이 차단되었습니다")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // 버튼들
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Button("이 사이트 허용") {
                                PopupBlockManager.shared.allowPopupsForDomain(domain)
                                isPresented = false
                            }
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            
                            Button("닫기") {
                                isPresented = false
                            }
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                        }
                        
                        Button("팝업 차단 끄기") {
                            PopupBlockManager.shared.isPopupBlocked = false
                            isPresented = false
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(24)
                .background(Color(.systemBackground))
                .cornerRadius(16)
                .shadow(radius: 20)
                .frame(maxWidth: 300)
            }
        }
        
        // MARK: - Main Site Menu Overlay - 🎯 주소창 위로 위치 조정
        struct SiteMenuOverlay: View {
            @ObservedObject var manager: SiteMenuManager
            let currentState: WebViewStateModel
            let outerHorizontalPadding: CGFloat
            let showAddressBar: Bool
            let whiteGlassBackground: AnyView
            let whiteGlassOverlay: AnyView
            @Binding var tabs: [WebTab]
            @Binding var selectedTabIndex: Int

            var body: some View {
                ZStack {
                    Color.black.opacity(0.1)
                        .ignoresSafeArea()
                        .onTapGesture {
                            manager.showSiteMenu = false
                        }

                    // 🎯 주소창 바로 위로 위치 변경
                    VStack(spacing: 0) {
                        Spacer()
                        
                        // 사이트 메뉴를 주소창 위에 표시
                        VStack(spacing: 0) {
                            siteMenuContent
                        }
                        .background(whiteGlassBackground)
                        .overlay(whiteGlassOverlay)
                        .padding(.horizontal, outerHorizontalPadding)
                        .padding(.bottom, 10) // 주소창과의 간격
                        
                        // 하단 UI를 위한 고정된 공간 확보 (키보드 높이 무시)
                        Spacer()
                            .frame(height: showAddressBar ? 160 : 110)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: manager.showSiteMenu)
            }

            @ViewBuilder
            private var siteMenuContent: some View {
                VStack(spacing: 0) {
                    siteInfoSection
                    Divider().padding(.vertical, 8)
                    quickSettingsSection
                    Divider().padding(.vertical, 8)
                    menuOptionsSection
                    Divider().padding(.vertical, 8)
                    downloadsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            @ViewBuilder
            private var siteInfoSection: some View {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            let securityInfo = SiteMenuSystem.Settings.getSiteSecurityInfo(for: currentState.currentURL)
                            
                            Image(systemName: securityInfo.icon)
                                .foregroundColor(securityInfo.color)

                            Text(securityInfo.text)
                                .font(.headline)
                                .foregroundColor(securityInfo.color)

                            if SiteMenuSystem.Settings.getPopupBlockedCount() > 0 {
                                Text("(\(SiteMenuSystem.Settings.getPopupBlockedCount())개 차단됨)")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }

                        if let url = currentState.currentURL {
                            Text(url.host ?? url.absoluteString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
            }
            
            @ViewBuilder
            private var quickSettingsSection: some View {
                VStack(spacing: 8) {
                    HStack {
                        quickSettingButton(
                            icon: "shield.fill",
                            title: "팝업 차단",
                            isOn: manager.popupBlocked,
                            color: manager.popupBlocked ? .blue : .gray
                        ) {
                            manager.togglePopupBlocking()
                        }
                        
                        quickSettingButton(
                            icon: manager.getDesktopModeEnabled() ? "display" : "iphone",
                            title: "데스크탑 모드",
                            isOn: manager.getDesktopModeEnabled(),
                            color: manager.getDesktopModeEnabled() ? .blue : .gray
                        ) {
                            manager.toggleDesktopMode()
                        }
                    }
                    
                    // 🎯 **데스크탑 모드가 활성화되었을 때만 줌 컨트롤 표시**
                    if manager.getDesktopModeEnabled() {
                        desktopZoomControls
                            .transition(.opacity.combined(with: .slide))
                            .animation(.easeInOut(duration: 0.3), value: manager.getDesktopModeEnabled())
                    }
                }
            }
            
            @ViewBuilder
            private func quickSettingButton(icon: String, title: String, isOn: Bool, color: Color, action: @escaping () -> Void) -> some View {
                Button(action: action) {
                    VStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(color)
                        
                        Text(title)
                            .font(.caption)
                            .foregroundColor(isOn ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(isOn ? color.opacity(0.1) : Color.clear)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isOn ? color.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            
            @ViewBuilder
            private var desktopZoomControls: some View {
                VStack(spacing: 12) {
                    HStack {
                        Text("페이지 줌")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text("\(String(format: "%.0f", manager.getZoomLevel() * 100))%")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                    
                    // 🎯 **슬라이더 추가**
                    VStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { manager.getZoomLevel() },
                                set: { newValue in
                                    manager.setZoomLevel(newValue)
                                }
                            ),
                            in: 0.3...3.0,
                            step: 0.1
                        ) {
                            Text("줌 레벨")
                        }
                        .accentColor(.blue)
                        
                        // 슬라이더 하단 레이블
                        HStack {
                            Text("30%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("300%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Button("-") {
                            manager.adjustZoom(-0.1)
                        }
                        .font(.title3)
                        .fontWeight(.medium)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(SiteMenuSystem.Desktop.getZoomPresets(), id: \.self) { preset in
                                    let isSelected = abs(manager.getZoomLevel() - preset) < 0.05
                                    Button("\(String(format: "%.0f", preset * 100))%") {
                                        manager.setZoomLevel(preset)
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.blue : Color.gray.opacity(0.15))
                                    .foregroundColor(isSelected ? .white : .primary)
                                    .cornerRadius(6)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .frame(height: 32)
                        
                        Button("+") {
                            manager.adjustZoom(0.1)
                        }
                        .font(.title3)
                        .fontWeight(.medium)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, 4)
            }

            @ViewBuilder
            private var menuOptionsSection: some View {
                VStack(spacing: 12) {
                    HStack {
                        menuOptionRow(
                            icon: "line.3.horizontal.decrease.circle",
                            title: "방문 기록 관리",
                            subtitle: "\(manager.historyFilters.count)개 필터",
                            color: .orange
                        ) {
                            manager.showHistoryFilterManager = true
                        }
                        
                        Spacer()
                        
                        menuOptionRow(
                            icon: "shield.lefthalf.filled",
                            title: "개인정보",
                            subtitle: "쿠키 & 캐시",
                            color: .purple
                        ) {
                            manager.showPrivacySettings = true
                        }
                    }
                    
                    HStack {
                        // 🎯 **데스크탑 모드를 성능과 위치 바꾸고 길게 만들기**
                        menuOptionRowWide(
                            icon: manager.getDesktopModeEnabled() ? "display" : "iphone",
                            title: "데스크탑 모드",
                            subtitle: manager.getDesktopModeEnabled() ? "활성화됨" : "비활성화됨",
                            color: manager.getDesktopModeEnabled() ? .blue : .gray
                        ) {
                            manager.toggleDesktopMode()
                        }
                        
                        Spacer()
                        
                        menuOptionRow(
                            icon: "speedometer",
                            title: "성능",
                            subtitle: "메모리 & 캐시",
                            color: .red
                        ) {
                            manager.showPerformanceSettings = true
                        }
                    }
                }
            }
            
            @ViewBuilder
            private func menuOptionRow(icon: String, title: String, subtitle: String, color: Color, action: @escaping () -> Void) -> some View {
                Button(action: action) {
                    VStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(color)
                        
                        Text(title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            
            // 🎯 **넓은 메뉴 옵션 행 (데스크탑 모드용)**
            @ViewBuilder
            private func menuOptionRowWide(icon: String, title: String, subtitle: String, color: Color, action: @escaping () -> Void) -> some View {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(color)
                            .frame(width: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.headline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(manager.getDesktopModeEnabled() ? color.opacity(0.1) : Color.gray.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(manager.getDesktopModeEnabled() ? color.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            @ViewBuilder
            private var downloadsSection: some View {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(action: {
                            manager.showDownloadsList = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.blue)
                                    .frame(width: 20)

                                Text("다운로드")
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        if !manager.downloads.isEmpty {
                            Text("\(manager.downloads.count)개")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(12)
                        }
                    }

                    if !manager.downloads.isEmpty {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(Array(manager.downloads.prefix(3))) { download in
                                    downloadRow(download)
                                }

                                if manager.downloads.count > 3 {
                                    HStack {
                                        Spacer()
                                        Text("및 \(manager.downloads.count - 3)개 더...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .frame(maxHeight: 100)
                    } else {
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Image(systemName: "tray")
                                    .font(.title3)
                                    .foregroundColor(.secondary.opacity(0.6))

                                Text("다운로드된 파일이 없습니다")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 16)
                    }
                }
            }

            @ViewBuilder
            private func downloadRow(_ download: DownloadItem) -> some View {
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.blue)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(download.filename)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)

                        HStack {
                            Text(download.size)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            Text(RelativeDateTimeFormatter().localizedString(for: download.date, relativeTo: Date()))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.white.opacity(0.95))
                .cornerRadius(8)
            }
        }
        
        // MARK: - Recent Visits View
        struct RecentVisitsView: View {
            @ObservedObject var manager: SiteMenuManager
            let onURLSelected: (URL) -> Void
            let onManageHistory: () -> Void

            var body: some View {
                VStack(spacing: 0) {
                    if manager.recentVisits.isEmpty {
                        emptyStateView
                    } else {
                        historyListView
                    }
                }
            }

            @ViewBuilder
            private var emptyStateView: some View {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    Text("최근 방문한 사이트가 없습니다")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)
            }

            @ViewBuilder
            private var historyListView: some View {
                VStack(spacing: 0) {
                    ForEach(manager.recentVisits) { entry in
                        historyRow(entry)

                        if entry.id != manager.recentVisits.last?.id {
                            Divider()
                                .padding(.horizontal, 14)
                        }
                    }
                }
            }

            @ViewBuilder
            private func historyRow(_ entry: HistoryEntry) -> some View {
                Button(action: {
                    onURLSelected(entry.url)
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "clock")
                            .foregroundColor(.blue)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Text(entry.url.absoluteString)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: Date()))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        
        // MARK: - Autocomplete View
        struct AutocompleteView: View {
            @ObservedObject var manager: SiteMenuManager
            let searchText: String
            let onURLSelected: (URL) -> Void
            let onManageHistory: () -> Void

            var body: some View {
                VStack(spacing: 0) {
                    if manager.getAutocompleteEntries(for: searchText).isEmpty {
                        emptyStateView
                    } else {
                        autocompleteListView
                    }
                }
            }

            @ViewBuilder
            private var emptyStateView: some View {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    Text("'\(searchText)'에 대한 방문 기록이 없습니다")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 20)
            }

            @ViewBuilder
            private var autocompleteListView: some View {
                VStack(spacing: 0) {
                    ForEach(manager.getAutocompleteEntries(for: searchText)) { entry in
                        autocompleteRow(entry)

                        if entry.id != manager.getAutocompleteEntries(for: searchText).last?.id {
                            Divider()
                                .padding(.horizontal, 14)
                        }
                    }
                }
            }

            @ViewBuilder
            private func autocompleteRow(_ entry: HistoryEntry) -> some View {
                Button(action: {
                    onURLSelected(entry.url)
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            highlightedText(entry.title, searchText: searchText)
                                .font(.system(size: 16, weight: .medium))
                                .lineLimit(1)

                            highlightedText(entry.url.absoluteString, searchText: searchText)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            @ViewBuilder
            private func highlightedText(_ text: String, searchText: String) -> some View {
                let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.isEmpty {
                    Text(text)
                        .foregroundColor(.primary)
                } else {
                    let parts = text.components(separatedBy: trimmed)

                    if parts.count > 1 {
                        HStack(spacing: 0) {
                            ForEach(0..<parts.count, id: \.self) { index in
                                Text(parts[index])
                                    .foregroundColor(.primary)

                                if index < parts.count - 1 {
                                    Text(trimmed)
                                        .foregroundColor(.blue)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    } else {
                        Text(text)
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        
        // MARK: - Downloads List View
        struct DownloadsListView: View {
            @ObservedObject var manager: SiteMenuManager
            @State private var searchText = ""
            @State private var showClearAllAlert = false
            @Environment(\.dismiss) private var dismiss

            private var filteredDownloads: [DownloadItem] {
                if searchText.isEmpty {
                    return manager.downloads
                } else {
                    return manager.downloads.filter {
                        $0.filename.localizedCaseInsensitiveContains(searchText)
                    }
                }
            }

            var body: some View {
                List {
                    if filteredDownloads.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)

                            Text(searchText.isEmpty ? "다운로드된 파일이 없습니다" : "검색 결과가 없습니다")
                                .font(.title3)
                                .foregroundColor(.secondary)

                            if searchText.isEmpty {
                                Text("웹에서 파일을 다운로드하면 여기에 표시됩니다\n(앱 내부 Documents/Downloads 폴더)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredDownloads) { download in
                            DownloadListRow(download: download, manager: manager)
                        }
                        .onDelete(perform: deleteDownloads)
                    }
                }
                .navigationTitle("다운로드")
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            if !manager.downloads.isEmpty {
                                Button(role: .destructive) {
                                    showClearAllAlert = true
                                } label: {
                                    Label("모든 파일 실제 삭제", systemImage: "trash.fill")
                                }

                                Button {
                                    manager.clearDownloads()
                                } label: {
                                    Label("목록만 지우기", systemImage: "list.dash")
                                }
                            }

                            Button {
                                openDownloadsFolder()
                            } label: {
                                Label("파일 앱에서 열기", systemImage: "folder")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .alert("모든 다운로드 파일 삭제", isPresented: $showClearAllAlert) {
                    Button("취소", role: .cancel) { }
                    Button("실제 파일 삭제", role: .destructive) {
                        manager.clearAllDownloadFiles()
                    }
                } message: {
                    Text("다운로드 폴더의 모든 파일을 실제로 삭제하시겠습니까?\n이 작업은 되돌릴 수 없습니다.")
                }
            }

            private func deleteDownloads(at offsets: IndexSet) {
                for index in offsets {
                    let download = filteredDownloads[index]
                    manager.deleteDownloadFile(download)
                }
            }

            private func openDownloadsFolder() {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let downloadsPath = documentsPath.appendingPathComponent("Downloads", isDirectory: true)

                if let topVC = getTopViewController() {
                    let activityVC = UIActivityViewController(activityItems: [downloadsPath], applicationActivities: nil)
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    topVC.present(activityVC, animated: true)
                }
            }
        }
        
        // MARK: - Download List Row
        struct DownloadListRow: View {
            let download: DownloadItem
            @ObservedObject var manager: SiteMenuManager

            private var fileExtension: String {
                URL(fileURLWithPath: download.filename).pathExtension.lowercased()
            }

            private var fileIcon: String {
                switch fileExtension {
                case "pdf": return "doc.richtext"
                case "jpg", "jpeg", "png", "gif", "webp": return "photo"
                case "mp4", "mov", "avi", "mkv": return "video"
                case "mp3", "wav", "aac", "flac": return "music.note"
                case "zip", "rar", "7z": return "archivebox"
                case "txt", "md": return "doc.text"
                case "html", "htm": return "globe"
                default: return "doc"
                }
            }

            private var fileIconColor: Color {
                switch fileExtension {
                case "pdf": return .red
                case "jpg", "jpeg", "png", "gif", "webp": return .green
                case "mp4", "mov", "avi", "mkv": return .purple
                case "mp3", "wav", "aac", "flac": return .orange
                case "zip", "rar", "7z": return .yellow
                case "txt", "md": return .blue
                case "html", "htm": return .cyan
                default: return .gray
                }
            }

            var body: some View {
                HStack(spacing: 12) {
                    Image(systemName: fileIcon)
                        .font(.title2)
                        .foregroundColor(fileIconColor)
                        .frame(width: 40, height: 40)
                        .background(fileIconColor.opacity(0.1))
                        .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(download.filename)
                            .font(.headline)
                            .lineLimit(2)

                        HStack {
                            Text(download.size)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            Text(RelativeDateTimeFormatter().localizedString(for: download.date, relativeTo: Date()))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let fileURL = download.fileURL {
                                if FileManager.default.fileExists(atPath: fileURL.path) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }

                    Spacer()

                    Menu {
                        if let fileURL = download.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                            Button {
                                openFile(fileURL)
                            } label: {
                                Label("열기", systemImage: "doc.text")
                            }

                            Button {
                                shareFile(fileURL)
                            } label: {
                                Label("공유", systemImage: "square.and.arrow.up")
                            }

                            Divider()

                            Button(role: .destructive) {
                                manager.deleteDownloadFile(download)
                            } label: {
                                Label("실제 파일 삭제", systemImage: "trash.fill")
                            }
                        } else {
                            Text("파일이 존재하지 않음")
                                .foregroundColor(.secondary)
                        }

                        Button(role: .destructive) {
                            manager.removeDownload(download)
                        } label: {
                            Label("목록에서만 제거", systemImage: "list.dash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if let fileURL = download.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                        openFile(fileURL)
                    }
                }
            }

            private func openFile(_ fileURL: URL) {
                if let topVC = getTopViewController() {
                    let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    topVC.present(activityVC, animated: true)
                }
            }

            private func shareFile(_ fileURL: URL) {
                if let topVC = getTopViewController() {
                    let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    topVC.present(activityVC, animated: true)
                }
            }
        }
        
        // MARK: - History Filter Manager View  
        struct HistoryFilterManagerView: View {
            @ObservedObject var manager: SiteMenuManager
            @Environment(\.dismiss) private var dismiss

            @State private var showAddFilterSheet = false
            @State private var newFilterType: HistoryFilter.FilterType = .keyword
            @State private var newFilterValue = ""
            @State private var showClearAllAlert = false
            @State private var editingFilter: HistoryFilter?
            @State private var editingValue = ""

            private var keywordFilters: [HistoryFilter] {
                manager.historyFilters.filter { $0.type == .keyword }
            }

            private var domainFilters: [HistoryFilter] {
                manager.historyFilters.filter { $0.type == .domain }
            }

            var body: some View {
                List {
                    Section {
                        Toggle("방문 기록 필터링", isOn: $manager.isHistoryFilteringEnabled)
                            .font(.headline)
                    } header: {
                        Text("필터 설정")
                    } footer: {
                        Text("필터링을 켜면 설정한 키워드나 도메인이 포함된 방문 기록이 주소창 자동완성에서 숨겨집니다.")
                    }

                    if manager.isHistoryFilteringEnabled && !manager.historyFilters.isEmpty {
                        Section("현재 필터 상태") {
                            let enabledCount = manager.historyFilters.filter { $0.isEnabled }.count
                            let totalCount = manager.historyFilters.count

                            HStack {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .foregroundColor(.blue)

                                Text("활성 필터: \(enabledCount) / \(totalCount)개")
                                    .font(.subheadline)

                                Spacer()

                                if enabledCount > 0 {
                                    Text("적용 중")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundColor(.blue)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }

                    if !keywordFilters.isEmpty {
                        Section("키워드 필터") {
                            ForEach(keywordFilters) { filter in
                                filterRow(filter)
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    manager.removeHistoryFilter(keywordFilters[index])
                                }
                            }
                        }
                    }

                    if !domainFilters.isEmpty {
                        Section("도메인 필터") {
                            ForEach(domainFilters) { filter in
                                filterRow(filter)
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    manager.removeHistoryFilter(domainFilters[index])
                                }
                            }
                        }
                    }

                    if manager.historyFilters.isEmpty {
                        Section {
                            VStack(spacing: 16) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)

                                VStack(spacing: 8) {
                                    Text("설정된 필터가 없습니다")
                                        .font(.headline)
                                        .foregroundColor(.secondary)

                                    Text("키워드나 도메인 필터를 추가하여\n원하지 않는 방문 기록을 숨길 수 있습니다")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .navigationTitle("방문 기록 관리")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                showAddFilterSheet = true
                            } label: {
                                Label("필터 추가", systemImage: "plus")
                            }

                            if !manager.historyFilters.isEmpty {
                                Divider()

                                Button(role: .destructive) {
                                    showClearAllAlert = true
                                } label: {
                                    Label("모든 필터 삭제", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showAddFilterSheet) {
                    addFilterSheet
                }
                .alert("필터 수정", isPresented: Binding(
                    get: { editingFilter != nil },
                    set: { if !$0 { editingFilter = nil } }
                )) {
                    TextField("필터 값", text: $editingValue)
                    Button("취소", role: .cancel) {
                        editingFilter = nil
                        editingValue = ""
                    }
                    Button("저장") {
                        if let filter = editingFilter {
                            manager.updateHistoryFilter(filter, newValue: editingValue)
                        }
                        editingFilter = nil
                        editingValue = ""
                    }
                } message: {
                    if let filter = editingFilter {
                        Text("\(filter.type.displayName) 필터를 수정하세요")
                    }
                }
                .alert("모든 필터 삭제", isPresented: $showClearAllAlert) {
                    Button("취소", role: .cancel) { }
                    Button("삭제", role: .destructive) {
                        manager.clearAllHistoryFilters()
                    }
                } message: {
                    Text("모든 히스토리 필터를 삭제하시겠습니까?")
                }
            }

            @ViewBuilder
            private func filterRow(_ filter: HistoryFilter) -> some View {
                HStack {
                    Image(systemName: filter.type.icon)
                        .foregroundColor(filter.isEnabled ? .blue : .gray)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(filter.value)
                            .font(.headline)
                            .foregroundColor(filter.isEnabled ? .primary : .secondary)

                        HStack {
                            Text(filter.type.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if filter.isEnabled {
                                Text("• 활성")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            } else {
                                Text("• 비활성")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }

                            Spacer()

                            Text(RelativeDateTimeFormatter().localizedString(for: filter.createdAt, relativeTo: Date()))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Menu {
                        Button {
                            editingFilter = filter
                            editingValue = filter.value
                        } label: {
                            Label("수정", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            manager.removeHistoryFilter(filter)
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        manager.toggleHistoryFilter(filter)
                    }
                }
            }

            @ViewBuilder
            private var addFilterSheet: some View {
                NavigationView {
                    Form {
                        Section("필터 종류") {
                            Picker("필터 종류", selection: $newFilterType) {
                                ForEach(HistoryFilter.FilterType.allCases, id: \.self) { type in
                                    HStack {
                                        Image(systemName: type.icon)
                                        Text(type.displayName)
                                    }
                                    .tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Section {
                            TextField(placeholderText, text: $newFilterValue)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        } header: {
                            Text("\(newFilterType.displayName) 입력")
                        } footer: {
                            Text(footerText)
                        }

                        if !newFilterValue.isEmpty {
                            Section("미리보기") {
                                HStack {
                                    Image(systemName: newFilterType.icon)
                                        .foregroundColor(.blue)

                                    Text(newFilterValue.lowercased())
                                        .font(.headline)

                                    Spacer()

                                    Text("필터됨")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.red.opacity(0.1))
                                        .foregroundColor(.red)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    .navigationTitle("필터 추가")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("취소") {
                                showAddFilterSheet = false
                                resetAddFilterForm()
                            }
                        }

                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("추가") {
                                manager.addHistoryFilter(type: newFilterType, value: newFilterValue)
                                showAddFilterSheet = false
                                resetAddFilterForm()
                            }
                            .disabled(newFilterValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }

            private var placeholderText: String {
                switch newFilterType {
                case .keyword:
                    return "예: 광고, 스팸, 성인"
                case .domain:
                    return "예: example.com, ads.google.com"
                }
            }

            private var footerText: String {
                switch newFilterType {
                case .keyword:
                    return "페이지 제목이나 URL에 이 키워드가 포함된 방문 기록이 숨겨집니다."
                case .domain:
                    return "이 도메인의 방문 기록이 숨겨집니다. 정확한 도메인명을 입력하세요."
                }
            }

            private func resetAddFilterForm() {
                newFilterType = .keyword
                newFilterValue = ""
            }
        }
        
        // MARK: - Privacy Settings View
        struct PrivacySettingsView: View {
            @ObservedObject var manager: SiteMenuManager
            @Environment(\.dismiss) private var dismiss
            
            @State private var showClearCookiesAlert = false
            @State private var showClearCacheAlert = false
            @State private var showClearAllDataAlert = false
            
            var body: some View {
                List {
                    Section("쿠키 및 사이트 데이터") {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("모든 쿠키 삭제")
                                    .font(.headline)
                                Text("로그인 상태가 해제됩니다")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("삭제") {
                                showClearCookiesAlert = true
                            }
                            .foregroundColor(.red)
                        }
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("캐시 삭제")
                                    .font(.headline)
                                Text("이미지 및 파일 캐시를 삭제합니다")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("삭제") {
                                showClearCacheAlert = true
                            }
                            .foregroundColor(.red)
                        }
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("모든 웹사이트 데이터 삭제")
                                    .font(.headline)
                                Text("쿠키, 캐시, 로컬 저장소 등 모든 데이터")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("모두 삭제") {
                                showClearAllDataAlert = true
                            }
                            .foregroundColor(.red)
                            .fontWeight(.semibold)
                        }
                    }
                    
                    Section("팝업 차단") {
                        HStack {
                            Text("차단된 팝업 수")
                                .font(.headline)
                            
                            Spacer()
                            
                            Text("\(SiteMenuSystem.Settings.getPopupBlockedCount())개")
                                .foregroundColor(.secondary)
                            
                            Button("초기화") {
                                SiteMenuSystem.Settings.resetPopupBlockedCount()
                            }
                            .font(.caption)
                        }
                        
                        HStack {
                            Text("허용된 사이트")
                                .font(.headline)
                            
                            Spacer()
                            
                            let allowedCount = PopupBlockManager.shared.getAllowedDomains().count
                            Text("\(allowedCount)개")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle("개인정보 보호")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") {
                            dismiss()
                        }
                    }
                }
                .alert("쿠키 삭제", isPresented: $showClearCookiesAlert) {
                    Button("취소", role: .cancel) { }
                    Button("삭제", role: .destructive) {
                        SiteMenuSystem.Settings.clearAllCookies()
                    }
                } message: {
                    Text("모든 웹사이트의 쿠키를 삭제하시겠습니까? 모든 사이트에서 로그아웃됩니다.")
                }
                .alert("캐시 삭제", isPresented: $showClearCacheAlert) {
                    Button("취소", role: .cancel) { }
                    Button("삭제", role: .destructive) {
                        SiteMenuSystem.Settings.clearCache()
                    }
                } message: {
                    Text("모든 캐시를 삭제하시겠습니까? 페이지 로딩이 일시적으로 느려질 수 있습니다.")
                }
                .alert("모든 웹사이트 데이터 삭제", isPresented: $showClearAllDataAlert) {
                    Button("취소", role: .cancel) { }
                    Button("모두 삭제", role: .destructive) {
                        SiteMenuSystem.Settings.clearWebsiteData()
                    }
                } message: {
                    Text("쿠키, 캐시, 로컬 저장소 등 모든 웹사이트 데이터를 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.")
                }
            }
        }
        
        // MARK: - Performance Settings View
        struct PerformanceSettingsView: View {
            @ObservedObject var manager: SiteMenuManager
            @Environment(\.dismiss) private var dismiss
            
            var body: some View {
                List {
                    Section("메모리 관리") {
                        let memoryUsage = SiteMenuSystem.Performance.getMemoryUsage()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("메모리 사용량")
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text("\(String(format: "%.0f", memoryUsage.used)) MB")
                                    .foregroundColor(.secondary)
                            }
                            
                            ProgressView(value: memoryUsage.used / memoryUsage.total)
                                .progressViewStyle(LinearProgressViewStyle(tint: memoryUsage.used / memoryUsage.total > 0.8 ? .red : .blue))
                                .scaleEffect(x: 1, y: 0.5)
                        }
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Text("웹뷰 풀 정리")
                                    .font(.headline)
                                Text("사용하지 않는 웹뷰를 정리합니다")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("정리") {
                                manager.clearWebViewPool()
                            }
                            .foregroundColor(.blue)
                        }
                    }
                    
                    Section("캐시 설정") {
                        Toggle("이미지 압축", isOn: $manager.imageCompressionEnabled)
                            .font(.headline)
                        
                        if manager.imageCompressionEnabled {
                            Text("이미지를 자동으로 압축하여 메모리 사용량을 줄입니다")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Section("고급 설정") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("메모리 정리 임계값")
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text("\(Int(manager.memoryThreshold * 100))%")
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $manager.memoryThreshold, in: 0.5...0.95, step: 0.05)
                                .accentColor(.blue)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("웹뷰 풀 크기")
                                    .font(.headline)
                                
                                Spacer()
                                
                                Text("\(manager.webViewPoolSize)개")
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: Binding(
                                get: { Double(manager.webViewPoolSize) },
                                set: { manager.webViewPoolSize = Int($0) }
                            ), in: 5...20, step: 1)
                            .accentColor(.blue)
                        }
                    }
                }
                .navigationTitle("성능")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("닫기") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 🎯 Enhanced Unified Manager with Popup Alert
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
    
    // MARK: - Desktop Mode State
    private weak var currentStateModel: WebViewStateModel?
    
    func setCurrentStateModel(_ stateModel: WebViewStateModel) {
        self.currentStateModel = stateModel
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
    
    // MARK: - Desktop Mode Actions
    func getDesktopModeEnabled() -> Bool {
        guard let stateModel = currentStateModel else { return false }
        return SiteMenuSystem.Desktop.getDesktopModeEnabled(for: stateModel)
    }
    
    func toggleDesktopMode() {
        guard let stateModel = currentStateModel else { return }
        SiteMenuSystem.Desktop.toggleDesktopMode(for: stateModel)
        objectWillChange.send()
    }
    
    func getZoomLevel() -> Double {
        guard let stateModel = currentStateModel else { return 1.0 }
        return SiteMenuSystem.Desktop.getZoomLevel(for: stateModel)
    }
    
    func setZoomLevel(_ level: Double) {
        guard let stateModel = currentStateModel else { return }
        SiteMenuSystem.Desktop.setZoomLevel(level, for: stateModel)
        objectWillChange.send()
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

// MARK: - 🔧 ContentView Extension (Complete Integration with Popup Alert)
extension View {
    func siteMenuOverlay(
        manager: SiteMenuManager,
        currentState: WebViewStateModel,
        tabs: Binding<[WebTab]>,
        selectedTabIndex: Binding<Int>,
        outerHorizontalPadding: CGFloat,
        showAddressBar: Bool,
        whiteGlassBackground: AnyView,
        whiteGlassOverlay: AnyView
    ) -> some View {
        self
            .overlay {
                if manager.showSiteMenu {
                    SiteMenuSystem.UI.SiteMenuOverlay(
                        manager: manager,
                        currentState: currentState,
                        outerHorizontalPadding: outerHorizontalPadding,
                        showAddressBar: showAddressBar,
                        whiteGlassBackground: whiteGlassBackground,
                        whiteGlassOverlay: whiteGlassOverlay,
                        tabs: tabs,
                        selectedTabIndex: selectedTabIndex
                    )
                }
            }
    }
}
