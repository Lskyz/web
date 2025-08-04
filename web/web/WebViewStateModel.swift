import Foundation
import Combine
import SwiftUI
import WebKit

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
                // 마지막 방문 URL을 저장하여 앱 재시작 시 복원 가능하게 함
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")

                if isRestoringSession {
                    // 세션 복원 중인 경우 방문기록 중복 방지
                    isRestoringSession = false
                } else {
                    // 앞으로 가기 중간에서 새 URL 진입 시 이후 기록 제거
                    if currentIndexInStack < historyStack.count - 1 {
                        historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
                    }

                    // 새 URL을 방문기록에 추가
                    historyStack.append(url)
                    currentIndexInStack = historyStack.count - 1

                    // 전역 방문기록(Global History)에 추가
                    addToHistory(url: url, title: "")
                }
            }
        }
    }

    // MARK: - WebView 내 앞/뒤 이동 가능 여부
    @Published var canGoBack = false
    @Published var canGoForward = false

    // MARK: - AVPlayer 관련 상태
    @Published var playerURL: URL? = nil             // 재생할 비디오 URL
    @Published var showAVPlayer = false              // 전체화면 여부

    // MARK: - 세션 복원용 임시 세션 정보
    var pendingSession: WebViewSession? = nil

    // MARK: - 내부 방문기록 스택 및 상태
    private var historyStack: [URL] = []             // 방문한 URL 목록
    private var currentIndexInStack: Int = -1        // 현재 위치 인덱스
    private var isRestoringSession: Bool = false     // 세션 복원 여부 플래그

    // MARK: - 전역 방문 기록 항목 정의
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

    // MARK: - 검색 키워드 (방문기록 검색용)
    @Published var searchKeyword: String = ""

    // MARK: - 필터링된 방문기록 리스트 반환
    var filteredHistory: [HistoryEntry] {
        let base = WebViewStateModel.globalHistory
        if searchKeyword.isEmpty {
            return base.reversed()
        } else {
            return base.filter {
                $0.title.localizedCaseInsensitiveContains(searchKeyword) ||
                $0.url.absoluteString.localizedCaseInsensitiveContains(searchKeyword)
            }.reversed()
        }
    }

    // MARK: - 전역 방문기록에 항목 추가
    func addToHistory(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title, date: Date())
        WebViewStateModel.globalHistory.append(entry)

        // 최대 1만 개까지만 유지
        if WebViewStateModel.globalHistory.count > 10000 {
            WebViewStateModel.globalHistory.removeFirst(WebViewStateModel.globalHistory.count - 10000)
        }
    }

    // MARK: - 전체 기록 삭제
    static func clearGlobalHistory() {
        globalHistory.removeAll()
        saveGlobalHistory()
    }

    // MARK: - 방문기록 저장
    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
        }
    }

    // MARK: - 방문기록 불러오기
    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
        }
    }

    // MARK: - 현재 탭의 세션 저장
    func saveSession() -> WebViewSession? {
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            return nil
        }
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    // MARK: - 세션 복원
    func restoreSession(_ session: WebViewSession) {
        isRestoringSession = true
        historyStack = session.urls
        currentIndexInStack = session.currentIndex
        pendingSession = session

        if session.urls.indices.contains(session.currentIndex) {
            currentURL = session.urls[session.currentIndex]
        } else {
            currentURL = nil
        }
    }

    // MARK: - 현재 세션의 스냅샷 URL 배열
    func historyStackIfAny() -> [URL] {
        return historyStack
    }

    func currentIndexInSafeBounds() -> Int {
        guard !historyStack.isEmpty,
              currentIndexInStack >= 0,
              currentIndexInStack < historyStack.count else {
            return 0
        }
        return currentIndexInStack
    }

    // MARK: - 외부 제어용 WebView 명령 Notification
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // MARK: - 방문기록 리스트 뷰 (내장 UI)
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

    // MARK: - 복원용 히스토리 URL 및 인덱스 (외부로부터 전달받음)
    var restoredHistoryURLs: [String] = []           // 저장된 방문 URL 문자열 배열
    var restoredHistoryIndex: Int = 0                // 복원할 위치 인덱스

    // MARK: - WKWebView 참조 (CustomWebView가 설정해야 함)
    weak var webView: WKWebView?

    // MARK: - 히스토리 복원 처리 (탭 복원 시 호출 필요)
    func prepareRestoredHistoryIfNeeded() {
        guard !restoredHistoryURLs.isEmpty,
              let webView = webView else { return }

        let urls = restoredHistoryURLs.compactMap { URL(string: $0) }
        guard urls.indices.contains(restoredHistoryIndex) else { return }

        // 순차적으로 load를 수행해 backForwardList를 push한 뒤 go(to:) 실행
        let dispatchGroup = DispatchGroup()

        for url in urls {
            dispatchGroup.enter()
            DispatchQueue.main.async {
                webView.load(URLRequest(url: url))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    dispatchGroup.leave()
                }
            }
        }

        dispatchGroup.notify(queue: .main) {
            let backList = webView.backForwardList.backList
            if backList.indices.contains(self.restoredHistoryIndex) {
                let item = backList[self.restoredHistoryIndex]
                webView.go(to: item)
            }
            // 복원 후 초기화
            self.restoredHistoryURLs = []
        }
    }

    // MARK: - 현재 웹뷰의 히스토리 상태 반환
    var historyURLs: [String] {
        guard let webView = webView else { return [] }
        let back = webView.backForwardList.backList.map { $0.url.absoluteString }
        let current = webView.backForwardList.currentItem?.url.absoluteString.map { [$0] } ?? []
        let forward = webView.backForwardList.forwardList.map { $0.url.absoluteString }
        return back + current + forward
    }

    var currentHistoryIndex: Int {
        guard let webView = webView else { return 0 }
        return webView.backForwardList.backList.count
    }
}
