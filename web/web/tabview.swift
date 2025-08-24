import SwiftUI
import AVKit
import WebKit

// MARK: - Bookmark: 북마크 데이터 모델 (기존 유지)
struct Bookmark: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let url: String
    let faviconURL: String?

    var idValue: UUID { id } // 편의 프로퍼티

    static func == (lhs: Bookmark, rhs: Bookmark) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Collection 확장: 안전 인덱싱
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - WebTabSessionSnapshot: 탭 상태 저장/복원용 (단순화)
struct WebTabSessionSnapshot: Codable {
    let id: String
    let pageRecords: [PageRecord]  // 기존 history 대신 페이지 기록
    let currentIndex: Int
}

// MARK: - 🏊‍♂️ **간소화된 웹뷰 풀 관리자**
class WebViewPool: ObservableObject {
    static let shared = WebViewPool()
    
    // 활성 웹뷰들 (탭 ID별로 관리)
    private var activeWebViews: [UUID: WKWebView] = [:]
    
    // 재사용 대기 웹뷰들 - LRU 순서 관리
    private var pooledWebViews: [UUID: WKWebView] = [:]
    private var lruOrder: [UUID] = [] // 가장 최근 사용된 순서 (마지막이 가장 최근)
    
    private let maxPoolSize = 10 // 최대 풀 크기
    
    private init() {
        TabPersistenceManager.debugMessages.append("🏊‍♂️ 웹뷰 풀 초기화 (간소화)")
    }
    
