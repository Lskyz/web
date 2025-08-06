import SwiftUI
import AVKit
import WebKit

// MARK: - Bookmark: 북마크 데이터 모델
/// 북마크를 저장하기 위한 구조체. URL과 파비콘 URL을 포함.
/// Codable을 채택하여 UserDefaults에 저장 가능.
struct Bookmark: Codable, Identifiable, Equatable {
    let id: UUID           // 북마크 고유 식별자
    let title: String      // 북마크 표시 이름 (예: "Google")
    let url: String        // 북마크 URL
    let faviconURL: String? // 파비콘 URL (옵셔널, 없을 경우 기본 아이콘 사용)

    // Identifiable 준수를 위한 id 프로퍼티
    var idValue: UUID { id }

    // Equatable 준수를 위한 비교 연산
    static func == (lhs: Bookmark, rhs: Bookmark) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - WebTabSessionSnapshot: 탭 상태 저장/복원용 Codable 구조체
/// 브라우저 탭의 상태를 저장하고 복원하기 위한 구조체.
/// 탭의 ID와 방문 히스토리, 현재 인덱스를 저장.
struct WebTabSessionSnapshot: Codable {
    let id: String          // 탭 UUID 문자열(= WebTab.id)
    let history: [String]   // 방문한 URL 문자열 배열 (back + current + forward)
    let index: Int          // 현재 히스토리 인덱스 (= backList.count)
}

// MARK: - WebTab: 브라우저 탭 모델
/// 탭의 식별자(UUID)와 ViewModel(WebViewStateModel)을 하나로 묶는 모델.
/// 주요 기능:
/// - 생성 시 stateModel.tabID를 항상 WebTab.id와 일치시켜 SwiftUI .id(...)와 매칭.
/// - 스냅샷 저장 시 webView의 back/forward 기준으로 정확한 히스토리/인덱스 보존.
/// - 복원 전용 생성자를 통해 저장된 id/history/index로 정확히 재구성.
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel
    var playerURL: URL? = nil
    var showAVPlayer: Bool = false

    // 읽기 편의 프로퍼티(기존 기능 유지)
    var currentURL: URL? { stateModel.currentURL }
    var historyURLs: [String] { stateModel.historyURLs }
    var currentHistoryIndex: Int { stateModel.currentHistoryIndex }

    // MARK: 기본 생성자 (새 탭)
    init(url: URL? = nil) {
        let newID = UUID()
        let model = WebViewStateModel()
        model.tabID = newID             // 탭과 모델 ID를 일치
        model.currentURL = url          // 초기 URL 있으면 세팅
        self.id = newID
        self.stateModel = model
        TabPersistenceManager.debugMessages.append("새 탭 생성: ID \(id.uuidString)")
    }

    // MARK: 복원 전용 생성자
    /// 저장된 스냅샷(id/history/index)로 탭을 재구성한다.
    /// - history: 문자열 배열을 그대로 받아 내부에서 URL 배열로 변환.
    /// - index: backList 기준 인덱스.
    init(restoredID: UUID, restoredHistory: [String], restoredIndex: Int) {
        self.id = restoredID
        let model = WebViewStateModel()
        model.tabID = restoredID        // 탭과 모델 ID를 일치

        // 복원용 세션을 만들어 모델에 전달 (WKWebView는 makeUIView에서 실제 복원)
        let urls = restoredHistory.compactMap { URL(string: $0) }
        let safeIndex = max(0, min(restoredIndex, max(0, urls.count - 1)))
        if !urls.isEmpty {
            // restoreSession은 isRestoringSession 플래그/스택/현재 URL/pendingSession까지 설정
            model.restoreSession(WebViewSession(urls: urls, currentIndex: safeIndex))
        } else {
            // 히스토리 없으면 currentURL 없음(대시보드)
            model.currentURL = nil
        }

        self.stateModel = model
        TabPersistenceManager.debugMessages.append("복원 탭 생성: ID \(restoredID.uuidString), \(urls.count) URLs, 인덱스 \(safeIndex)")
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - 스냅샷 변환 (히스토리와 인덱스 정확히 저장)
    /// webView가 있으면 back/forward 리스트 기준으로, 없으면 커스텀 스택 기준으로 저장.
    func toSnapshot() -> WebTabSessionSnapshot {
        // 저장 전에 혹시라도 모델 ID가 어긋나 있으면 정렬
        alignIDsIfNeeded()

        let history = stateModel.historyStackIfAny().map { $0.absoluteString }
        let index = stateModel.currentIndexInSafeBounds()
        let snapshot = WebTabSessionSnapshot(id: id.uuidString, history: history, index: index)
        TabPersistenceManager.debugMessages.append("스냅샷 생성: ID \(id.uuidString), \(history.count) URLs, 인덱스 \(index)")
        return snapshot
    }

    /// 내부 편의: stateModel.tabID를 WebTab.id와 동기화 (저장 전에 방어)
    private func alignIDsIfNeeded() {
        if stateModel.tabID != id {
            stateModel.tabID = id
            TabPersistenceManager.debugMessages.append("ID 정렬: stateModel.tabID <- \(id.uuidString)")
        }
    }
}

// MARK: - TabPersistenceManager: 탭 저장/복원 관리
/// 탭과 북마크의 저장/복원을 관리하는 유틸리티 열거형.
enum TabPersistenceManager {
    private static let key = "savedTabs" // 탭 저장용 UserDefaults 키
    private static let bookmarkKey = "savedBookmarks" // 북마크 저장용 UserDefaults 키
    static var debugMessages: [String] = [] // 탭 관련 디버깅 메시지 (기존 코드 유지)

