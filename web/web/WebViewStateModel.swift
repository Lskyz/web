import Foundation
import Combine
import SwiftUI

// ✅ WebView의 세션을 표현하는 구조체 (탭 앞/뒤 탐색용)
struct WebViewSession: Codable {
    let urls: [URL]         // 순서대로 방문한 URL 리스트
    let currentIndex: Int   // 현재 위치 인덱스
}

// ✅ WebView의 상태를 관리하는 ViewModel
class WebViewStateModel: ObservableObject {

    // ✅ 탭 고유 식별자 (탭 간 구분용)
    var tabID: UUID? = nil

    // ✅ 현재 페이지의 URL
    @Published var currentURL: URL? = nil {
        didSet {
            if let url = currentURL {
                // 🔐 마지막 방문 페이지 저장 (앱 재시작 시 복원 가능)
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")

                // ✅ 변경됨: 탭 세션용 히스토리 스택 관리
                if isRestoringSession {
                    isRestoringSession = false  // 세션 복원 중엔 기록 안 쌓음
                } else {
                    if currentIndexInStack < historyStack.count - 1 {
                        historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
                    }
                    historyStack.append(url)
                    currentIndexInStack = historyStack.count - 1
                }
            }
        }
    }

    // ✅ 뒤로 가기 가능 여부
    @Published var canGoBack = false

    // ✅ 앞으로 가기 가능 여부
    @Published var canGoForward = false

    // ✅ AVPlayer 관련 상태
    @Published var playerURL: URL? = nil
    @Published var showAVPlayer = false

    // ✅ 복원 대기 중인 세션
    var pendingSession: WebViewSession? = nil

    // ✅ 변경됨: 탭 세션 관리용 히스토리 스택
    private var historyStack: [URL] = []
    private var currentIndexInStack: Int = -1
    private var isRestoringSession: Bool = false

    // ✅ 방문 기록 항목 정의 (전역 기록에서 사용)
    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID()
        let url: URL
        let title: String
        let date: Date
    }

    // ✅ 전역 방문 기록 저장소 (공용)
    static var globalHistory: [HistoryEntry] = [] {
        didSet {
            saveGlobalHistory()
        }
    }

    // ✅ 검색어 상태
    @Published var searchKeyword: String = ""

    // ✅ 검색 필터링 기록
    var filteredHistory: [HistoryEntry] {
        let base = WebViewStateModel.globalHistory
        if searchKeyword.isEmpty {
            return base.reversed()
        }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchKeyword) ||
            $0.url.absoluteString.localizedCaseInsensitiveContains(searchKeyword)
        }.reversed()
    }

    // ✅ 글로벌 방문 기록에 항목 추가
    func addToHistory(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title, date: Date())
        WebViewStateModel.globalHistory.append(entry)

        if WebViewStateModel.globalHistory.count > 10000 {
            WebViewStateModel.globalHistory.removeFirst(WebViewStateModel.globalHistory.count - 10000)
        }
    }

    // ✅ 전역 방문 기록 전체 삭제
    static func clearGlobalHistory() {
        globalHistory.removeAll()
        saveGlobalHistory()
    }

    // ✅ 전역 기록 저장
    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
        }
    }

    // ✅ 전역 기록 로딩
    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
        }
    }

    // ✅ 변경됨: 탭 세션 저장
    func saveSession() -> WebViewSession? {
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else { return nil }
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    // ✅ 변경됨: 탭 세션 복원
    func restoreSession(_ session: WebViewSession) {
        isRestoringSession = true
        historyStack = session.urls
        currentIndexInStack = session.currentIndex
        pendingSession = session
        currentURL = session.urls[session.currentIndex]
    }

    // ✅ WebView 제어 함수들
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // ✅ 방문기록 화면
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel

        var body: some View {
            VStack {
                TextField("방문기록 검색", text: $state.searchKeyword)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

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

        static let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        func delete(at offsets: IndexSet) {
            let items = state.filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
        }
    }
}