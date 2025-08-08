import SwiftUI
import AVKit
import WebKit

// MARK: - Bookmark: 북마크 데이터 모델
// (기존 코드 유지, 변경 없음)
struct Bookmark: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let url: String
    let faviconURL: String?
    
    var idValue: UUID { id }
    
    static func == (lhs: Bookmark, rhs: Bookmark) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - WebTabSessionSnapshot: 탭 상태 저장/복원용 Codable 구조체
struct WebTabSessionSnapshot: Codable {
    let id: String
    let history: [HistoryEntry] // [String] → [HistoryEntry]로 변경
    let index: Int
    
    // Codable 키 정의
    enum CodingKeys: String, CodingKey {
        case id, history, index
    }
}

// MARK: - WebTab: 브라우저 탭 모델
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel
    var playerURL: URL? = nil
    var showAVPlayer: Bool = false
    
    var currentURL: URL? { stateModel.currentURL }
    var historyURLs: [String] { stateModel.historyURLs }
    var currentHistoryIndex: Int { stateModel.currentIndexInSafeBounds() }
    
    init(url: URL? = nil) {
        let newID = UUID()
        let model = WebViewStateModel()
        model.tabID = newID
        model.currentURL = url
        self.id = newID
        self.stateModel = model
        TabPersistenceManager.debugMessages.append("새 탭 생성: ID \(id.uuidString)")
    }
    
    init(restoredID: UUID, restoredHistory: [HistoryEntry], restoredIndex: Int) {
        self.id = restoredID
        let model = WebViewStateModel()
        model.tabID = restoredID
        
        let safeIndex = max(0, min(restoredIndex, max(0, restoredHistory.count - 1)))
        if !restoredHistory.isEmpty {
            model.restoreSession(WebViewSession(history: restoredHistory, currentIndex: safeIndex))
        } else {
            model.currentURL = nil
        }
        
        self.stateModel = model
        let urlList = restoredHistory.map { $0.debugDescription }.joined(separator: ", ")
        TabPersistenceManager.debugMessages.append("복원 탭 생성: ID \(restoredID.uuidString), \(restoredHistory.count) 항목, 인덱스 \(safeIndex) | entries=[\(urlList)]")
    }
    
    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
    
    func toSnapshot() -> WebTabSessionSnapshot {
        alignIDsIfNeeded()
        guard let session = stateModel.saveSession() else {
            TabPersistenceManager.debugMessages.append("스냅샷 생성 실패: ID \(id.uuidString), 세션 없음")
            return WebTabSessionSnapshot(id: id.uuidString, history: [], index: -1)
        }
        let snapshot = WebTabSessionSnapshot(id: id.uuidString, history: session.history, index: session.currentIndex)
        let urlList = session.history.map { $0.debugDescription }.joined(separator: ", ")
        TabPersistenceManager.debugMessages.append("스냅샷 생성: ID \(id.uuidString), \(session.history.count) 항목, 인덱스 \(session.currentIndex) | entries=[\(urlList)]")
        return snapshot
    }
    
    private func alignIDsIfNeeded() {
        if stateModel.tabID != id {
            stateModel.tabID = id
            TabPersistenceManager.debugMessages.append("ID 정렬: stateModel.tabID <- \(id.uuidString)")
        }
    }
}

// MARK: - TabPersistenceManager: 탭 저장/복원 관리
enum TabPersistenceManager {
    private static let key = "savedTabs"
    private static let bookmarkKey = "savedBookmarks"
    static var debugMessages: [String] = []
    
    static func saveTabs(_ tabs: [WebTab]) {
        tabs.forEach { tab in
            if tab.stateModel.tabID != tab.id {
                tab.stateModel.tabID = tab.id
                debugMessages.append("저장 전 정렬: \(tab.id.uuidString)")
            }
        }
        
        let snapshots = tabs.map { $0.toSnapshot() }
        let summary = snapshots.map { "\($0.id): \($0.history.count) 항목, idx=\($0.index)" }.joined(separator: ", ")
        debugMessages.append("저장 시도: 탭 \(tabs.count)개, 스냅샷 요약: [\(summary)]")
        
        do {
            let data = try JSONEncoder().encode(snapshots)
            UserDefaults.standard.set(data, forKey: key)
            debugMessages.append("저장 성공: 데이터 크기 \(data.count) 바이트")
        } catch {
            debugMessages.append("저장 실패: 인코딩 오류 - \(error.localizedDescription)")
        }
    }
    
    static func loadTabs() -> [WebTab] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            debugMessages.append("복원 실패: UserDefaults에 데이터 없음")
            return []
        }
        
        debugMessages.append("복원 시도: 데이터 크기 \(data.count) 바이트")
        do {
            let snapshots = try JSONDecoder().decode([WebTabSessionSnapshot].self, from: data)
            debugMessages.append("복원 성공: \(snapshots.count)개 탭 복원")
            
            let tabs: [WebTab] = snapshots.map { snap in
                let rid = UUID(uuidString: snap.id) ?? UUID()
                let hist = snap.history
                let idx = max(0, min(snap.index, max(0, hist.count - 1)))
                let urlList = hist.map { $0.debugDescription }.joined(separator: ", ")
                debugMessages.append("탭 복원 준비: ID \(rid.uuidString), 항목 \(hist.count), idx \(idx) | entries=[\(urlList)]")
                return WebTab(restoredID: rid, restoredHistory: hist, restoredIndex: idx)
            }
            return tabs
        } catch {
            debugMessages.append("복원 실패: 디코딩 오류 - \(error.localizedDescription)")
            return []
        }
    }
    
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