    // 웹뷰 등록 (탭 생성 시)
    func registerWebView(_ webView: WKWebView, for tabID: UUID) {
        activeWebViews[tabID] = webView
        updateLRU(tabID)
        TabPersistenceManager.debugMessages.append("🏊‍♂️ 웹뷰 등록: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 웹뷰 조회
    func getWebView(for tabID: UUID) -> WKWebView? {
        if let webView = activeWebViews[tabID] {
            updateLRU(tabID)
            return webView
        }
        return nil
    }
    
    // LRU 순서 업데이트
    private func updateLRU(_ tabID: UUID) {
        lruOrder.removeAll { $0 == tabID }
        lruOrder.append(tabID)
    }
    
    // 탭 닫기 시 웹뷰 처리 (간소화 - PIP 보호 제거)
    func handleTabClose(_ tabID: UUID) -> Bool {
        guard let webView = activeWebViews[tabID] else {
            TabPersistenceManager.debugMessages.append("⚠️ 닫을 웹뷰 없음: 탭 \(String(tabID.uuidString.prefix(8)))")
            return true
        }
        
        // 간단히 풀로 이동
        activeWebViews.removeValue(forKey: tabID)
        addToPool(tabID: tabID, webView: webView)
        TabPersistenceManager.debugMessages.append("🏊‍♂️ 탭 닫기 - 풀로 이동: 탭 \(String(tabID.uuidString.prefix(8)))")
        
        return true // 항상 닫기 허용
    }
    
    // 스마트 풀 추가 (LRU 기반 교체)
    private func addToPool(tabID: UUID, webView: WKWebView) {
        if pooledWebViews.count >= maxPoolSize {
            evictLeastRecentlyUsed()
        }
        
        pooledWebViews[tabID] = webView
        updateLRU(tabID)
        
        TabPersistenceManager.debugMessages.append("🏊‍♂️ 웹뷰 풀 저장: 탭 \(String(tabID.uuidString.prefix(8))) (풀 크기: \(pooledWebViews.count)/\(maxPoolSize))")
    }
    
    // LRU 기반 제거
    private func evictLeastRecentlyUsed() {
        if let oldestTabID = lruOrder.first,
           let oldWebView = pooledWebViews.removeValue(forKey: oldestTabID) {
            cleanupWebView(oldWebView)
            lruOrder.removeFirst()
            TabPersistenceManager.debugMessages.append("♻️ LRU 제거: 탭 \(String(oldestTabID.uuidString.prefix(8)))")
        }
    }
    
    // 탭 복원 시 웹뷰 재사용
    func reuseWebView(for tabID: UUID) -> WKWebView? {
        if let pooledWebView = pooledWebViews.removeValue(forKey: tabID) {
            activeWebViews[tabID] = pooledWebView
            updateLRU(tabID)
            TabPersistenceManager.debugMessages.append("♻️ 웹뷰 재사용: 탭 \(String(tabID.uuidString.prefix(8))) (풀 크기: \(pooledWebViews.count))")
            return pooledWebView
        }
        return nil
    }
    
    // 웹뷰 완전 정리
    private func cleanupWebView(_ webView: WKWebView) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        
        // 메모리 정리
        webView.configuration.userContentController.removeAllUserScripts()
        webView.scrollView.delegate = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
    
    // 풀 전체 정리
    func clearPool() {
        for (_, webView) in pooledWebViews {
            cleanupWebView(webView)
        }
        pooledWebViews.removeAll()
        lruOrder.removeAll()
        
        TabPersistenceManager.debugMessages.append("🧹 웹뷰 풀 정리 완료")
    }
    
    // 디버그 정보
    func debugInfo() -> String {
        return "활성: \(activeWebViews.count), 풀: \(pooledWebViews.count)/\(maxPoolSize)"
    }
}

// MARK: - 🎬 **간소화된 PIP 관리자**
class PIPManager: ObservableObject {
    static let shared = PIPManager()
    
    @Published var currentPIPTab: UUID? = nil
    @Published var pipPlayerURL: URL? = nil
    @Published var isPIPActive: Bool = false
    
    private init() {
        TabPersistenceManager.debugMessages.append("🎬 PIP 관리자 초기화")
    }
    
    // PIP 시작
    func pipDidStart() {
        isPIPActive = true
        TabPersistenceManager.debugMessages.append("🎬 PIP 시작됨")
    }
    
    // PIP 중지
    func pipDidStop() {
        isPIPActive = false
        currentPIPTab = nil
        pipPlayerURL = nil
        TabPersistenceManager.debugMessages.append("🎬 PIP 종료됨")
    }
    
    // PIP 시작 요청
    func startPIP(for tabID: UUID, with url: URL) {
        currentPIPTab = tabID
        pipPlayerURL = url
        pipDidStart()
        
        TabPersistenceManager.debugMessages.append("🎬 PIP 시작 요청: 탭 \(String(tabID.uuidString.prefix(8)))")
        
        NotificationCenter.default.post(
            name: .init("StartPIPForTab"),
            object: nil,
            userInfo: ["tabID": tabID, "url": url]
        )
    }
    
    // PIP 중지 요청
    func stopPIP() {
        TabPersistenceManager.debugMessages.append("🎬 PIP 중지 요청")
        pipDidStop()
        NotificationCenter.default.post(name: .init("StopPIPForTab"), object: nil)
    }
}

// MARK: - WebTab: 브라우저 탭 모델 (간소화)
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel
    var playerURL: URL? = nil
    var showAVPlayer: Bool = false

    // 읽기 편의 프로퍼티
    var currentURL: URL? { stateModel.currentURL }
    var historyURLs: [String] { stateModel.historyURLs }
    var currentHistoryIndex: Int { stateModel.currentHistoryIndex }
    
    // 웹뷰 풀 상태
    var isWebViewPooled: Bool {
        return WebViewPool.shared.getWebView(for: id) != nil
    }

    // MARK: 기본 생성자 (새 탭)
    init(url: URL? = nil) {
        let newID = UUID()
        let model = WebViewStateModel()
        model.tabID = newID
        
        if let url = url {
            model.currentURL = url
        }
        
        self.id = newID
        self.stateModel = model
        TabPersistenceManager.debugMessages.append("새 탭 생성: ID \(String(id.uuidString.prefix(8)))")
    }

    // MARK: 복원 전용 생성자
    init(restoredID: UUID, pageRecords: [PageRecord], currentIndex: Int) {
        self.id = restoredID
        let model = WebViewStateModel()
        model.tabID = restoredID

        if !pageRecords.isEmpty {
            let session = WebViewSession(pageRecords: pageRecords, currentIndex: currentIndex)
            model.restoreSession(session)
            
            TabPersistenceManager.debugMessages.append(
                "복원 탭 생성: ID \(String(restoredID.uuidString.prefix(8))), \(pageRecords.count)개 페이지, 인덱스 \(currentIndex)"
            )
        } else {
            model.currentURL = nil
            TabPersistenceManager.debugMessages.append(
                "복원 탭 생성(빈탭): ID \(String(restoredID.uuidString.prefix(8)))"
            )
        }

        self.stateModel = model
    }
    
    // PIP 시작
    mutating func startPIP(with url: URL) {
        playerURL = url
        showAVPlayer = true
        PIPManager.shared.startPIP(for: id, with: url)
        TabPersistenceManager.debugMessages.append("🎬 탭 \(String(id.uuidString.prefix(8))) PIP 시작")
    }
    
    // PIP 중지
    mutating func stopPIP() {
        showAVPlayer = false
        playerURL = nil
        if PIPManager.shared.currentPIPTab == id {
            PIPManager.shared.stopPIP()
        }
        TabPersistenceManager.debugMessages.append("🎬 탭 \(String(id.uuidString.prefix(8))) PIP 중지")
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - 스냅샷 변환
    func toSnapshot() -> WebTabSessionSnapshot {
        alignIDsIfNeeded()

        if let session = stateModel.saveSession() {
            let snapshot = WebTabSessionSnapshot(
                id: id.uuidString, 
                pageRecords: session.pageRecords, 
                currentIndex: session.currentIndex
            )
            
            TabPersistenceManager.debugMessages.append(
                "스냅샷 생성: ID \(String(id.uuidString.prefix(8))), \(session.pageRecords.count)개 페이지, 인덱스 \(session.currentIndex)"
            )
            
            return snapshot
        } else {
            return WebTabSessionSnapshot(id: id.uuidString, pageRecords: [], currentIndex: -1)
        }
    }

    private func alignIDsIfNeeded() {
        if stateModel.tabID != id {
            stateModel.tabID = id
            TabPersistenceManager.debugMessages.append("ID 정렬: stateModel.tabID <- \(String(id.uuidString.prefix(8)))")
        }
    }
}

// MARK: - TabPersistenceManager: 탭 저장/복원 관리
enum TabPersistenceManager {
    private static let key = "savedTabs"
    private static let bookmarkKey = "savedBookmarks"
    static var debugMessages: [String] = []

    // MARK: 탭 저장
    static func saveTabs(_ tabs: [WebTab]) {
        tabs.forEach { tab in
            if tab.stateModel.tabID != tab.id {
                tab.stateModel.tabID = tab.id
                debugMessages.append("저장 전 정렬: \(String(tab.id.uuidString.prefix(8)))")
            }
        }

        let snapshots = tabs.map { $0.toSnapshot() }
        
        let pageCounts = snapshots.map { "\($0.pageRecords.count)페이지" }
        debugMessages.append("저장 시도: 탭 \(tabs.count)개 [\(pageCounts.joined(separator: ", "))]")
        debugMessages.append("웹뷰 풀 상태: \(WebViewPool.shared.debugInfo())")
        
        do {
            let data = try JSONEncoder().encode(snapshots)
            UserDefaults.standard.set(data, forKey: key)
            debugMessages.append("저장 성공: 데이터 크기 \(data.count) 바이트")
        } catch {
            debugMessages.append("저장 실패: 인코딩 오류 - \(error.localizedDescription)")
        }
    }

    // MARK: 탭 복원
    static func loadTabs() -> [WebTab] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            debugMessages.append("복원 실패: UserDefaults에 데이터 없음")
            return []
        }

        debugMessages.append("복원 시도: 데이터 크기 \(data.count) 바이트")
        do {
            let snapshots = try JSONDecoder().decode([WebTabSessionSnapshot].self, from: data)
            debugMessages.append("복원 성공: \(snapshots.count)개 탭 디코딩")

            let tabs: [WebTab] = snapshots.map { snap in
                let rid = UUID(uuidString: snap.id) ?? UUID()
                let pageRecords = snap.pageRecords
                let idx = max(0, min(snap.currentIndex, max(0, pageRecords.count - 1)))
                
                debugMessages.append(
                    "탭 복원 준비: ID \(String(rid.uuidString.prefix(8))), \(pageRecords.count)개 페이지, idx \(idx)"
                )
                
                // 웹뷰 풀에서 재사용 시도
                if WebViewPool.shared.reuseWebView(for: rid) != nil {
                    debugMessages.append("♻️ 웹뷰 재사용됨: \(String(rid.uuidString.prefix(8)))")
                }
                
                return WebTab(restoredID: rid, pageRecords: pageRecords, currentIndex: idx)
            }
            
            let restoredCounts = tabs.map { "\($0.historyURLs.count)페이지" }
            debugMessages.append("복원 완료: [\(restoredCounts.joined(separator: ", "))]")
            debugMessages.append("웹뷰 풀 상태: \(WebViewPool.shared.debugInfo())")
            
            return tabs
        } catch {
            debugMessages.append("복원 실패: 디코딩 오류 - \(error.localizedDescription)")
            return []
        }
    }

