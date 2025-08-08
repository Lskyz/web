import SwiftUI
import AVKit
import WebKit

// MARK: - Bookmark: 북마크 데이터 모델 (기존 유지)
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

// MARK: - WebTabSessionSnapshot: 탭 상태 저장/복원용 (단순화)
struct WebTabSessionSnapshot: Codable {
    let id: String
    let pageRecords: [PageRecord]  // 기존 history 대신 페이지 기록
    let currentIndex: Int
}

// MARK: - WebTab: 브라우저 탭 모델 (새 시스템 적용)
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel
    var playerURL: URL? = nil
    var showAVPlayer: Bool = false

    // 읽기 편의 프로퍼티 (새 시스템 기준)
    var currentURL: URL? { stateModel.currentURL }
    var historyURLs: [String] { stateModel.historyURLs }
    var currentHistoryIndex: Int { stateModel.currentHistoryIndex }

    // MARK: 기본 생성자 (새 탭)
    init(url: URL? = nil) {
        let newID = UUID()
        let model = WebViewStateModel()
        model.tabID = newID
        
        // URL이 있으면 설정 (자동으로 페이지 기록에 추가됨)
        if let url = url {
            model.currentURL = url
        }
        
        self.id = newID
        self.stateModel = model
        TabPersistenceManager.debugMessages.append("새 탭 생성: ID \(String(id.uuidString.prefix(8)))")
    }

    // MARK: 복원 전용 생성자 (단순화)
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

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - 스냅샷 변환 (단순화)
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
            // 빈 탭
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

// MARK: - TabPersistenceManager: 탭 저장/복원 관리 (새 시스템 적용)
enum TabPersistenceManager {
    private static let key = "savedTabs"
    private static let bookmarkKey = "savedBookmarks"
    static var debugMessages: [String] = []

    // MARK: 탭 저장 (단순화)
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
        
        do {
            let data = try JSONEncoder().encode(snapshots)
            UserDefaults.standard.set(data, forKey: key)
            debugMessages.append("저장 성공: 데이터 크기 \(data.count) 바이트")
        } catch {
            debugMessages.append("저장 실패: 인코딩 오류 - \(error.localizedDescription)")
        }
    }

    // MARK: 탭 복원 (단순화)
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
                
                return WebTab(restoredID: rid, pageRecords: pageRecords, currentIndex: idx)
            }
            
            let restoredCounts = tabs.map { "\($0.historyURLs.count)페이지" }
            debugMessages.append("복원 완료: [\(restoredCounts.joined(separator: ", "))]")
            
            return tabs
        } catch {
            debugMessages.append("복원 실패: 디코딩 오류 - \(error.localizedDescription)")
            return []
        }
    }

    // MARK: 북마크 저장/복원 (기존 유지)
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

// MARK: - WebViewStateModel 확장 제거 (중복 방지)
// loadURLIfReady() 메서드는 WebViewStateModel.swift에 이미 구현됨

// MARK: - DashboardView: URL 없는 탭의 홈 화면 (기존 기능 유지)
struct DashboardView: View {
    @State private var bookmarks: [Bookmark] = TabPersistenceManager.loadBookmarks()
    @State private var showAddBookmarkAlert: Bool = false
    @State private var showDeleteBookmarkAlert: Bool = false
    @State private var bookmarkToDelete: Bookmark?
    @State private var newBookmarkTitle: String = ""
    @State private var inputURL: String = ""
    @State private var longPressedBookmarkID: UUID? = nil

    let onSelectURL: (URL) -> Void
    let triggerLoad: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]
    
    // 최근 방문 페이지 (전역 히스토리에서 최신 5개)
    private var recentPages: [WebViewStateModel.HistoryEntry] {
        Array(WebViewStateModel.globalHistory
            .sorted { $0.date > $1.date }
            .prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("새 탭")
                    .font(.largeTitle.bold())
                    .padding(.top)

                // 최근 방문 페이지 섹션
                if !recentPages.isEmpty {
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
                                        onSelectURL(page.url)
                                        triggerLoad()
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                // 북마크 섹션
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
                        
                        // 북마크 추가 버튼
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
                    .padding(.horizontal)
                }

                // 시스템 상태 (개발용)
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
                            Text("히스토리: \(WebViewStateModel.globalHistory.count)개")
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

                Spacer(minLength: 50)
            }
        }
        
        // 북마크 추가 알림
        .alert("북마크 추가", isPresented: $showAddBookmarkAlert) {
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
        } message: {
            Text("새로운 북마크의 제목과 URL을 입력하세요.\n예) naver.com → https://naver.com 자동 적용")
        }
        
        // 북마크 삭제 알림
        .alert("북마크 삭제", isPresented: $showDeleteBookmarkAlert) {
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
        } message: {
            Text("'\(bookmarkToDelete?.title ?? "")' 북마크를 삭제하시겠습니까?")
        }
        
        .onChange(of: bookmarks) { _ in
            TabPersistenceManager.saveBookmarks(bookmarks)
        }
    }

    /// 북마크 아이콘 뷰
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
    let page: WebViewStateModel.HistoryEntry
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

// MARK: - TabManager: 탭 목록 관리 뷰 (기존 기능 유지)
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

                // 디버깅 로그 영역
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

                // 탭 리스트
                ScrollView {
                    ForEach(tabs) { tab in
                        HStack {
                            Button(action: {
                                if let index = tabs.firstIndex(of: tab) {
                                    onTabSelected(index)
                                    dismiss()
                                    TabPersistenceManager.debugMessages.append("탭 선택: 인덱스 \(index) (ID \(String(tab.id.uuidString.prefix(8))))")
                                    debugMessages = TabPersistenceManager.debugMessages
                                }
                            }) {
                                VStack(alignment: .leading) {
                                    Text(tab.currentURL?.host ?? "대시보드")
                                        .font(.headline)
                                    Text(tab.currentURL?.absoluteString ?? "")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    
                                    // 페이지 개수 표시
                                    Text("\(tab.historyURLs.count)개 페이지")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
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

                // 새 탭 버튼
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
                    TabPersistenceManager.debugMessages.append("새 탭 추가: ID \(String(newTab.id.uuidString.prefix(8))), 대시보드 표시")
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

            // 토스트
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
            TabPersistenceManager.debugMessages.append("탭 닫힘: ID \(String(tab.id.uuidString.prefix(8)))")
            debugMessages = TabPersistenceManager.debugMessages
        }
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

// MARK: - Collection 확장: 안전 인덱싱
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
