import Foundation
import Combine
import SwiftUI

// ✅ WebView의 상태를 관리하는 ViewModel
class WebViewStateModel: ObservableObject {
    
    // ✅ 현재 페이지의 URL을 나타냄
    @Published var currentURL: URL? = nil {
        didSet {
            if let url = currentURL {
                // 마지막 방문 페이지 저장 (앱 재실행 시 복원용)
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
                // ⚠️ 방문 기록은 title 수신 후 CustomWebView에서 처리됨
            }
        }
    }
    
    // ✅ WebView의 '뒤로 가기' 가능 여부
    @Published var canGoBack = false
    
    // ✅ WebView의 '앞으로 가기' 가능 여부
    @Published var canGoForward = false
    
    // ✅ AVPlayer로 재생할 영상의 URL
    @Published var playerURL: URL? = nil
    
    // ✅ AVPlayer를 전체화면으로 표시할지 여부
    @Published var showAVPlayer = false

    // ✅ 방문기록 항목 정의 (title 포함)
    struct HistoryEntry: Identifiable, Hashable {
        let id = UUID()               // 고유 ID
        let url: URL                  // 방문한 URL
        let title: String             // 페이지 제목
        let date: Date               // 방문 시각
    }

    // ✅ 전체 방문기록 배열 (최신순)
    @Published var history: [HistoryEntry] = []

    // ✅ 검색 키워드 필터링용
    @Published var searchKeyword: String = ""

    // ✅ 필터링된 방문기록 (검색어 기반)
    var filteredHistory: [HistoryEntry] {
        if searchKeyword.isEmpty {
            return history.reversed()
        }
        return history.filter {
            $0.title.localizedCaseInsensitiveContains(searchKeyword) ||
            $0.url.absoluteString.localizedCaseInsensitiveContains(searchKeyword)
        }.reversed()
    }

    // ✅ 방문 기록에 항목 추가 (중복 URL 제거 후 재삽입)
    func addToHistory(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title, date: Date())

        // 기존에 동일 URL이 있으면 제거
        history.removeAll { $0.url == url }

        history.append(entry)

        // 🔒 용량 제한 (예: 최대 1GB → 항목 수 기준으로 예시: 10000개)
        if history.count > 10000 {
            history.removeFirst(history.count - 10000)
        }
    }

    // ✅ WebView 뒤로가기 동작을 트리거
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    // ✅ WebView 앞으로가기 동작을 트리거
    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    // ✅ WebView 새로고침 동작을 트리거
    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // ✅ 전체 방문기록 삭제
    func clearAllHistory() {
        history.removeAll()
    }

    // ✅ 방문기록을 보여주는 별도 페이지 (ContentView에서 NavigationLink로 호출)
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
                    state.clearAllHistory()
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

        // ✅ 리스트에서 항목 삭제 기능
        func delete(at offsets: IndexSet) {
            let items = state.filteredHistory
            let targets = offsets.map { items[$0] }
            state.history.removeAll { targets.contains($0) }
        }
    }
}

// ✅ WebViewStateModel의 값을 다른 모델로부터 복사
class WebViewStateModel: ObservableObject {
    @Published var currentURL: URL?
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var playerURL: URL?
    @Published var showAVPlayer: Bool = false
    @Published var history: [(url: URL, title: String)] = []

    @Published var pageTitle: String = "로딩 중…" // ✅ 현재 페이지 제목 캐시

    func addToHistory(url: URL, title: String) {
        history.append((url, title))
        pageTitle = title  // ✅ 캐시 업데이트
    }

    // ...기타 로직
}