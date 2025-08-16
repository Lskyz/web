//
//  WebViewDataModel.swift
//  🎯 **단순화된 정상 히스토리 시스템** 
//  ✅ 정상 기록, 정상 배열 - 예측 가능한 동작
//  🚫 네이티브 시스템 완전 차단 - 순수 커스텀만
//  🔧 세션 점프 이슈 해결 - 현재 인덱스 고정
//

import Foundation
import SwiftUI
import WebKit

// MARK: - 네비게이션 타입 정의
enum NavigationType: String, Codable, CaseIterable {
    case normal = "normal"
    case reload = "reload"
    case home = "home"
    case spaNavigation = "spa"
    case userClick = "userClick"
}

// MARK: - 페이지 기록
struct PageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    let timestamp: Date
    var lastAccessed: Date
    var siteType: String?
    var navigationType: NavigationType = .normal
    
    init(url: URL, title: String = "", siteType: String? = nil, navigationType: NavigationType = .normal) {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? (url.host ?? "제목 없음") : title
        self.timestamp = Date()
        self.lastAccessed = Date()
        self.siteType = siteType
        self.navigationType = navigationType
    }
    
    mutating func updateTitle(_ title: String) {
        if !title.isEmpty {
            self.title = title
        }
        lastAccessed = Date()
    }
    
    mutating func updateAccess() {
        lastAccessed = Date()
    }
    
    // URL 정규화 (게시글 구분용 핵심 파라미터 유지)
    static func normalizeURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        if components?.scheme == "http" {
            components?.scheme = "https"
        }
        
        if let path = components?.path, path.hasSuffix("/") && path.count > 1 {
            components?.path = String(path.dropLast())
        }
        
        // 핵심 파라미터만 유지
        if let queryItems = components?.queryItems {
            let importantParams = ["document_srl", "wr_id", "no", "id", "mid", "page"]
            let filteredItems = queryItems.filter { importantParams.contains($0.name) }
            
            if !filteredItems.isEmpty {
                components?.queryItems = filteredItems.sorted { $0.name < $1.name }
            } else {
                components?.query = nil
            }
        }
        
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
    
    func normalizedURL() -> String {
        return Self.normalizeURL(self.url)
    }
    
    // 로그인 관련 URL 감지
    static func isLoginRelatedURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()
        let loginPatterns = [
            "login", "signin", "auth", "oauth", "sso", "redirect", "callback",
            "nid.naver.com", "accounts.google.com", "facebook.com/login", "twitter.com/oauth",
            "returnurl=", "redirect_uri=", "continue=", "state=", "code="
        ]
        return loginPatterns.contains { urlString.contains($0) }
    }
}

// MARK: - 세션 저장/복원
struct WebViewSession: Codable {
    let pageRecords: [PageRecord]
    let currentIndex: Int
    let sessionId: UUID
    let createdAt: Date
    
    init(pageRecords: [PageRecord], currentIndex: Int) {
        self.pageRecords = pageRecords
        self.currentIndex = currentIndex
        self.sessionId = UUID()
        self.createdAt = Date()
    }
}