    // MARK: 북마크 저장/복원
    static func saveBookmarks(_ bookmarks: [Bookmark]) {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            print("북마크 저장 실패: \(error.localizedDescription)")
        }
    }

    static func loadBookmarks() -> [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            let defaultBookmarks = [
                Bookmark(id: UUID(), title: "Google", url: "https://www.google.com", faviconURL: "https://www.google.com/favicon.ico"),
                Bookmark(id: UUID(), title: "Naver", url: "https://www.naver.com", faviconURL: "https://www.naver.com/favicon.ico")
            ]
            saveBookmarks(defaultBookmarks)
            return defaultBookmarks
        }

        do {
            return try JSONDecoder().decode([Bookmark].self, from: data)
        } catch {
            print("북마크 복원 실패: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - DashboardView: URL 없는 탭의 홈 화면
struct DashboardView: View {
    @State private var bookmarks: [Bookmark] = TabPersistenceManager.loadBookmarks()
    @State private var showAddBookmarkAlert: Bool = false
    @State private var showDeleteBookmarkAlert: Bool = false
    @State private var bookmarkToDelete: Bookmark?
    @State private var newBookmarkTitle: String = ""
    @State private var inputURL: String = ""
    @State private var longPressedBookmarkID: UUID? = nil

    let onNavigateToURL: (URL) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]
    
    // 최근 방문 페이지 (전역 히스토리에서 최신 5개)
    private var recentPages: [HistoryEntry] {
        Array(WebViewDataModel.globalHistory
            .sorted { $0.date > $1.date }
            .prefix(5))
    }

    var body: some View {
        dashboardContent
            .alert("북마크 추가", isPresented: $showAddBookmarkAlert, actions: addBookmarkActions, message: addBookmarkMessage)
            .alert("북마크 삭제", isPresented: $showDeleteBookmarkAlert, actions: deleteBookmarkActions, message: deleteBookmarkMessage)
            .onChange(of: bookmarks) { _ in
                TabPersistenceManager.saveBookmarks(bookmarks)
            }
    }
    
    @ViewBuilder
    private var dashboardContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("")
                    .font(.largeTitle.bold())
                    .padding(.top)

                if !recentPages.isEmpty {
                    recentPagesSection
                }

                bookmarksSection

                systemStatusSection

                Spacer(minLength: 50)
            }
        }
    }
    
    @ViewBuilder
    private var recentPagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.blue)
                Text("최근 방문")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentPages) { page in
                        RecentPageCard(page: page) {
                            DispatchQueue.main.async {
                                onNavigateToURL(page.url)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
    
    @ViewBuilder
    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "book.fill")
                    .foregroundColor(.orange)
                Text("북마크")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal)
            
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(bookmarks) { bookmark in
                    bookmarkIcon(bookmark: bookmark)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5, maximumDistance: 20)
                                .onEnded { _ in
                                    longPressedBookmarkID = bookmark.id
                                    bookmarkToDelete = bookmark
                                    showDeleteBookmarkAlert = true
                                }
                        )
                }
                
                addBookmarkButton
            }
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private var addBookmarkButton: some View {
        Button(action: {
            showAddBookmarkAlert = true
            newBookmarkTitle = ""
            inputURL = ""
        }) {
            VStack {
                Image(systemName: "plus.circle.fill")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .foregroundColor(.blue)
                Text("추가")
                    .font(.subheadline)
                    .foregroundColor(.black)
            }
        }
    }
    
    @ViewBuilder
    private var systemStatusSection: some View {
        if !TabPersistenceManager.debugMessages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundColor(.gray)
                    Text("시스템 상태")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("히스토리: \(WebViewDataModel.globalHistory.count)개")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Text("웹뷰 풀: \(WebViewPool.shared.debugInfo())")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    if let lastMessage = TabPersistenceManager.debugMessages.last {
                        Text("최근: \(lastMessage)")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .lineLimit(2)
                    }
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            .padding(.horizontal)
        }
    }
    
    @ViewBuilder
    private func addBookmarkActions() -> some View {
        TextField("제목", text: $newBookmarkTitle)
        TextField("URL", text: $inputURL)
        Button("저장") {
            guard
                let normalized = normalizedURLString(from: inputURL),
                let url = URL(string: normalized)
            else { return }

            let faviconURL = faviconURLString(for: url)

            let newBookmark = Bookmark(
                id: UUID(),
                title: newBookmarkTitle.isEmpty ? (url.host ?? "북마크") : newBookmarkTitle,
                url: normalized,
                faviconURL: faviconURL
            )
            bookmarks.append(newBookmark)
            TabPersistenceManager.saveBookmarks(bookmarks)
        }
        Button("취소", role: .cancel) { }
    }
    
    private func addBookmarkMessage() -> some View {
        Text("새로운 북마크의 제목과 URL을 입력하세요.\n예) naver.com → https://naver.com 자동 적용")
    }
    
    @ViewBuilder
    private func deleteBookmarkActions() -> some View {
        Button("삭제", role: .destructive) {
            if let bookmark = bookmarkToDelete, 
               let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                bookmarks.remove(at: index)
                TabPersistenceManager.saveBookmarks(bookmarks)
            }
            bookmarkToDelete = nil
            longPressedBookmarkID = nil
        }
        Button("취소", role: .cancel) {
            bookmarkToDelete = nil
            longPressedBookmarkID = nil
        }
    }
    
    private func deleteBookmarkMessage() -> some View {
        Text("'\(bookmarkToDelete?.title ?? "")' 북마크를 삭제하시겠습니까?")
    }

    /// 북마크 아이콘 뷰
    private func bookmarkIcon(bookmark: Bookmark) -> some View {
        Button(action: {
            if longPressedBookmarkID == bookmark.id {
                longPressedBookmarkID = nil
                return
            }

            guard let url = URL(string: bookmark.url) else { return }
            DispatchQueue.main.async {
                onNavigateToURL(url)
            }
        }) {
            VStack(spacing: 8) {
                if let faviconURL = bookmark.faviconURL, let url = URL(string: faviconURL) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                    } placeholder: {
                        Image(systemName: "globe")
                            .resizable()
                            .frame(width: 40, height: 40)
                            .foregroundColor(.blue)
                    }
                } else {
                    Image(systemName: "globe")
                        .resizable()
                        .frame(width: 40, height: 40)
                        .foregroundColor(.blue)
                }
                
                Text(bookmark.title)
                    .font(.subheadline)
                    .foregroundColor(.black)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - URL 보정/생성 유틸
    private func normalizedURLString(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let u = URL(string: trimmed), u.scheme != nil, u.host != nil {
            return trimmed
        }

        var candidate = trimmed
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            candidate = "https://" + trimmed
        }

        if let u2 = URL(string: candidate), u2.scheme != nil, u2.host != nil {
            return candidate
        }
        return nil
    }

    private func faviconURLString(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)/favicon.ico"
    }
}

