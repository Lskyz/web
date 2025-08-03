import Foundation
import Combine
import SwiftUI

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
            }
        }
    }

    // ✅ 뒤로 가기 가능 여부 (WebView에서 상태 업데이트)
    @Published var canGoBack = false

    // ✅ 앞으로 가기 가능 여부
    @Published var canGoForward = false

    // ✅ AVPlayer 관련 상태 (비디오 URL & 전체화면 여부)
    @Published var playerURL: URL? = nil
    @Published var showAVPlayer = false

    // ✅ 방문 기록 항목 정의 (전역 기록에서 사용)
    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID()               // 고유 ID
        let url: URL                  // 방문한 URL
        let title: String             // 페이지 제목
        let date: Date                // 방문 시각
    }

    // ✅ 전역 방문 기록 저장소 (모든 탭 공유)
    static var globalHistory: [HistoryEntry] = [] {
        didSet {
            saveGlobalHistory() // 변경될 때마다 자동 저장
        }
    }

    // ✅ 검색어 상태
    @Published var searchKeyword: String = ""

    // ✅ 필터링된 방문 기록 (검색 및 최신순 정렬)
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

    // ✅ 방문 기록에 새 항목 추가 (중복 제거 후 저장)
    func addToHistory(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title, date: Date())

        // 기존 동일 URL 제거
        WebViewStateModel.globalHistory.removeAll { $0.url == url }

        // 새 항목 추가
        WebViewStateModel.globalHistory.append(entry)

        // 🔒 최대 저장 개수 제한
        if WebViewStateModel.globalHistory.count > 10000 {
            WebViewStateModel.globalHistory.removeFirst(WebViewStateModel.globalHistory.count - 10000)
        }
    }

    // ✅ 전역 기록 전체 삭제
    static func clearGlobalHistory() {
        globalHistory.removeAll()
        saveGlobalHistory()
    }

    // ✅ UserDefaults에 전역 기록 저장
    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
        }
    }

    // ✅ 앱 시작 시 전역 기록 복원
    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
        }
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

    // ✅ 방문 기록 화면
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel

        var body: some View {
            VStack {
                // 🔍 검색창
                TextField("방문기록 검색", text: $state.searchKeyword)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                // 📜 기록 리스트
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

                // 🗑 전체 삭제 버튼
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

        // ✅ 날짜 포맷
        static let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        // ✅ 기록 항목 삭제
        func delete(at offsets: IndexSet) {
            let items = state.filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
        }
    }
}