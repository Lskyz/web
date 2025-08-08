//
//  WebViewStateModel.swift
//  페이지 고유번호 기반 히스토리 시스템 (기존 복잡한 시스템 교체)
//

import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 페이지 식별자 (제목, 주소, 시간 포함)
struct PageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let url: URL
    var title: String
    let timestamp: Date
    var lastAccessed: Date
    
    init(url: URL, title: String = "") {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? (url.host ?? "제목 없음") : title
        self.timestamp = Date()
        self.lastAccessed = Date()
    }
    
    mutating func updateTitle(_ newTitle: String) {
        if !newTitle.isEmpty {
            title = newTitle
        }
        lastAccessed = Date()
    }
    
    mutating func updateAccess() {
        lastAccessed = Date()
    }
}

// MARK: - 간단한 히스토리 세션 
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
    
    // 기존 시스템과의 호환성을 위한 computed properties
    var urls: [URL] { pageRecords.map { $0.url } }
}

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - WebViewStateModel (기존 인터페이스 유지, 내부 구현 교체)
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {

    var tabID: UUID?
    
    // 페이지 기록 기반 히스토리 (기존 복잡한 시스템 교체)
    @Published private var pageHistory: [PageRecord] = []
    @Published private var currentPageIndex: Int = -1
    
    let navigationDidFinish = PassthroughSubject<Void, Never>()

    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }
            
            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            dbg("URL 업데이트 → \(url.absoluteString)")
            
            // 🔧 주소창에서 직접 입력한 경우 웹뷰 로드
            if !isRestoringSession && !isNavigatingFromWebView {
                if let webView = webView {
                    webView.load(URLRequest(url: url))
                    dbg("🌐 주소창에서 웹뷰 로드: \(url.absoluteString)")
                }
            }
        }
    }

    // 웹뷰 내부 네비게이션인지 구분하는 플래그
    private var isNavigatingFromWebView: Bool = false

    @Published var canGoBack: Bool = false {
        didSet {
            dbg("canGoBack 업데이트: \(canGoBack)")
        }
    }
    @Published var canGoForward: Bool = false {
        didSet {
            dbg("canGoForward 업데이트: \(canGoForward)")
        }
    }
    @Published var showAVPlayer = false

    // 복원 상태 관리 (단순화)
    private(set) var isRestoringSession: Bool = false
    
    weak var webView: WKWebView? {
        didSet {
            if webView != nil {
                dbg("🔗 webView 연결됨")
                updateNavigationState()
            }
        }
    }

    // 기존 방문기록 구조체 유지
    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID()
        let url: URL
        let title: String
        let date: Date
    }

    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }

    func clearHistory() {
        WebViewStateModel.globalHistory = []
        WebViewStateModel.saveGlobalHistory()
        pageHistory.removeAll()
        currentPageIndex = -1
        updateNavigationState()
        dbg("🧹 전체 히스토리 삭제")
    }

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

    // MARK: - 새로운 페이지 기록 시스템
    
    private func addNewPage(url: URL, title: String = "") {
        // 현재 위치 이후의 forward 기록 제거
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            pageHistory.removeSubrange((currentPageIndex + 1)...)
        }
        
        let newRecord = PageRecord(url: url, title: title)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // 최대 50개 유지
        if pageHistory.count > 50 {
            pageHistory.removeFirst()
            currentPageIndex -= 1
        }
        
        updateNavigationState()
        dbg("📄 페이지 추가: \(newRecord.title) [ID: \(String(newRecord.id.uuidString.prefix(8)))] 인덱스: \(currentPageIndex)")
    }
    
    private func updateNavigationState() {
        canGoBack = currentPageIndex > 0
        canGoForward = currentPageIndex < pageHistory.count - 1
    }
    
    func updateCurrentPageTitle(_ title: String) {
        guard currentPageIndex >= 0, 
              currentPageIndex < pageHistory.count,
              !title.isEmpty else { return }
        
        var updatedRecord = pageHistory[currentPageIndex]
        updatedRecord.updateTitle(title)
        pageHistory[currentPageIndex] = updatedRecord
        
        dbg("📝 페이지 제목 업데이트: \(title) [ID: \(String(updatedRecord.id.uuidString.prefix(8)))]")
    }
    
    var currentPageRecord: PageRecord? {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return nil }
        return pageHistory[currentPageIndex]
    }

    // MARK: - 세션 저장/복원 (단순화)
    
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
        isRestoringSession = true
        
        pageHistory = session.pageRecords
        currentPageIndex = max(0, min(session.currentIndex, pageHistory.count - 1))
        
        // 현재 페이지 URL 설정
        if let currentRecord = currentPageRecord {
            isNavigatingFromWebView = true
            currentURL = currentRecord.url
            isNavigatingFromWebView = false
            
            dbg("🔄 세션 복원: \(pageHistory.count)개 페이지, 현재 '\(currentRecord.title)'")
        } else {
            currentURL = nil
            dbg("🔄 세션 복원 실패: 유효한 페이지 없음")
        }
        
        updateNavigationState()
        
        // 복원 완료 후 웹뷰 로드
        if let webView = webView, let url = currentURL {
            webView.load(URLRequest(url: url))
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isRestoringSession = false
            self.dbg("🔄 세션 복원 완료")
        }
    }

    // MARK: - 네비게이션 메서드 (기존 인터페이스 유지)
    
    func goBack() {
        guard canGoBack, currentPageIndex > 0 else { 
            dbg("⬅️ 뒤로가기 불가: canGoBack=\(canGoBack), index=\(currentPageIndex)")
            return 
        }
        
        currentPageIndex -= 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            isNavigatingFromWebView = true
            currentURL = record.url
            
            if let webView = webView {
                webView.load(URLRequest(url: record.url))
                dbg("🌐 뒤로가기 웹뷰 로드: \(record.url.absoluteString)")
            }
            
            updateNavigationState()
            dbg("⬅️ 뒤로: '\(record.title)' [ID: \(String(record.id.uuidString.prefix(8)))] | 인덱스: \(currentPageIndex)/\(pageHistory.count)")
            
            // isNavigatingFromWebView는 didFinish에서 false로 설정
        }
    }
    
    func goForward() {
        guard canGoForward, currentPageIndex < pageHistory.count - 1 else { 
            dbg("➡️ 앞으로가기 불가: canGoForward=\(canGoForward), index=\(currentPageIndex)")
            return 
        }
        
        currentPageIndex += 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            isNavigatingFromWebView = true
            currentURL = record.url
            
            if let webView = webView {
                webView.load(URLRequest(url: record.url))
                dbg("🌐 앞으로가기 웹뷰 로드: \(record.url.absoluteString)")
            }
            
            updateNavigationState()
            dbg("➡️ 앞으로: '\(record.title)' [ID: \(String(record.id.uuidString.prefix(8)))] | 인덱스: \(currentPageIndex)/\(pageHistory.count)")
            
            // isNavigatingFromWebView는 didFinish에서 false로 설정
        }
    }
    
    func reload() { 
        guard let webView = webView else { return }
        webView.reload()
        dbg("🔄 페이지 새로고침")
    }

    // MARK: - 기존 호환성 API (기존 코드가 계속 작동하도록)
    
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
    
    // MARK: - 기존 호환성 메서드
    
    func loadURLIfReady() {
        if let url = currentURL, let webView = webView {
            webView.load(URLRequest(url: url))
            dbg("URL 로드 시도: \(url.absoluteString)")
        } else {
            dbg("URL 로드 실패: WebView 또는 URL 없음")
        }
    }

    // MARK: - WKNavigationDelegate (개선)
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        dbg("🌐 로드 시작 → \(webView.url?.absoluteString ?? "(pending)")")
        
        // 🔧 웹뷰 내부 네비게이션 감지
        if let startURL = webView.url, currentURL != startURL && !isRestoringSession {
            dbg("🔄 웹뷰 내부 네비게이션 감지: \(startURL.absoluteString)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView
        
        let title = webView.title ?? webView.url?.host ?? "제목 없음"
        
        // 🔧 웹뷰에서 실제 로드된 URL 확인 및 페이지 기록 업데이트
        if let finalURL = webView.url {
            dbg("🌐 didFinish: \(finalURL.absoluteString), current: \(currentURL?.absoluteString ?? "nil")")
            
            // 🔥 핵심 수정: 항상 새 페이지로 기록 (단, 복원 중 제외)
            if !isRestoringSession {
                isNavigatingFromWebView = true
                
                // 마지막 페이지와 URL이 다르면 새 페이지 추가
                let shouldAddNewPage: Bool
                if pageHistory.isEmpty {
                    shouldAddNewPage = true
                } else if let lastRecord = pageHistory.last {
                    shouldAddNewPage = (lastRecord.url != finalURL)
                } else {
                    shouldAddNewPage = true
                }
                
                if shouldAddNewPage {
                    addNewPage(url: finalURL, title: title)
                    dbg("🆕 새 페이지 기록: '\(title)' (\(finalURL.absoluteString))")
                    
                    // 전역 방문 기록 추가
                    WebViewStateModel.globalHistory.append(.init(url: finalURL, title: title, date: Date()))
                    WebViewStateModel.saveGlobalHistory()
                } else {
                    // 같은 URL이면 제목만 업데이트
                    updateCurrentPageTitle(title)
                    dbg("📝 페이지 제목만 업데이트: '\(title)'")
                }
                
                // currentURL 동기화 (didSet 호출 방지)
                currentURL = finalURL
                isNavigatingFromWebView = false
            }
        }
        
        updateNavigationState()
        
        dbg("🌐 로드 완료 → '\(title)' | back=\(canGoBack) forward=\(canGoForward) | 히스토리: \(pageHistory.count)개")
        
        // 저장 트리거 (복원 중이 아닐 때만)
        if !isRestoringSession {
            navigationDidFinish.send(())
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dbg("❌ 로드 실패(Provisional): \(error.localizedDescription)")
        isRestoringSession = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dbg("❌ 로드 실패(Navigation): \(error.localizedDescription)")
        isRestoringSession = false
    }

    // MARK: - 디버그 로그
    private func dbg(_ msg: String) {
        let id: String
        if let tabID = tabID {
            id = String(tabID.uuidString.prefix(6))
        } else {
            id = "noTab"
        }
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)] \(msg)")
    }

    // MARK: - 방문기록 페이지 (기존 UI 유지하면서 새 시스템 연동)
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel
        @State private var searchQuery: String = ""
        @Environment(\.dismiss) private var dismiss
        
        private var dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        // 현재 세션 히스토리
        private var sessionHistory: [PageRecord] {
            return state.pageHistory.reversed()
        }
        
        // 전역 히스토리 (검색 필터링)
        private var filteredGlobalHistory: [HistoryEntry] {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return WebViewStateModel.globalHistory.sorted { $0.date > $1.date } }
            return WebViewStateModel.globalHistory
                .filter { $0.url.absoluteString.lowercased().contains(q) || $0.title.lowercased().contains(q) }
                .sorted { $0.date > $1.date }
        }

        init(state: WebViewStateModel) {
            self._state = ObservedObject(wrappedValue: state)
        }

        var body: some View {
            List {
                // 현재 세션 히스토리
                if !sessionHistory.isEmpty {
                    Section("현재 세션") {
                        ForEach(sessionHistory) { record in
                            SessionHistoryRowView(
                                record: record, 
                                isCurrent: record.id == state.currentPageRecord?.id
                            )
                            .onTapGesture {
                                // 특정 페이지로 직접 이동
                                if let index = state.pageHistory.firstIndex(where: { $0.id == record.id }) {
                                    state.currentPageIndex = index
                                    state.currentURL = record.url
                                    if let webView = state.webView {
                                        webView.load(URLRequest(url: record.url))
                                    }
                                    state.updateNavigationState()
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                
                // 전역 히스토리
                Section("전체 기록") {
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
                            // 전역 히스토리에서 페이지 로드
                            state.currentURL = item.url
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
                        state.clearHistory()
                    }
                }
            }
        }

        func deleteGlobalHistory(at offsets: IndexSet) {
            let items = filteredGlobalHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
            WebViewStateModel.saveGlobalHistory()
            TabPersistenceManager.debugMessages.append("[\(ts())] 🧹 방문 기록 삭제: \(targets.count)개")
        }
    }
}

// MARK: - 세션 히스토리 행 뷰
struct SessionHistoryRowView: View {
    let record: PageRecord
    let isCurrent: Bool
    
    var body: some View {
        HStack {
            // 현재 페이지 표시
            Image(systemName: isCurrent ? "arrow.right.circle.fill" : "circle")
                .foregroundColor(isCurrent ? .blue : .gray)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(isCurrent ? .headline : .body)
                    .fontWeight(isCurrent ? .bold : .regular)
                    .lineLimit(1)
                
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

// MARK: - DateFormatter 확장
extension DateFormatter {
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
