import Foundation
import Combine
import SwiftUI

// MARK: - WebView 내 방문기록 저장을 위한 구조체 (탭 단위 세션 기록용)
struct WebViewSession: Codable {
    let urls: [URL]           // 사용자가 방문한 URL 목록
    let currentIndex: Int     // 현재 위치한 페이지 인덱스
}

// MARK: - WebView 상태 및 동작을 관리하는 ViewModel
class WebViewStateModel: ObservableObject {

    // MARK: - 탭 구분용 고유 ID (복원 및 식별용)
    var tabID: UUID? = nil

    // MARK: - 현재 WebView에 로드된 URL
    @Published var currentURL: URL? = nil {
        didSet {
            if let url = currentURL {
                // ✅ 마지막 방문 URL 저장 (앱 재시작 시 활용 가능)
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")

                if isRestoringSession {
                    // ✅ 세션 복원 중일 경우 방문기록 중복 방지
                    isRestoringSession = false
                } else {
                    // ✅ 앞으로 가기 중간에서 새 URL 진입 시 이후 기록 제거
                    if currentIndexInStack < historyStack.count - 1 {
                        historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
                    }

                    // ✅ 새 URL을 방문기록 스택에 추가
                    historyStack.append(url)
                    currentIndexInStack = historyStack.count - 1

                    // ✅ 전역 방문 기록(Global History)에 추가
                    addToHistory(url: url, title: "")
                }
            }
        }
    }

    // MARK: - WebView 내 앞/뒤 이동 가능 여부
    @Published var canGoBack = false
    @Published var canGoForward = false

    // MARK: - AVPlayer 관련 상태 (비디오 재생)
    @Published var playerURL: URL? = nil             // 재생할 비디오 URL
    @Published var showAVPlayer = false              // 전체화면 여부

    // MARK: - 세션 복원용 임시 데이터 저장소
    var pendingSession: WebViewSession? = nil

    // MARK: - 내부 방문기록 스택 (탭 별 저장)
    private var historyStack: [URL] = []             // 방문한 URL 목록
    private var currentIndexInStack: Int = -1        // 현재 위치 인덱스
    private var isRestoringSession: Bool = false     // 세션 복원 여부 플래그

    // MARK: - 전역 방문 기록 항목 정의 (공용 저장용)
    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID()
        let url: URL
        let title: String
        let date: Date
    }

    // MARK: - 전체 앱에서 공유되는 방문기록
    static var globalHistory: [HistoryEntry] = [] {
        didSet {
            saveGlobalHistory()
        }
    }

    // MARK: - 방문기록 검색 필드 (검색어 바인딩용)
    @Published var searchKeyword: String = ""

    // MARK: - 검색된 방문기록 반환
    var filteredHistory: [HistoryEntry] {
        let base = WebViewStateModel.globalHistory
        if searchKeyword.isEmpty {
            return base.reversed()  // 기본 최신순 정렬
        } else {
            return base.filter {
                $0.title.localizedCaseInsensitiveContains(searchKeyword) ||
                $0.url.absoluteString.localizedCaseInsensitiveContains(searchKeyword)
            }.reversed()
        }
    }

    // MARK: - 전역 방문기록에 새 항목 추가
    func addToHistory(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title, date: Date())
        WebViewStateModel.globalHistory.append(entry)

        // ✅ 기록은 최대 1만 개까지만 유지
        if WebViewStateModel.globalHistory.count > 10000 {
            WebViewStateModel.globalHistory.removeFirst(WebViewStateModel.globalHistory.count - 10000)
        }
    }

    // MARK: - 전역 방문기록 초기화
    static func clearGlobalHistory() {
        globalHistory.removeAll()
        saveGlobalHistory()
    }

    // MARK: - 방문기록을 UserDefaults에 저장
    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
        }
    }

    // MARK: - UserDefaults로부터 기록 불러오기
    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
        }
    }

    // MARK: - 현재 탭의 세션 저장 (방문 URL과 인덱스 반환)
    func saveSession() -> WebViewSession? {
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            return nil
        }
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    // MARK: - 세션 복원 로직
    func restoreSession(_ session: WebViewSession) {
        isRestoringSession = true
        historyStack = session.urls
        currentIndexInStack = session.currentIndex
        pendingSession = session

        // ✅ 현재 인덱스에 해당하는 URL을 로딩 트리거로 지정
        if session.urls.indices.contains(session.currentIndex) {
            currentURL = session.urls[session.currentIndex]
        } else {
            currentURL = nil // 대시보드 표시 가능
        }
    }

    // MARK: - WebView 제어용 외부 호출 함수 (Notification 기반)
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // MARK: - 방문기록 UI 페이지 (내장형 뷰)
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel

        var body: some View {
            VStack {
                // 🔍 검색 필드
                TextField("방문기록 검색", text: $state.searchKeyword)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                // 📜 필터링된 방문기록 리스트
                List {
                    ForEach(state.filteredHistory) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Button(action: {
                                state.currentURL = entry.url // ✅ 클릭 시 URL 로딩
                            }) {
                                Text(entry.title.isEmpty ? "제목 없음" : entry.title)
                                    .font(.headline)
                                    .lineLimit(1)

                                Text(entry.url.absoluteString)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)

                                Text(Self.dateFormatter.string(from: entry.date))
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: delete)
                }

                // 🗑 전체 기록 삭제 버튼
                Button(action: {
                    WebViewStateModel.clearGlobalHistory()
                }) {
                    Label("전체 기록 삭제", systemImage: "trash")
                        .foregroundColor(.red)
                }
                .padding()
            }
            .navigationTitle("방문 기록")
        }

        // 📅 날짜 포맷 정의
        static let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        // 🧹 항목 개별 삭제 처리
        func delete(at offsets: IndexSet) {
            let items = state.filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
        }
    }
}