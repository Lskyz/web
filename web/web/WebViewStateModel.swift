import Foundation
import Combine
import SwiftUI

// MARK: - 세션 저장을 위한 구조체 (탭 내의 앞/뒤 방문 기록용)
struct WebViewSession: Codable {
    let urls: [URL]           // 사용자가 방문한 URL 목록
    let currentIndex: Int     // 현재 페이지가 위치한 인덱스
}

// MARK: - WebView 상태를 관리하는 뷰모델
class WebViewStateModel: ObservableObject {

    // MARK: - 탭 관련 식별 정보
    var tabID: UUID? = nil    // 각 탭의 고유 식별자 (탭 간 구분용)

    // MARK: - 현재 로드 중인 페이지의 URL
    @Published var currentURL: URL? = nil {
        didSet {
            if let url = currentURL {
                // ✅ 앱 종료 시 복원을 위한 마지막 URL 저장
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")

                if isRestoringSession {
                    // ✅ 세션 복원 중인 경우에는 방문 기록 누락 방지
                    isRestoringSession = false
                } else {
                    // ✅ 앞으로 가기 도중 새 URL 진입 시 스택 정리
                    if currentIndexInStack < historyStack.count - 1 {
                        historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
                    }

                    // ✅ 방문한 URL을 히스토리 스택에 추가
                    historyStack.append(url)
                    currentIndexInStack = historyStack.count - 1

                    // ✅ 전역 방문 기록(Global History)에 추가
                    addToHistory(url: url, title: "")
                }
            }
        }
    }

    // MARK: - 앞/뒤 이동 상태
    @Published var canGoBack = false
    @Published var canGoForward = false

    // MARK: - AVPlayer 재생 상태 (전체화면 재생용)
    @Published var playerURL: URL? = nil
    @Published var showAVPlayer = false

    // MARK: - 복원 대기 세션 정보
    var pendingSession: WebViewSession? = nil

    // MARK: - 내부 히스토리 스택
    private var historyStack: [URL] = []        // 방문 URL 스택
    private var currentIndexInStack: Int = -1   // 현재 인덱스
    private var isRestoringSession: Bool = false // 세션 복원 중인지 여부

    // MARK: - 전역 방문 기록 항목 정의
    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID()        // 유일 식별자
        let url: URL           // 방문한 URL
        let title: String      // 페이지 제목 (현재는 빈 값)
        let date: Date         // 방문 시각
    }

    // MARK: - 전역 방문 기록 저장소 (모든 탭 공용)
    static var globalHistory: [HistoryEntry] = [] {
        didSet {
            saveGlobalHistory()
        }
    }

    // MARK: - 방문기록 검색 필드 (UI 연동용)
    @Published var searchKeyword: String = ""

    // MARK: - 필터링된 방문 기록 리스트
    var filteredHistory: [HistoryEntry] {
        let base = WebViewStateModel.globalHistory
        if searchKeyword.isEmpty {
            return base.reversed() // 최신순
        }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchKeyword) ||
            $0.url.absoluteString.localizedCaseInsensitiveContains(searchKeyword)
        }.reversed()
    }

    // MARK: - 전역 방문 기록에 새로운 항목 추가
    func addToHistory(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title, date: Date())
        WebViewStateModel.globalHistory.append(entry)

        // ✅ 최대 개수 제한 (1만 개)
        if WebViewStateModel.globalHistory.count > 10000 {
            WebViewStateModel.globalHistory.removeFirst(WebViewStateModel.globalHistory.count - 10000)
        }
    }

    // MARK: - 전역 방문 기록 삭제 (전체 초기화)
    static func clearGlobalHistory() {
        globalHistory.removeAll()
        saveGlobalHistory()
    }

    // MARK: - 전역 방문 기록 저장 (UserDefaults)
    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
        }
    }

    // MARK: - 전역 방문 기록 로딩
    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
        }
    }

    // MARK: - 현재 탭 세션 저장
    func saveSession() -> WebViewSession? {
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else { return nil }
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    // MARK: - 세션 복원
    func restoreSession(_ session: WebViewSession) {
        isRestoringSession = true
        historyStack = session.urls
        currentIndexInStack = session.currentIndex
        pendingSession = session
        currentURL = session.urls[session.currentIndex] // 복원 트리거
    }

    // MARK: - WebView 제어 함수들 (Notification 기반)
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // MARK: - 방문 기록 화면 (UI)
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel

        var body: some View {
            VStack {
                // 🔍 검색 필드
                TextField("방문기록 검색", text: $state.searchKeyword)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                // 📜 방문 기록 리스트
                List {
                    ForEach(state.filteredHistory) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Button(action: {
                                state.currentURL = entry.url
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

                // 🗑 전체 기록 삭제
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

        // ✅ 날짜 포맷터
        static let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        // ✅ 삭제 처리
        func delete(at offsets: IndexSet) {
            let items = state.filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
        }
    }
}