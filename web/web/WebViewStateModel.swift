import Foundation                 // 기본적인 데이터 타입 및 시스템 기능 제공
import Combine                   // @Published와 같은 퍼블리셔 사용을 위해 필요
import SwiftUI                   // SwiftUI 뷰와 관련 기능 사용

// ✅ WebView의 상태를 관리하는 ViewModel
class WebViewStateModel: ObservableObject {

    // ✅ 현재 페이지의 URL을 나타냄 (URL 이동 시 변경됨)
    @Published var currentURL: URL? = nil {
        didSet {
            if let url = currentURL {
                // 🔐 마지막 방문 페이지 저장 (앱 재시작 시 복원 가능)
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
                // ⚠️ 실제 방문기록 등록은 웹 타이틀 수신 후 처리됨 (CustomWebView 쪽에서)
            }
        }
    }

    // ✅ 뒤로 가기 가능 여부 (WebView에서 상태 업데이트 필요)
    @Published var canGoBack = false

    // ✅ 앞으로 가기 가능 여부 (WebView에서 상태 업데이트 필요)
    @Published var canGoForward = false

    // ✅ AVPlayer에서 재생할 비디오 URL (감지하여 AVPlayer 띄움)
    @Published var playerURL: URL? = nil

    // ✅ AVPlayer 전체화면 표시 여부 (true면 AVPlayerView가 나타남)
    @Published var showAVPlayer = false

    // ✅ 방문 기록 항목 구조체 (URL, 제목, 시각 포함)
    struct HistoryEntry: Identifiable, Hashable, Codable {
        let id = UUID()               // 고유 ID (List 구분용)
        let url: URL                  // 방문한 페이지의 URL
        let title: String             // 페이지 제목
        let date: Date                // 방문한 시간
    }

    // ✅ 전체 방문기록 (최신 항목이 마지막에 위치)
    @Published var history: [HistoryEntry] = []

    // ✅ 방문기록 검색용 키워드 (검색창에서 입력됨)
    @Published var searchKeyword: String = ""

    // ✅ 필터링된 방문기록 (검색어로 필터링, 최신순 정렬)
    var filteredHistory: [HistoryEntry] {
        if searchKeyword.isEmpty {
            return history.reversed()    // 검색어 없으면 전체 기록 역순 반환
        }
        return history.filter {
            // 제목 또는 URL에 검색어가 포함되었는지 검사
            $0.title.localizedCaseInsensitiveContains(searchKeyword) ||
            $0.url.absoluteString.localizedCaseInsensitiveContains(searchKeyword)
        }.reversed()
    }

    // ✅ 전역(모든 탭) 방문기록 저장소 (앱 전체 공유)
    static var globalHistory: [HistoryEntry] = [] {
        didSet {
            saveGlobalHistory() // 변경될 때마다 자동 저장
        }
    }

    // ✅ 방문기록에 새 항목 추가 (중복 제거 후 삽입)
    func addToHistory(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title, date: Date())

        // 📌 개인 기록 추가 (중복 URL 제거)
        history.removeAll { $0.url == url }
        history.append(entry)

        // 📌 전역 기록 추가 (중복 URL 제거)
        WebViewStateModel.globalHistory.removeAll { $0.url == url }
        WebViewStateModel.globalHistory.append(entry)

        // 🔒 용량 제한 (예: 1만개까지만 유지)
        if history.count > 10000 {
            history.removeFirst(history.count - 10000)
        }
        if WebViewStateModel.globalHistory.count > 10000 {
            WebViewStateModel.globalHistory.removeFirst(WebViewStateModel.globalHistory.count - 10000)
        }
    }

    // ✅ WebView에게 "뒤로 가기" 요청 알림 전송
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    // ✅ WebView에게 "앞으로 가기" 요청 알림 전송
    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    // ✅ WebView에게 "새로고침" 요청 알림 전송
    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // ✅ 방문기록 전체 삭제 (기록 배열 초기화)
    func clearAllHistory() {
        history.removeAll()
    }

    // ✅ 전역 방문기록 전체 삭제 (정적 함수)
    static func clearGlobalHistory() {
        globalHistory.removeAll()
        saveGlobalHistory()
    }

    // ✅ 전역 기록 저장 (UserDefaults에 JSON 인코딩)
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

    // ✅ 방문기록을 보여주는 별도 화면 (List 기반)
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel  // 외부 상태를 관찰

        var body: some View {
            VStack {
                // 🔍 검색창 (키워드 입력 시 필터링 동작)
                TextField("방문기록 검색", text: $state.searchKeyword)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                // 📜 방문기록 리스트
                List {
                    ForEach(state.filteredHistory) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Button(action: {
                                // 기록 선택 시 해당 URL로 이동
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
                    .onDelete(perform: delete) // 스와이프 삭제 지원
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
            .navigationTitle("방문 기록") // 상단 제목
        }

        // ✅ 날짜/시간 포맷 (YYYY.MM.DD HH:mm)
        static let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        // ✅ 리스트 항목 삭제 함수
        func delete(at offsets: IndexSet) {
            let items = state.filteredHistory           // 현재 필터링된 기록
            let targets = offsets.map { items[$0] }     // 삭제 대상들
            state.history.removeAll { targets.contains($0) } // 기록에서 제거
        }
    }
}