    // MARK: 탭 저장
    /// 현재 열려있는 모든 탭을 스냅샷으로 직렬화하여 UserDefaults에 저장.
    static func saveTabs(_ tabs: [WebTab]) {
        // 저장 직전 모든 탭의 ID 일치성을 한번 더 보장(방어)
        tabs.forEach { tab in
            if tab.stateModel.tabID != tab.id {
                tab.stateModel.tabID = tab.id
                debugMessages.append("저장 전 정렬: \(tab.id.uuidString)")
            }
        }

        let snapshots = tabs.map { $0.toSnapshot() }
        debugMessages.append("저장 시도: 탭 \(tabs.count)개, 스냅샷 요약: \(snapshots.map { "\($0.id): \($0.history.count) URLs, idx=\($0.index)" })")
        do {
            let data = try JSONEncoder().encode(snapshots)
            UserDefaults.standard.set(data, forKey: key)
            debugMessages.append("저장 성공: 데이터 크기 \(data.count) 바이트")
        } catch {
            debugMessages.append("저장 실패: 인코딩 오류 - \(error.localizedDescription)")
        }
    }

    // MARK: 탭 복원
    /// 저장된 스냅샷을 읽어 WebTab 배열로 재구성.
    static func loadTabs() -> [WebTab] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            debugMessages.append("복원 실패: UserDefaults에 데이터 없음")
            return []
        }