// MARK: - 최근 방문 페이지 카드
struct RecentPageCard: View {
    let page: HistoryEntry
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "globe")
                        .frame(width: 20, height: 20)
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    Text(RelativeDateTimeFormatter().localizedString(for: page.date, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text(page.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.primary)
                
                Text(page.url.absoluteString)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
            }
            .frame(width: 140, height: 100)
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 🛠️ **간소화된 TabManager**
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tabs: [WebTab]
    let initialStateModel: WebViewStateModel
    let onTabSelected: (Int) -> Void

    @State private var debugMessages: [String] = TabPersistenceManager.debugMessages
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var showDebugView = false
    @State private var showHistorySheet = false
    
    // PIP 상태 표시용
    @StateObject private var pipManager = PIPManager.shared
    
    private var currentTabID: UUID? { initialStateModel.tabID }

    var body: some View {
        GeometryReader { geometry in
            tabManagerContent
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.all)
        .onAppear(perform: onAppearHandler)
        .onChange(of: tabs, perform: onTabsChange)
        .fullScreenCover(isPresented: $showDebugView, content: debugView)
        .sheet(isPresented: $showHistorySheet, content: historySheet)
    }
    
    @ViewBuilder
    private var tabManagerContent: some View {
        ZStack {
            backgroundGradient
            
            VStack(spacing: 12) {
                titleSection
                statusSection
                tabScrollView
            }
            
            floatingButtons
            
            if showToast {
                toastView
            }
        }
    }
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.blue.opacity(0.15),
                Color.yellow.opacity(0.05)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .background(Color.clear)
    }
    
    private var titleSection: some View {
        Text("탭 관리")
            .font(.title.bold())
            .padding(.top, 6)
    }
    
    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("시스템 상태").font(.headline)
                Spacer()
                Button("상세 로그") { showDebugView = true }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                Button("방문기록") { showHistorySheet = true }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
            .padding(.top)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("웹뷰 풀: \(WebViewPool.shared.debugInfo())")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.blue)
                    
                    if pipManager.isPIPActive {
                        Text("🎬 PIP 활성: 탭 \(String(pipManager.currentPIPTab?.uuidString.prefix(8) ?? "없음"))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    
                    ForEach(Array(debugMessages.suffix(5).enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.gray)
                            .lineLimit(2)
                    }
                    if debugMessages.count > 5 {
                        Text("... 및 \(debugMessages.count - 5)개 더")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxHeight: 120)
            .padding()
            .background(Color(UIColor.secondarySystemBackground).opacity(0.7))
            .cornerRadius(10)
        }
    }
    
    @ViewBuilder
    private var tabScrollView: some View {
        ScrollView {
            ForEach(tabs) { tab in
                tabRow(tab: tab)
            }
            .padding(.bottom, 100)
        }
    }
    
    @ViewBuilder
    private func tabRow(tab: WebTab) -> some View {
        HStack(spacing: 12) {
            tabContentButton(tab: tab)
            tabCloseButton(tab: tab)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func tabContentButton(tab: WebTab) -> some View {
        Button(action: {
            if let index = tabs.firstIndex(of: tab) {
                onTabSelected(index)
                DispatchQueue.main.async { dismiss() }
                TabPersistenceManager.debugMessages.append("탭 선택: 인덱스 \(index) (ID \(String(tab.id.uuidString.prefix(8))))")
                debugMessages = TabPersistenceManager.debugMessages
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tab.currentURL?.host ?? "대시보드")
                        .font(.headline)
                        .lineLimit(1)
                    
                    // 간단한 PIP 표시 (보호 기능 없음)
                    if pipManager.isPIPActive && pipManager.currentPIPTab == tab.id {
                        Text("🎬PIP")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                    
                    // 웹뷰 풀 상태 표시
                    if tab.isWebViewPooled {
                        Text("🏊‍♂️풀")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    
                    if tab.id == currentTabID {
                        Text("현재")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
                
                Text(tab.currentURL?.absoluteString ?? "")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                HStack {
                    Text("\(tab.historyURLs.count)개 페이지")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    Spacer()
                    Text("ID: \(String(tab.id.uuidString.prefix(8)))")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.secondarySystemBackground).opacity(tab.id == currentTabID ? 0.9 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        pipManager.isPIPActive && pipManager.currentPIPTab == tab.id ? Color.green.opacity(0.6) : 
                        (tab.id == currentTabID ? Color.orange.opacity(0.6) : Color.clear), 
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func tabCloseButton(tab: WebTab) -> some View {
        // 간단한 닫기 버튼 (보호 기능 제거)
        Button(action: { closeTab(tab) }) {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.red))
        }
        .accessibilityLabel("탭 닫기")
    }
    
    @ViewBuilder
    private var floatingButtons: some View {
        VStack {
            Spacer()
            HStack(spacing: 18) {
                FloatingCircleButton(symbol: "plus") { addNewTabAndExit() }
                FloatingCircleButton(symbol: "trash.fill") { clearWebViewPool() }
                FloatingCircleButton(symbol: "chevron.down") {
                    dismiss()
                    TabPersistenceManager.debugMessages.append("목록 닫기")
                    debugMessages = TabPersistenceManager.debugMessages
                }
            }
            .padding(.bottom, 24)
        }
    }
    
    @ViewBuilder
    private var toastView: some View {
        ToastView(message: toastMessage)
            .transition(.opacity)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showToast = false }
                }
            }
    }
    
    @ViewBuilder
    private func debugView() -> some View {
        DebugLogView()
    }
    
    @ViewBuilder
    private func historySheet() -> some View {
        NavigationView { 
            WebViewDataModel.HistoryPage(
                dataModel: initialStateModel.dataModel,
                onNavigateToPage: { record in
                    if let index = initialStateModel.dataModel.findPageIndex(for: record.url) {
                        if let navigatedRecord = initialStateModel.dataModel.navigateToIndex(index) {
                            initialStateModel.currentURL = navigatedRecord.url
                            if let webView = initialStateModel.webView {
                                webView.load(URLRequest(url: navigatedRecord.url))
                            }
                        }
                    }
                },
                onNavigateToURL: { url in
                    initialStateModel.currentURL = url
                    dismiss()
                }
            )
        }
    }
    
    // MARK: - 이벤트 핸들러들
    
    private func onAppearHandler() {
        debugMessages = TabPersistenceManager.debugMessages
        if let last = debugMessages.last {
            toastMessage = last
            showToast = true
        }
        
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        TabPersistenceManager.debugMessages.append("🛠️ TabManager 간소화 모드")
    }
    
    private func onTabsChange(_: [WebTab]) {
        TabPersistenceManager.saveTabs(tabs)
        debugMessages = TabPersistenceManager.debugMessages
    }

    // MARK: - 동작들

    private func addNewTabAndExit() {
        let newTab = WebTab(url: nil)
        var tmp = tabs
        tmp.append(newTab)
        tabs = tmp
        TabPersistenceManager.saveTabs(tabs)

        if let newIndex = tabs.firstIndex(of: newTab) {
            onTabSelected(newIndex)
            DispatchQueue.main.async { dismiss() }
            TabPersistenceManager.debugMessages.append("🆕 새 탭 추가(+버튼): index \(newIndex) / ID \(String(newTab.id.uuidString.prefix(8)))")
            debugMessages = TabPersistenceManager.debugMessages
        }
    }
    
    // 웹뷰 풀 정리
    private func clearWebViewPool() {
        WebViewPool.shared.clearPool()
        TabPersistenceManager.debugMessages.append("🧹 웹뷰 풀 전체 정리 완료")
        debugMessages = TabPersistenceManager.debugMessages
        
        toastMessage = "웹뷰 풀 정리 완료"
        withAnimation { showToast = true }
    }

    // 간소화된 탭 닫기 (PIP 보호 없음)
    private func closeTab(_ tab: WebTab) {
        guard let closingIndex = tabs.firstIndex(of: tab) else { return }
        
        let wasCurrent = (tab.id == initialStateModel.tabID)
        let indexOfCurrentBefore = tabs.firstIndex(where: { $0.id == initialStateModel.tabID }) ?? 0

        var newList = tabs
        newList.remove(at: closingIndex)

        if newList.isEmpty {
            let dashboard = WebTab(url: nil)
            newList = [dashboard]
            TabPersistenceManager.saveTabs(newList)
            tabs = newList
            if let idx = tabs.firstIndex(of: dashboard) { onTabSelected(idx) }
            DispatchQueue.main.async { dismiss() }
            TabPersistenceManager.debugMessages.append("탭 닫힌(마지막): 새 대시보드 생성 → 선택")
            debugMessages = TabPersistenceManager.debugMessages
            return
        }

        TabPersistenceManager.saveTabs(newList)
        tabs = newList
        
        let targetIndex: Int = {
            if wasCurrent {
                return min(closingIndex, tabs.count - 1)
            } else {
                return tabs.firstIndex(where: { $0.id == initialStateModel.tabID }) ?? min(indexOfCurrentBefore, tabs.count - 1)
            }
        }()

        onTabSelected(targetIndex)
        DispatchQueue.main.async { dismiss() }
        TabPersistenceManager.debugMessages.append("탭 닫힌: ID \(String(tab.id.uuidString.prefix(8))) → 복귀 인덱스 \(targetIndex)")
        debugMessages = TabPersistenceManager.debugMessages
    }
}

// MARK: - 둥근 플로팅 버튼 컴포넌트
private struct FloatingCircleButton: View {
    let symbol: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.bold))
                .foregroundColor(.primary)
                .frame(width: 56, height: 56)
                .background(.ultraThickMaterial)
                .clipShape(Circle())
                .shadow(radius: 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ToastView: 알림 메시지 뷰
struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .padding()
            .background(Color.black.opacity(0.7))
            .foregroundColor(.white)
            .cornerRadius(10)
            .padding(.top, 50)
    }
}

// MARK: - DebugLogView: 간소화
struct DebugLogView: View {
    @State private var debugMessages: [String] = TabPersistenceManager.debugMessages
    @State private var searchText: String = ""
    @State private var showCopyAlert = false
    @State private var copyMessage = ""
    @Environment(\.dismiss) private var dismiss
    
    private var filteredMessages: [String] {
        if searchText.isEmpty {
            return debugMessages.reversed()
        } else {
            return debugMessages.filter { 
                $0.localizedCaseInsensitiveContains(searchText)
            }.reversed()
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            NavigationView {
                debugContent
                    .navigationTitle("디버그 로그")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("닫기") { dismiss() }
                        }
                    }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.all)
        .onAppear { 
            debugMessages = TabPersistenceManager.debugMessages
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            TabPersistenceManager.debugMessages.append("🛠️ DebugView 간소화 모드")
        }
        .alert("복사 완료", isPresented: $showCopyAlert) {
            Button("확인", role: .cancel) { }
        } message: { Text(copyMessage) }
    }
    
    @ViewBuilder
    private var debugContent: some View {
        VStack {
            searchSection
            messagesScrollView
            bottomControls
        }
    }
    
    @ViewBuilder
    private var searchSection: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.gray)
            TextField("로그 검색...", text: $searchText)
                .textFieldStyle(.roundedBorder)
            if !searchText.isEmpty {
                Button("지우기") { searchText = "" }.font(.caption)
            }
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var messagesScrollView: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(filteredMessages.enumerated()), id: \.offset) { index, message in
                        DebugLogRowView(message: message, index: index, onCopy: { copyToClipboard($0) })
                        .id(index)
                    }
                }
                .padding(.horizontal)
                .onAppear { if !filteredMessages.isEmpty { proxy.scrollTo(0, anchor: .top) } }
                .onChange(of: debugMessages.count) { _ in
                    if !filteredMessages.isEmpty { proxy.scrollTo(0, anchor: .top) }
                }
            }
        }
    }
    
    @ViewBuilder
    private var bottomControls: some View {
        HStack {
            Button("전체 복사") {
                let allText = debugMessages.joined(separator: "\n")
                copyToClipboard(allText)
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
            
            Button("로그 지우기") {
                TabPersistenceManager.debugMessages.removeAll()
                debugMessages.removeAll()
            }
            .padding()
            .background(Color.red)
            .foregroundColor(.white)
            .cornerRadius(8)
            
            Spacer()
            Text("\(debugMessages.count)개").font(.caption).foregroundColor(.gray)
        }
        .padding()
    }
    
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        copyMessage = "\(text.count)자 복사됨"
        showCopyAlert = true
    }
}

