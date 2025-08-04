import Foundation
import Combine
import SwiftUI
import WebKit

struct WebViewSession: Codable {
    let urls: [URL]
    let currentIndex: Int
}

class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID?
    @Published var currentURL: URL? {
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
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var playerURL: URL?
    @Published var showAVPlayer = false
    var pendingSession: WebViewSession?
    private var historyStack: [URL] = []
    private var currentIndexInStack: Int = -1
    private var isRestoringSession: Bool = false
    var restoredHistoryURLs: [String] = []
    var restoredHistoryIndex: Int = 0
    weak var webView: WKWebView?
    var onLoadCompletion: (() -> Void)?

    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID()
        let url: URL
        let title: String
        let date: Date
    }

    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }

    @Published var searchKeyword: String = ""

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

    func addToHistory(url: URL, title: String) {
        let entry = HistoryEntry(url: url, title: title, date: Date())
        WebViewStateModel.globalHistory.append(entry)
        if WebViewStateModel.globalHistory.count > 10000 {
            WebViewStateModel.globalHistory.removeFirst(WebViewStateModel.globalHistory.count - 10000)
        }
        TabPersistenceManager.debugMessages.append("방문 기록 추가: \(url.absoluteString)")
    }

    static func clearGlobalHistory() {
        globalHistory.removeAll()
        saveGlobalHistory()
        TabPersistenceManager.debugMessages.append("전역 방문 기록 삭제")
    }

    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
            TabPersistenceManager.debugMessages.append("전역 방문 기록 저장: \(globalHistory.count)개")
        }
    }

    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
            TabPersistenceManager.debugMessages.append("전역 방문 기록 로드: \(loaded.count)개")
        }
    }

    func saveSession() -> WebViewSession? {
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            TabPersistenceManager.debugMessages.append("세션 저장 실패: 히스토리 또는 인덱스 없음")
            return nil
        }
        let session = WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
        TabPersistenceManager.debugMessages.append("세션 저장: \(historyStack.count) URLs, 인덱스 \(currentIndexInStack)")
        return session
    }

    // MARK: - 세션 복원 개선
    func restoreSession(_ session: WebViewSession) {
        isRestoringSession = true
        historyStack = session.urls
        currentIndexInStack = max(0, min(session.currentIndex, session.urls.count - 1)) // 인덱스 범위 제한
        pendingSession = session
        if session.urls.indices.contains(currentIndexInStack) {
            currentURL = session.urls[currentIndexInStack]
            TabPersistenceManager.debugMessages.append("세션 복원: URL \(currentURL?.absoluteString ?? "없음"), 인덱스 \(currentIndexInStack)")
        } else {
            currentURL = nil
            TabPersistenceManager.debugMessages.append("세션 복원 실패: 유효한 인덱스 없음")
        }
        // 복원 후 즉시 히스토리 준비
        if !restoredHistoryURLs.isEmpty {
            prepareRestoredHistoryIfNeeded()
        }
    }

    // MARK: - 히스토리 복원 개선
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
        for (index, url) in urls.enumerated() {
            dispatchGroup.enter()
            webView.load(URLRequest(url: url))
            onLoadCompletion = {
                TabPersistenceManager.debugMessages.append("히스토리 URL 로드 완료: \(url)")
                dispatchGroup.leave()
                // 마지막 URL 로드 후 인덱스로 이동
                if index == urls.count - 1 {
                    DispatchQueue.main.async {
                        let backList = webView.backForwardList.backList
                        if backList.indices.contains(self.restoredHistoryIndex) {
                            webView.go(to: backList[self.restoredHistoryIndex])
                            TabPersistenceManager.debugMessages.append("히스토리 복원 완료: \(webView.url?.absoluteString ?? "없음")")
                        } else {
                            TabPersistenceManager.debugMessages.append("히스토리 복원 실패: backList 인덱스 범위 초과")
                        }
                        self.restoredHistoryURLs = []
                        self.restoredHistoryIndex = 0
                    }
                }
            }
        }
    }

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

    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

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