// MARK: - 전역 히스토리
struct HistoryEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    let url: URL
    let title: String
    let date: Date
}

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 🎯 **단순화된 WebViewDataModel**
final class WebViewDataModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID?
    
    // ✅ 순수 히스토리 배열 (정상 기록, 정상 배열)
    @Published private(set) var pageHistory: [PageRecord] = []
    @Published private(set) var currentPageIndex: Int = -1
    
    // ✅ 단순한 네비게이션 상태
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    
    // ✅ 복원 상태만 유지
    private(set) var isRestoringSession: Bool = false
    
    // ✅ 전역 히스토리
    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }
    
    // ✅ StateModel 참조
    weak var stateModel: WebViewStateModel?
    
    override init() {
        super.init()
        Self.loadGlobalHistory()
    }
    
    // MARK: - 🎯 **핵심: 단순한 네비게이션 상태 관리**
    
    private func updateNavigationState() {
        let newCanGoBack = currentPageIndex > 0
        let newCanGoForward = currentPageIndex < pageHistory.count - 1
        
        if canGoBack != newCanGoBack || canGoForward != newCanGoForward {
            canGoBack = newCanGoBack
            canGoForward = newCanGoForward
            objectWillChange.send()
            dbg("🎯 네비게이션 상태: back=\(canGoBack), forward=\(canGoForward), index=\(currentPageIndex)/\(pageHistory.count)")
        }
    }
    
    // MARK: - 🌐 **SPA 네비게이션 처리** (완전 단순화)
    
    func handleSPANavigation(type: String, url: URL, title: String, timestamp: Double, siteType: String = "unknown") {
        dbg("🌐 SPA \(type): \(siteType) | \(url.absoluteString)")
        
        // 로그인 관련은 무시
        if PageRecord.isLoginRelatedURL(url) {
            dbg("🔒 로그인 페이지 무시: \(url.absoluteString)")
            return
        }
        
        switch type {
        case "push":
            // 모든 push는 새 페이지
            addNewPage(url: url, title: title, navigationType: .spaNavigation)
        case "replace":
            // replace는 현재 페이지 교체
            replaceCurrentPage(url: url, title: title, siteType: siteType)
        case "pop", "hash", "dom":
            // 모든 이동은 새 페이지로 처리 (단순하게)
            addNewPage(url: url, title: title, navigationType: .spaNavigation)
        case "title":
            // 제목 변경만 별도 처리
            updateCurrentPageTitle(title)
        default:
            dbg("🌐 알 수 없는 SPA 타입: \(type)")
        }
        
        // 전역 히스토리 추가
        if type != "title" && !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }
    
    private func replaceCurrentPage(url: URL, title: String, siteType: String) {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else {
            addNewPage(url: url, title: title, navigationType: .reload)
            return
        }
        
        var record = pageHistory[currentPageIndex]
        record.url = url
        record.updateTitle(title)
        record.siteType = siteType
        record.navigationType = .reload
        pageHistory[currentPageIndex] = record
        
        dbg("🔄 SPA Replace - 현재 페이지 교체:
    
    // MARK: - 🎯 **핵심: 단순한 새 페이지 추가 로직**
    
    func addNewPage(url: URL, title: String = "", navigationType: NavigationType = .normal) {
        // 🔒 로그인 관련은 완전 무시
        if PageRecord.isLoginRelatedURL(url) {
            dbg("🔒 로그인 페이지 히스토리 제외: \(url.absoluteString)")
            return
        }
        
        // ✅ **핵심 로직**: 현재 페이지와 같으면 제목만 업데이트
        if let currentRecord = currentPageRecord,
           currentRecord.normalizedURL() == PageRecord.normalizeURL(url) {
            updateCurrentPageTitle(title)
            dbg("🔄 같은 페이지 - 제목만 업데이트: '\(title)'")
            return
        }
        
        // ✅ **새 페이지 추가**: forward 스택 제거 후 추가
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🗑️ forward 스택 \(removedCount)개 제거")
        }
        
        let newRecord = PageRecord(url: url, title: title, navigationType: navigationType)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        updateNavigationState()
        dbg("📄 새 페이지 추가: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] (총 \(pageHistory.count)개)")
        
        // 전역 히스토리 추가
        if !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }
    
    func updateCurrentPageTitle(_ title: String) {
        guard currentPageIndex >= 0, 
              currentPageIndex < pageHistory.count,
              !title.isEmpty else { 
            return 
        }
        
        var updatedRecord = pageHistory[currentPageIndex]
        updatedRecord.updateTitle(title)
        pageHistory[currentPageIndex] = updatedRecord
        dbg("📝 제목 업데이트: '\(title)'")
    }
    
    var currentPageRecord: PageRecord? {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return nil }
        return pageHistory[currentPageIndex]
    }
    
    // MARK: - 🎯 **순수 인덱스 기반 네비게이션** (세션 점프 방지)
    
    func navigateBack() -> PageRecord? {
        guard canGoBack, currentPageIndex > 0 else { 
            dbg("❌ navigateBack 실패: canGoBack=\(canGoBack), currentIndex=\(currentPageIndex)")
            return nil
        }
        
        currentPageIndex -= 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            updateNavigationState()
            dbg("⬅️ 뒤로가기: '\(record.title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
            return record
        }
        
        return nil
    }
    
    func navigateForward() -> PageRecord? {
        guard canGoForward, currentPageIndex < pageHistory.count - 1 else { 
            dbg("❌ navigateForward 실패: canGoForward=\(canGoForward), currentIndex=\(currentPageIndex)")
            return nil
        }
        
        currentPageIndex += 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            updateNavigationState()
            dbg("➡️ 앞으로가기: '\(record.title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
            return record
        }
        
        return nil
    }
    
    // MARK: - 🏄‍♂️ **스와이프 제스처 처리** (과거 점프 완전 제거)
    
    func handleSwipeGestureDetected(to url: URL) {
        // ✅ **단순화**: 스와이프도 그냥 새 페이지로 추가
        // 히스토리에서 찾아서 점프하는 로직 완전 제거
        addNewPage(url: url, title: "", navigationType: .normal)
        stateModel?.syncCurrentURL(url)
        dbg("👆 스와이프 - 새 페이지로 추가: \(url.absoluteString)")
    }
    
    func findPageIndex(for url: URL) -> Int? {
        // 히스토리에서 같은 URL 찾기 (미리보기용만 - 점프하지 않음)
        let normalizedURL = PageRecord.normalizeURL(url)
        let matchingIndices = pageHistory.enumerated().compactMap { index, record in
            record.normalizedURL() == normalizedURL ? index : nil
        }
        return matchingIndices.last // 가장 최근 것 반환 (참고용만)
    }
    
    // MARK: - 세션 저장/복원
    
    func saveSession() -> WebViewSession? {
        guard !pageHistory.isEmpty, currentPageIndex >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 없음")
            return nil
        }
        
        let session = WebViewSession(pageRecords: pageHistory, currentIndex: currentPageIndex)
        dbg("💾 세션 저장: \(pageHistory.count)개 페이지, 현재 인덱스 \(currentPageIndex)")
        return session
    }
    
    func restoreSession(_ session: WebViewSession) {
        dbg("🔄 === 세션 복원 시작 ===")
        isRestoringSession = true
        
        pageHistory = session.pageRecords
        currentPageIndex = max(0, min(session.currentIndex, pageHistory.count - 1))
        
        updateNavigationState()
        dbg("🔄 세션 복원: \(pageHistory.count)개 페이지, 현재 인덱스 \(currentPageIndex)")
    }
    
    func finishSessionRestore() {
        isRestoringSession = false
    }
    
    // MARK: - 유틸리티
    
    func clearHistory() {
        Self.globalHistory.removeAll()
        Self.saveGlobalHistory()
        pageHistory.removeAll()
        currentPageIndex = -1
        updateNavigationState()
        dbg("🧹 전체 히스토리 삭제")
    }
    
    // MARK: - 네비게이션 타입 추적
    private var pendingNavigationType: WKNavigationType = .other
    private var pendingNavigationURL: URL?
    
    // MARK: - 🚫 **네이티브 시스템 감지 및 차단**
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 네비게이션 타입 저장
        pendingNavigationType = navigationAction.navigationType
        pendingNavigationURL = navigationAction.request.url
        
        // 사용자 클릭 감지만 하고, 네이티브 뒤로가기는 완전 차단
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted:
            dbg("👆 사용자 클릭 감지: \(navigationAction.request.url?.absoluteString ?? "nil")")
        case .backForward:
            dbg("🚫 네이티브 뒤로/앞으로 차단")
            // 네이티브 히스토리 네비게이션 완전 차단하고 우리 시스템 사용
            decisionHandler(.cancel)
            return
        case .reload:
            dbg("🔄 새로고침 감지: \(navigationAction.request.url?.absoluteString ?? "nil")")
        default:
            dbg("🤖 기타 네비게이션: \(navigationAction.request.url?.absoluteString ?? "nil")")
        }
        
        decisionHandler(.allow)
    }
    
    // MARK: - WKNavigationDelegate (단순화)
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stateModel?.handleLoadingStart()
        
        // 🚫 **자동 스와이프 감지 타이머 완전 제거**
        // 이 로직이 세션 점프를 유발할 수 있음
        // if let startURL = startURL, 
        //    !isRestoringSession, 
        //    stateModel?.currentURL != startURL {
        //    handleSwipeGestureDetected(to: startURL) // ← 이게 문제!
        // }
        
        dbg("🚀 네비게이션 시작: \(webView.url?.absoluteString ?? "nil")")
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        stateModel?.handleLoadingFinish()
        let title = webView.title ?? webView.url?.host ?? "제목 없음"
        
        if let finalURL = webView.url {
            if isRestoringSession {
                updateCurrentPageTitle(title)
                finishSessionRestore()
                dbg("🔄 복원 완료: '\(title)'")
            } else {
                // ✅ **완전한 히스토리 구축 로직 사용**
                let isReload = (pendingNavigationType == .reload)
                buildHistory(url: finalURL, title: title, navigationType: pendingNavigationType, isReload: isReload)
                stateModel?.syncCurrentURL(finalURL)
            }
        }
        
        // 네비게이션 타입 초기화
        pendingNavigationType = .other
        pendingNavigationURL = nil
        
        stateModel?.triggerNavigationFinished()
        dbg("✅ 네비게이션 완료")
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            stateModel?.notifyHTTPError(httpResponse.statusCode, url: navigationResponse.response.url?.absoluteString ?? "")
        }
        
        stateModel?.handleDownloadDecision(navigationResponse, decisionHandler: decisionHandler)
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        stateModel?.handleDidCommitNavigation(webView)
    }
    
    // MARK: - 전역 히스토리 관리
    
    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
            TabPersistenceManager.debugMessages.append("[\(ts())] ☁️ 전역 방문 기록 저장: \(globalHistory.count)개")
        }
    }
    
    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
            TabPersistenceManager.debugMessages.append("[\(ts())] ☁️ 전역 방문 기록 로드: \(loaded.count)개")
        }
    }
    
    // MARK: - 기존 호환성 API
    
    var historyURLs: [String] {
        return pageHistory.map { $0.url.absoluteString }
    }
    
    var currentHistoryIndex: Int {
        return max(0, currentPageIndex)
    }
    
    func historyStackIfAny() -> [URL] {
        return pageHistory.map { $0.url }
    }
    
    func currentIndexInSafeBounds() -> Int {
        return max(0, min(currentPageIndex, pageHistory.count - 1))
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        let id = tabID?.uuidString.prefix(6) ?? "noTab"
        let navState = "B:\(canGoBack ? "✅" : "❌") F:\(canGoForward ? "✅" : "❌")"
        let historyCount = "[\(pageHistory.count)]"
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(historyCount) \(msg)")
    }
}