// MARK: - DebugLogRowView: 개별 로그 행
struct DebugLogRowView: View {
    let message: String
    let index: Int
    let onCopy: (String) -> Void
    
    @State private var isExpanded = false
    
    private var messageColor: Color {
        if message.contains("❌") { return .red }
        if message.contains("🆕") { return .green }
        if message.contains("⬅️") || message.contains("➡️") { return .blue }
        if message.contains("🔧") || message.contains("🔄") { return .orange }
        if message.contains("🏊‍♂️") { return .cyan }
        if message.contains("🛠️") { return .purple }
        return .primary
    }
    
    private var messageIcon: String {
        if message.contains("❌") { return "xmark.circle" }
        if message.contains("🆕") { return "plus.circle" }
        if message.contains("⬅️") { return "arrow.left.circle" }
        if message.contains("➡️") { return "arrow.right.circle" }
        if message.contains("🌐") { return "globe" }
        if message.contains("📄") { return "doc" }
        if message.contains("🏊‍♂️") { return "figure.pool.swim" }
        if message.contains("🛠️") { return "wrench.and.screwdriver" }
        return "info.circle"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: messageIcon)
                    .foregroundColor(messageColor)
                    .frame(width: 16)
                
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(messageColor)
                    .lineLimit(isExpanded ? nil : 3)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                    }
                
                Spacer()
                
                Button(action: { onCopy(message) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            
            if message.count > 100 && !isExpanded {
                HStack {
                    Spacer()
                    Text("탭하여 펼치기").font(.caption2).foregroundColor(.gray)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(messageColor.opacity(0.05))
        .cornerRadius(6)
    }
}
