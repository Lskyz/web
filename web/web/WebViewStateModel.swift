import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - WebViewSession: 탭 단위 세션 저장용
struct WebViewSession: Codable {
    let urls: [URL] // 방문한 URL 목록
    let currentIndex: Int // 현재 페이지 인덱스
}

// MARK: - WebViewStateModel: WebView 상태 관리
class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID? // 탭 고유 ID
    @Published var currentURL: URL? { // 현재 로드된 URL
        didSet {
            if let url = currentURL {
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
                TabPersistenceManager.debugMessages.append("URL 업데이트: \(url.absoluteString)")
                if isRestoringSession {
                    isRestoringSession = false
                } else {
                    if currentIndexInStack < historyStack.count - 1 {
                        historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
                    }
                    historyStack.append(url)
                    currentIndexInStack = historyStack.count - 1
                    addToHistory(url: url, title: "")
                }
            }
        }
    }
    @Published var canGoBack = false // 뒤로가기 가능 여부
    @Published var canGoForward = false // 앞으로가기 가능 여부
    @Published var playerURL: URL? // 비디오 재생 URL
    @Published var showAVPlayer = false // AVPlayer 전체화면 여부
    var pendingSession: WebViewSession? // 세션 복원용 임시 데이터
    private var historyStack: [URL] = [] // 내부 히스토리 스택
    private var currentIndexInStack: Int = -1 // 현재 히스토리 인덱스
    private var isRestoringSession: Bool = false // 세션 복원 플래그
    var restoredHistoryURLs: [String] = [] // 복원용 히스토리 URL
    var restoredHistoryIndex: Int = 0 // 복원용 히스토리 인덱스
    weak var webView: WKWebView? // WKWebView 참조
    var onLoadCompletion: (() -> Void)? // URL 로드 완료 콜백

    // MARK: - 전역 방문 기록 항목
    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID()
        let url: URL
        let title: String
        let date: Date
    }

    static var globalHistory: [HistoryEntry] = [] { // 전역 방문 기록
        didSet {
            saveGlobalHistory()
        }
    }

    @Published var searchKeyword: String = "" // 방문 기록 검색 키워드

    var filteredHistory: [HistoryEntry] { // 필터링된 방문 기록
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

    // MARK: - 전역 방문 기록 추가
    func addToHistory(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title, date: Date())
        WebViewStateModel.globalHistory.append(entry)
        if WebViewStateModel.globalHistory.count > 10000 {
            WebViewStateModel.globalHistory.removeFirst(WebViewStateModel.globalHistory.count - 10000)
        }
        TabPersistenceManager.debugMessages.append("방문 기록 추가: \(url.absoluteString)")
    }

    // MARK: - 전역 방문 기록 초기화
    static func clearGlobalHistory() {
        globalHistory.removeAll()
        saveGlobalHistory()
        TabPersistenceManager.debugMessages.append("전역 방문 기록 삭제")
    }

    // MARK: - 전역 방문 기록 저장
    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
            TabPersistenceManager.debugMessages.append("전역 방문 기록 저장: \(globalHistory.count)개")
        }
    }

    // MARK: - 전역 방문 기록 로드
    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
            TabPersistenceManager.debugMessages.append("전역 방문 기록 로드: \(loaded.count)개")
        }
    }

    // MARK: - 현재 탭 세션 저장
    func saveSession() -> WebViewSession? {
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            TabPersistenceManager.debugMessages.append("세션 저장 실패: 히스토리 또는 인덱스 없음")
            return nil
        }
        let session = WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
        TabPersistenceManager.debugMessages.append("세션 저장: \(historyStack.count) URLs, 인덱스 \(currentIndexInStack)")
        return session
    }

    // MARK: - 세션 복원
    func restoreSession(_ session: WebViewSession) {
        isRestoringSession = true
        historyStack = session.urls
        currentIndexInStack = session.currentIndex
        pendingSession = session
        if session.urls.indices.contains(session.currentIndex) {
            currentURL = session.urls[session.currentIndex]
            TabPersistenceManager.debugMessages.append("세션 복원: URL \(currentURL?.absoluteString ?? "없음")")
        } else {
            currentURL = nil
            TabPersistenceManager.debugMessages.append("세션 복원 실패: 인덱스 범위 초과")
        }
    }

    // MARK: - 히스토리 복원
    func prepareRestoredHistoryIfNeeded() {
        guard !restoredHistoryURLs.isEmpty, let webView = webView else {
            TabPersistenceManager.debugMessages.append("히스토리 복원 실패: URL 없음 또는 webView 없음")
            return
        }

        let urls = restoredHistoryURLs.compactMap { urlString -> URL? in
            if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
                return url
            }
            TabPersistenceManager.debugMessages.append("유효하지 않은 URL: \(urlString)")
            return nil
        }
        TabPersistenceManager.debugMessages.append("히스토리 복원 시도: \(urls.count) URLs, 인덱스 \(restoredHistoryIndex)")

        guard urls.indices.contains(restoredHistoryIndex) else {
            TabPersistenceManager.debugMessages.append("히스토리 복원 실패: 인덱스 범위 초과")
            return
        }

        let dispatchGroup = DispatchGroup()
        for url in urls {
            dispatchGroup.enter()
            webView.load(URLRequest(url: url))
            (webView.navigationDelegate as? WebViewStateModel)?.onLoadCompletion = {
                TabPersistenceManager.debugMessages.append("히스토리 URL 로드 완료: \(url)")
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            let backList = webView.backForwardList.backList
            if backList.indices.contains(self.restoredHistoryIndex) {
                webView.go(to: backList[self.restoredHistoryIndex])
                TabPersistenceManager.debugMessages.append("히스토리 복원 완료: \(webView.url?.absoluteString ?? "없음")")
            } else {
                TabPersistenceManager.debugMessages.append("히스토리 복원 실패: backList 인덱스 범위 초과")
            }
            self.restoredHistoryURLs = []
        }
    }

    // MARK: - 현재 웹뷰 히스토리 상태
    var historyURLs: [String] {
        guard let webView = webView else {
            TabPersistenceManager.debugMessages.append("히스토리 URL 반환 실패: webView 없음")
            return []
        }
        let back = webView.backForwardList.backList.map { $0.url.absoluteString }
        let current = webView.backForwardList.currentItem.map { [$0.url.absoluteString] } ?? []
        let forward = webView.backForwardList.forwardList.map { $0.url.absoluteString }
        return back + current + forward
    }

    var currentHistoryIndex: Int {
        guard let webView = webView else {
            TabPersistenceManager.debugMessages.append("현재 히스토리 인덱스 반환 실패: webView 없음")
            return 0
        }
        return webView.backForwardList.backList.count
    }

    // MARK: - 히스토리 스택 반환
    func historyStackIfAny() -> [URL] {
        return historyStack
    }

    // MARK: - 안전한 인덱스 반환
    func currentIndexInSafeBounds() -> Int {
        guard !historyStack.isEmpty,
              currentIndexInStack >= 0,
              currentIndexInStack < historyStack.count else {
            return 0
        }
        return currentIndexInStack
    }

    // MARK: - WebView 제어 (Notification 기반)
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // MARK: - WKNavigationDelegate 메서드
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
        let title = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "제목 없음")
        if let finalURL = webView.url {
            addToHistory(url: finalURL, title: title)
        }
        TabPersistenceManager.debugMessages.append("페이지 로드 완료: \(webView.url?.absoluteString ?? "없음")")
        onLoadCompletion?()
        onLoadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        TabPersistenceManager.debugMessages.append("로드 실패 (Provisional): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        TabPersistenceManager.debugMessages.append("로드 실패 (Navigation): \(error.localizedDescription)")
    }

    // MARK: - 방문 기록 뷰
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
                                TabPersistenceManager.debugMessages.append("방문 기록에서 URL 선택: \(entry.url)")
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
            TabPersistenceManager.debugMessages.append("방문 기록 삭제: \(targets.count)개")
        }
    }
}