// MARK: - 방문기록 페이지 뷰
extension WebViewDataModel {
    public struct HistoryPage: View {
        @ObservedObject var dataModel: WebViewDataModel
        let onNavigateToPage: (PageRecord) -> Void
        let onNavigateToURL: (URL) -> Void
        
        @State private var searchQuery: String = ""
        @Environment(\.dismiss) private var dismiss
        
        private var dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        public init(
            dataModel: WebViewDataModel,
            onNavigateToPage: @escaping (PageRecord) -> Void,
            onNavigateToURL: @escaping (URL) -> Void
        ) {
            self.dataModel = dataModel
            self.onNavigateToPage = onNavigateToPage
            self.onNavigateToURL = onNavigateToURL
        }

        private var sessionHistory: [PageRecord] {
            return dataModel.pageHistory.reversed()
        }
        
        private var filteredGlobalHistory: [HistoryEntry] {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return WebViewDataModel.globalHistory.sorted { $0.date > $1.date } }
            return WebViewDataModel.globalHistory
                .filter { $0.url.absoluteString.lowercased().contains(q) || $0.title.lowercased().contains(q) }
                .sorted { $0.date > $1.date }
        }

        public var body: some View {
            List {
                if !sessionHistory.isEmpty {
                    Section("현재 세션 (\(sessionHistory.count)개)") {
                        ForEach(sessionHistory) { record in
                            SessionHistoryRowView(
                                record: record, 
                                isCurrent: record.id == dataModel.currentPageRecord?.id
                            )
                            .onTapGesture {
                                onNavigateToPage(record)
                                dismiss()
                            }
                        }
                    }
                }
                
                Section("전체 기록 (\(filteredGlobalHistory.count)개)") {
                    ForEach(filteredGlobalHistory) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "globe")
                                    .frame(width: 16, height: 16)
                                    .foregroundColor(.blue)
                                
                                Text(item.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                Text(dateFormatter.string(from: item.date))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(item.url.absoluteString)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .onTapGesture {
                            onNavigateToURL(item.url)
                            dismiss()
                        }
                    }
                    .onDelete(perform: deleteGlobalHistory)
                }
            }
            .navigationTitle("방문 기록")
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("모두 지우기") {
                        dataModel.clearHistory()
                    }
                }
            }
        }

        func deleteGlobalHistory(at offsets: IndexSet) {
            let items = filteredGlobalHistory
            let targets = offsets.map { items[$0] }
            WebViewDataModel.globalHistory.removeAll { targets.contains($0) }
            WebViewDataModel.saveGlobalHistory()
            TabPersistenceManager.debugMessages.append("[\(ts())] 🧹 방문 기록 삭제: \(targets.count)개")
        }
    }
}