        debugMessages.append("복원 시도: 데이터 크기 \(data.count) 바이트")
        do {
            let snapshots = try JSONDecoder().decode([WebTabSessionSnapshot].self, from: data)
            debugMessages.append("복원 성공: \(snapshots.count)개 탭 복원")

            // 저장돼 있던 id/history/index로 정확히 탭을 복원
            let tabs: [WebTab] = snapshots.map { snap in
                let rid = UUID(uuidString: snap.id) ?? UUID()
                let hist = snap.history
                let idx = max(0, min(snap.index, max(0, hist.count - 1)))
                debugMessages.append("탭 복원 준비: ID \(rid.uuidString), URLs \(hist.count), idx \(idx)")
                let restored = WebTab(restoredID: rid, restoredHistory: hist, restoredIndex: idx)
                return restored
            }
            return tabs
        } catch {
            debugMessages.append("복원 실패: 디코딩 오류 - \(error.localizedDescription)")
            return []
        }
    }

    // MARK: 북마크 저장
    /// 북마크 리스트를 UserDefaults에 저장.
    static func saveBookmarks(_ bookmarks: [Bookmark]) {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            print("북마크 저장 실패: \(error.localizedDescription)")
        }
    }

    // MARK: 북마크 복원
    /// UserDefaults에서 북마크 리스트를 복원.
    static func loadBookmarks() -> [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            // 기본 북마크 제공 (Google, Naver)
            let defaultBookmarks = [
                Bookmark(id: UUID(), title: "Google", url: "https://www.google.com", faviconURL: "https://www.google.com/favicon.ico"),
                Bookmark(id: UUID(), title: "Naver", url: "https://www.naver.com", faviconURL: "https://www.naver.com/favicon.ico")
            ]
            saveBookmarks(defaultBookmarks) // 기본 북마크 저장
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

// MARK: - WebViewStateModel 유틸: 현재 URL이 준비되면 로드
extension WebViewStateModel {
    func loadURLIfReady() {
        if let url = currentURL, let webView = webView {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("URL 로드 시도: \(url.absoluteString)")
        } else {
            TabPersistenceManager.debugMessages.append("URL 로드 실패: WebView 또는 URL 없음")
        }
    }
}

// MARK: - DashboardView: URL 없는 탭의 홈 화면
/// URL이 없는 탭에서 표시되는 대시보드 뷰.
/// 변경 사항:
/// - 북마크를 3~4개씩 세로로 정렬 (LazyVGrid 사용).
/// - 북마크를 길게 누르면 삭제 알림 표시.
/// - 회색 배경 제거, 글자 폰트를 검정색으로 변경하고 크기 축소 (.subheadline).
/// - "+" 버튼으로 새 북마크 추가.
/// - 주소창 제거.
struct DashboardView: View {
    @State private var bookmarks: [Bookmark] = TabPersistenceManager.loadBookmarks() // 북마크 리스트
    @State private var showAddBookmarkAlert: Bool = false // 북마크 추가 알림 상태
    @State private var showDeleteBookmarkAlert: Bool = false // 북마크 삭제 알림 상태
    @State private var bookmarkToDelete: Bookmark? // 삭제할 북마크
    @State private var newBookmarkTitle: String = "" // 새 북마크 제목 입력
    @State private var inputURL: String = "" // 새 북마크 URL 입력
    let onSelectURL: (URL) -> Void // URL 선택 시 호출되는 콜백
    let triggerLoad: () -> Void // URL 로드 트리거

    // 그리드 레이아웃 설정: 3~4개씩 표시
    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20)
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("대시보드")
                .font(.largeTitle.bold())

            // 북마크 그리드 표시
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(bookmarks) { bookmark in
                        bookmarkIcon(bookmark: bookmark)
                            .onLongPressGesture {
                                bookmarkToDelete = bookmark
                                showDeleteBookmarkAlert = true // 삭제 알림 표시
                            }
                    }
                    // 북마크 추가 버튼
                    Button(action: {
                        showAddBookmarkAlert = true // 추가 알림 표시
                        newBookmarkTitle = "" // 제목 초기화
                        inputURL = "" // URL 초기화
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

            Spacer() // 주소창 제거 후 콘텐츠 아래 여백
        }
        .padding()
        // 북마크 추가 알림
        .alert("북마크 추가", isPresented: $showAddBookmarkAlert) {
            TextField("제목", text: $newBookmarkTitle)
            TextField("URL", text: $inputURL)
            Button("저장") {
                guard let url = URL(string: inputURL), !inputURL.isEmpty else { return }
                let faviconURL = url.deletingLastPathComponent().appendingPathComponent("favicon.ico").absoluteString
                let newBookmark = Bookmark(id: UUID(), title: newBookmarkTitle.isEmpty ? url.host ?? "북마크" : newBookmarkTitle, url: inputURL, faviconURL: faviconURL)
                bookmarks.append(newBookmark)
                TabPersistenceManager.saveBookmarks(bookmarks)
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("새로운 북마크의 제목과 URL을 입력하세요.")
        }
        // 북마크 삭제 알림
        .alert("북마크 삭제", isPresented: $showDeleteBookmarkAlert) {
            Button("삭제", role: .destructive) {
                if let bookmark = bookmarkToDelete, let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
                    bookmarks.remove(at: index)
                    TabPersistenceManager.saveBookmarks(bookmarks)
                }
                bookmarkToDelete = nil
            }
            Button("취소", role: .cancel) { bookmarkToDelete = nil }
        } message: {
            Text("'\(bookmarkToDelete?.title ?? "")' 북마크를 삭제하시겠습니까?")
        }
        .onChange(of: bookmarks) { _ in
            TabPersistenceManager.saveBookmarks(bookmarks) // 북마크 변경 시 저장
        }
    }

    /// 북마크 아이콘 뷰: 파비콘 이미지를 표시하거나 기본 아이콘 사용.
    private func bookmarkIcon(bookmark: Bookmark) -> some View {
        Button(action: {
            guard let url = URL(string: bookmark.url) else { return }
            onSelectURL(url) // URL 선택 콜백 호출
            triggerLoad() // 즉시 로드 트리거
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
                            .frame(width: 40, height: 40)
                    }
                } else {
                    Image(systemName: "globe")
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                Text(bookmark.title)
                    .font(.subheadline) // 폰트 크기 축소
                    .foregroundColor(.black) // 글자 색상 검정
            }
        }
    }
}

// MARK: - TabManager: 탭 목록 관리 뷰
/// 탭 목록을 표시하고 관리하는 뷰.
/// - onTabSelected는 ViewModel가 아닌 "인덱스"를 넘겨 참조 엉킴 방지.
/// - 탭 추가/삭제 시 저장 호출 유지.
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

                // 디버깅 로그 영역 (기존 코드 유지)
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
                                // 인덱스를 계산하여 콜백으로 전달
                                if let index = tabs.firstIndex(of: tab) {
                                    onTabSelected(index)
                                    dismiss()
                                    TabPersistenceManager.debugMessages.append("탭 선택: 인덱스 \(index) (ID \(tab.id.uuidString))")
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
            TabPersistenceManager.debugMessages.append("탭 닫힘: ID \(tab.id.uuidString)")
            debugMessages = TabPersistenceManager.debugMessages
        }
    }
}

// MARK: - ToastView: 알림 메시지 뷰
/// 디버깅 메시지나 상태 변화를 사용자에게 알리는 토스트 뷰.
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
/// Collection의 인덱스 접근을 안전하게 처리.
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}