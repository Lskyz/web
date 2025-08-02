import Foundation
import Combine
import SwiftUI

// ✅ WebView의 상태를 관리하는 ViewModel
class WebViewStateModel: ObservableObject {

    // ✅ 방문 기록 항목 구조: URL + 제목 + 날짜
    struct VisitRecord: Identifiable, Codable {
        let id = UUID()
        let url: URL
        let title: String
        let date: Date
    }

    // ✅ 현재 페이지의 URL. 값이 바뀌면 방문기록 저장 트리거
    @Published var currentURL: URL? = nil {
        didSet {
            if let url = currentURL {
                // UserDefaults에 마지막 URL 저장 (앱 재시작 복원용)
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")

                // 타이틀은 아직 연동 안 됐으므로 임시값으로 저장
                addToHistory(url: url, title: "제목 없음")
            }
        }
    }

    // ✅ 앞으로 가기 / 뒤로 가기 가능 여부
    @Published var canGoBack = false
    @Published var canGoForward = false

    // ✅ 영상 재생용 AVPlayer 관련 상태
    @Published var playerURL: URL? = nil
    @Published var showAVPlayer = false

    // ✅ 전체 방문 기록 (최신순 정렬)
    @Published var history: [VisitRecord] = [] {
        didSet {
            saveHistoryToDisk()
        }
    }

    // ✅ 현재 검색어에 따른 필터링된 방문기록
    @Published var searchQuery: String = ""

    // ✅ 필터링된 검색 결과
    var filteredHistory: [VisitRecord] {
        if searchQuery.isEmpty {
            return history.sorted(by: { $0.date > $1.date })
        } else {
            return history.filter {
                $0.url.absoluteString.localizedCaseInsensitiveContains(searchQuery) ||
                $0.title.localizedCaseInsensitiveContains(searchQuery)
            }.sorted(by: { $0.date > $1.date })
        }
    }

    // ✅ 방문기록 추가 함수 (title은 추후 연결)
    func addToHistory(url: URL, title: String) {
        let newEntry = VisitRecord(url: url, title: title, date: Date())

        // 중복 URL은 제거 (같은 URL 여러번 기록되면 하나로 대체)
        history.removeAll { $0.url == url }

        // 최신순으로 추가
        history.append(newEntry)

        // 용량 체크 후 오래된 기록 제거
        trimHistoryIfNeeded()
    }

    // ✅ 방문기록 전체 삭제
    func clearHistory() {
        history.removeAll()
    }

    // ✅ 오래된 기록 제거 (총 기록 1GB 제한 기준)
    private func trimHistoryIfNeeded() {
        // JSON 저장 시 대략적인 사이즈 추정 (실제 사용시 더 정밀화 가능)
        let estimatedSize = estimateHistorySize()
        let maxSize: Int = 1_000_000_000 // 1GB

        while estimatedSize > maxSize, !history.isEmpty {
            history.removeFirst()
        }
    }

    // ✅ 전체 기록 용량을 추정하는 함수
    private func estimateHistorySize() -> Int {
        do {
            let data = try JSONEncoder().encode(history)
            return data.count
        } catch {
            return 0
        }
    }

    // ✅ 방문기록 로컬에 저장
    private func saveHistoryToDisk() {
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: historyFileURL(), options: .atomic)
        } catch {
            print("⚠️ 방문기록 저장 실패: \(error)")
        }
    }

    // ✅ 방문기록 디스크에서 불러오기
    func loadHistoryFromDisk() {
        do {
            let data = try Data(contentsOf: historyFileURL())
            let decoded = try JSONDecoder().decode([VisitRecord].self, from: data)
            self.history = decoded
        } catch {
            print("⚠️ 방문기록 로드 실패: \(error)")
        }
    }

    // ✅ 파일 저장 경로
    private func historyFileURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("visitHistory.json")
    }

    // ✅ WebView 제어용 트리거
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // ✅ 방문기록 페이지 View (ContentView에서 NavigationLink로 접근)
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel

        var body: some View {
            VStack {
                // 🔍 검색 필드
                TextField("방문기록 검색", text: $state.searchQuery)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()

                // 📜 방문 기록 목록
                List {
                    ForEach(state.filteredHistory) { item in
                        Button(action: {
                            state.currentURL = item.url
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title.isEmpty ? "(제목 없음)" : item.title)
                                    .font(.headline)
                                Text(item.url.absoluteString)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text(item.date.formatted())
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: delete)
                }

                // 🗑️ 전체 삭제 버튼
                Button(role: .destructive) {
                    state.clearHistory()
                } label: {
                    Label("기록 전체 삭제", systemImage: "trash")
                        .padding()
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("방문 기록")
        }

        func delete(at offsets: IndexSet) {
            state.history.remove(atOffsets: offsets)
        }
    }
}