// MARK: - 세션 히스토리 행 뷰
struct SessionHistoryRowView: View {
    let record: PageRecord
    let isCurrent: Bool
    
    private var navigationTypeIcon: String {
        switch record.navigationType {
        case .home: return "house.fill"
        case .reload: return "arrow.clockwise"
        case .spaNavigation: return "sparkles"
        case .userClick: return "hand.tap.fill"
        default: return "circle"
        }
    }
    
    private var navigationTypeColor: Color {
        switch record.navigationType {
        case .home: return .green
        case .reload: return .orange
        case .spaNavigation: return .blue
        case .userClick: return .red
        default: return .gray
        }
    }
    
    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "arrow.right.circle.fill" : navigationTypeIcon)
                .foregroundColor(isCurrent ? .blue : navigationTypeColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(record.title)
                        .font(isCurrent ? .headline : .body)
                        .fontWeight(isCurrent ? .bold : .regular)
                        .lineLimit(1)
                    
                    if let siteType = record.siteType {
                        Text("[\(siteType)]")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    if record.navigationType != .normal {
                        Text(record.navigationType.rawValue)
                            .font(.caption2)
                            .foregroundColor(navigationTypeColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(navigationTypeColor.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    Spacer()
                }
                
                Text(record.url.absoluteString)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                
                HStack {
                    Text("ID: \(String(record.id.uuidString.prefix(8)))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(DateFormatter.shortTime.string(from: record.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .background(isCurrent ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
}

extension DateFormatter {
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