// MARK: - DashboardView, TabManager, ToastView, Collection 확장
// (기존 코드 유지, 변경 없음)
struct DashboardView: View {
    @State private var bookmarks: [Bookmark] = TabPersistenceManager.loadBookmarks()
    @State private var showAddBookmarkAlert: Bool = false
    @State private var showDeleteBookmarkAlert: Bool = false
    @State private var bookmarkToDelete: Bookmark?
    @State private var newBookmarkTitle: String = ""
    @State private var inputURL: String = ""
    @State private var longPressedBookmarkID: UUID?
    
    let onSelectURL: (URL) -> Void
    let triggerLoad: () -> Void
    
    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]
    
    var body: some View {
        VStack(spacing: 20) {
            Text("")
                .font(.largeTitle.bold())
            
            ScrollView {
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
                    Button(action: {
                        showAddBookmarkAlert = true
                        newBookmarkTitle = ""
                        inputURL = ""
                    }) {
                        VStack {
                            Image(systemName: "plus.circle.fill")
                                .resizable()
                                .frame(width: 40, height: 40)
                            Text("추가")
                                .font(.subheadline)
                                .foregroundColor(.black)
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
        .alert("북마크 추가", isPresented: $showAddBookmarkAlert) {
            TextField("제목", text: $newBookmarkTitle)
            TextField("URL", text: $inputURL)
            Button("저장") {
                guard let normalized = normalizedURLString(from: inputURL),
                      let url = URL(string: normalized) else { return }
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
        } message: {
            Text("새로운 북마크의 제목과 URL을 입력하세요.\n예) naver.com → https://naver.com 자동 적용")
        }
        .alert("북마크 삭제", isPresented: $showDeleteBookmarkAlert) {
            Button("삭제", role: .destructive) {
                if let bookmark = bookmarkToDelete, let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
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
        } message: {
            Text("'\(bookmarkToDelete?.title ?? "")' 북마크를 삭제하시겠습니까?")
        }
        .onChange(of: bookmarks) { _ in
            TabPersistenceManager.saveBookmarks(bookmarks)
        }
    }
    
    private func bookmarkIcon(bookmark: Bookmark) -> some View {
        Button(action: {
            if longPressedBookmarkID == bookmark.id {
                longPressedBookmarkID = nil
                return
            }
            guard let url = URL(string: bookmark.url) else { return }
            onSelectURL(url)
            triggerLoad()
        }) {
            VStack {
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
                            .frame(width: 40, height 40)
                    }
                } else {
                    Image(systemName: "globe")
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                Text(bookmark.title)
                    .font(.subheadline)
                    .foregroundColor(.black)
            }
        }
    }
    
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

struct TabManager: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tabs: [WebTab]
    let initialStateModel: WebViewStateModel
    let onTabSelected: (Int) -> Void
    
    @State private var debugMessages: [String] = TabPersistenceManager.debugMessages
    @State private var showToast = false
    @State private var toastMessage = ""
    
    var body: some View {
        ZStack {
            VStack {
                Text("탭 목록")
                    .font(.title.bold())
                
                VStack(alignment: .leading) {
                    Text("디버깅 로그")
                        .font(.headline)
                        .padding(.top)
                    ScrollView {
                        ForEach(debugMessages, id: \.self) { message in
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding(.vertical, 2)
                        }
                    }
                    .frame(maxHeight: 150)
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)
                }
                
                ScrollView {
                    ForEach(tabs) { tab in
                        HStack {
                            Button(action: {
                                if let index = tabs.firstIndex(of: tab) {
                                    onTabSelected(index)
                                    dismiss()
                                    let urlList = tab.stateModel.virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
                                    TabPersistenceManager.debugMessages.append("탭 선택: 인덱스 \(index) (ID \(tab.id.uuidString), entries=[\(urlList)])")
                                    debugMessages = TabPersistenceManager.debugMessages
                                }
                            }) {
                                VStack(alignment: .leading) {
                                    Text(tab.currentURL?.host ?? "대시보드")
                                        .font(.headline)
                                    Text(tab.currentURL?.absoluteString ?? "")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            Spacer()
                            Button(action: { closeTab(tab) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                        .padding()
                    }
                }
                
                Button(action: {
                    let newTab = WebTab(url: nil)
                    var tmp = tabs
                    tmp.append(newTab)
                    TabPersistenceManager.saveTabs(tmp)
                    tabs = tmp
                    if let newIndex = tabs.firstIndex(of: newTab) {
                        onTabSelected(newIndex)
                    }
                    dismiss()
                    TabPersistenceManager.debugMessages.append("새 탭 추가: ID \(newTab.id.uuidString), 대시보드 표시")
                    debugMessages = TabPersistenceManager.debugMessages
                }) {
                    Label("새 탭", systemImage: "plus")
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()
            }
            
            if showToast {
                ToastView(message: toastMessage)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showToast = false }
                        }
                    }
            }
        }
        .onAppear {
            debugMessages = TabPersistenceManager.debugMessages
            if let lastMessage = debugMessages.last {
                toastMessage = lastMessage
                showToast = true
            }
        }
        .onChange(of: tabs) { _ in
            TabPersistenceManager.saveTabs(tabs)
            debugMessages = TabPersistenceManager.debugMessages
        }
    }
    
    private func closeTab(_ tab: WebTab) {
        if let idx = tabs.firstIndex(of: tab) {
            var tmp = tabs
            tmp.remove(at: idx)
            TabPersistenceManager.saveTabs(tmp)
            tabs = tmp
            TabPersistenceManager.debugMessages.append("탭 닫힘: ID \(tab.id.uuidString)")
            debugMessages = TabPersistenceManager.debugMessages
        }
    }
}

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

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}