import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 세션 스냅샷 (저장/복원에 사용)
struct WebViewSession: Codable {
    let urls: [URL]       // 히스토리 전체 (back + current + forward)
    let currentIndex: Int // 현재 위치(= backList.count)
}

// MARK: - WebViewStateModel
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {

    // 탭 식별자 (외부에서 셋)
    var tabID: UUID?

    // MARK: 상태 바인딩
    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }
            // 마지막 URL 메모
            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            TabPersistenceManager.debugMessages.append("URL 업데이트: \(url.absoluteString)")

            // 🛠 [수정] 복원 중엔 커스텀 히스토리/전역 방문기록에 손대지 않음
            //  - 이전 코드: 여기서 isRestoringSession = false 로 내려버려서
            //    순차 로드 도중 didSet에 의해 커스텀 히스토리가 오염됨
            if isRestoringSession { return }

            // 커스텀 히스토리(웹뷰가 아직 없거나 fallback용)
            if currentIndexInStack < historyStack.count - 1 {
                historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
            }
            historyStack.append(url)
            currentIndexInStack = historyStack.count - 1

            // 전역 방문기록 (표시용)
            addToHistory(url: url, title: "")
        }
    }

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var playerURL: URL?
    @Published var showAVPlayer = false

    // 세션 복원 대기 (CustomWebView.makeUIView에서 사용)
    var pendingSession: WebViewSession?

    // MARK: 내부 히스토리(커스텀; webView 없을 때를 위한 백업)
    private var historyStack: [URL] = []
    private var currentIndexInStack: Int = -1

    // 🛠 [수정] 복원 상태 플래그와 제어 메서드
    private(set) var isRestoringSession: Bool = false
    func beginSessionRestore() { isRestoringSession = true }   // 외부/내부에서 복원 시작 시 호출
    func finishSessionRestore() { isRestoringSession = false }  // 순차 로드/인덱스 이동 완료 후 호출

    // 히스토리 복원용 임시 버퍼 (TabPersistenceManager.loadTabs에서 채움)
    var restoredHistoryURLs: [String] = []
    var restoredHistoryIndex: Int = 0

    // 현재 연결된 웹뷰
    weak var webView: WKWebView?

    // 순차 로드 동기화를 위한 콜백 훅
    var onLoadCompletion: (() -> Void)?

    // MARK: 방문기록(표시용)
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
        let base = Self.globalHistory
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
        Self.globalHistory.append(entry)
        if Self.globalHistory.count > 10_000 {
            Self.globalHistory.removeFirst(Self.globalHistory.count - 10_000)
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

    // MARK: 세션 저장
    func saveSession() -> WebViewSession? {
        // 🛠 [수정] webView가 있으면 back/forward 리스트를 우선 사용 (정확도↑)
        if let _ = webView {
            let urls = historyURLs.compactMap { URL(string: $0) }
            let idx = currentHistoryIndex
            guard !urls.isEmpty, idx >= 0, idx < urls.count else {
                TabPersistenceManager.debugMessages.append("세션 저장 실패: webView 히스토리 없음")
                return nil
            }
            TabPersistenceManager.debugMessages.append("세션 저장(webView): \(urls.count) URLs, 인덱스 \(idx)")
            return WebViewSession(urls: urls, currentIndex: idx)
        }

        // fallback: 커스텀 스택 사용
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            TabPersistenceManager.debugMessages.append("세션 저장 실패: 히스토리 또는 인덱스 없음")
            return nil
        }
        TabPersistenceManager.debugMessages.append("세션 저장(fallback): \(historyStack.count) URLs, 인덱스 \(currentIndexInStack)")
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    // MARK: 세션 복원(스냅샷 → pendingSession → CustomWebView가 실제 로드)
    func restoreSession(_ session: WebViewSession) {
        // 🛠 [수정] 여기서는 플래그만 올리고 커스텀 스택만 준비.
        // 실제 순차 로드/인덱스 이동은 CustomWebView에서 수행 후 finishSessionRestore() 호출.
        beginSessionRestore()
        historyStack = session.urls
        currentIndexInStack = max(0, min(session.currentIndex, session.urls.count - 1))
        pendingSession = session

        if session.urls.indices.contains(currentIndexInStack) {
            // 현재 URL만 세팅(로드는 CustomWebView에서)
            currentURL = session.urls[currentIndexInStack]
            TabPersistenceManager.debugMessages.append("세션 복원 준비: URL \(currentURL?.absoluteString ?? "없음"), 인덱스 \(currentIndexInStack)")
        } else {
            currentURL = nil
            TabPersistenceManager.debugMessages.append("세션 복원 실패: 유효한 인덱스 없음")
        }

        // TabPersistenceManager.loadTabs()에서 채워둔 복원 버퍼가 있으면 시도
        if !restoredHistoryURLs.isEmpty {
            prepareRestoredHistoryIfNeeded()
        }
    }

    // MARK: 히스토리 복원(배열로 받은 URL들을 순차 로드 후 대상 인덱스로 이동)
    func prepareRestoredHistoryIfNeeded() {
        guard !restoredHistoryURLs.isEmpty, let webView = webView else {
            TabPersistenceManager.debugMessages.append("히스토리 복원 실패: URL 없음 또는 webView 없음")
            return
        }

        // 🛠 [수정] canOpenURL 필터 제거: WebKit에서 열 수 있는데 canOpenURL 제한으로 드랍될 수 있음
        let urls = restoredHistoryURLs.compactMap { URL(string: $0) }
        TabPersistenceManager.debugMessages.append("히스토리 복원 시도: \(urls.count) URLs, 인덱스 \(restoredHistoryIndex)")
        guard urls.indices.contains(restoredHistoryIndex) else {
            TabPersistenceManager.debugMessages.append("히스토리 복원 실패: 인덱스 범위 초과")
            return
        }

        // 순차 로드: 각 load 완료마다 onLoadCompletion 호출 → 마지막에 backList 인덱스로 이동
        for (index, url) in urls.enumerated() {
            webView.load(URLRequest(url: url))
            onLoadCompletion = { [weak self, weak webView] in
                guard let self, let webView else { return }
                TabPersistenceManager.debugMessages.append("히스토리 URL 로드 완료: \(url)")
                if index == urls.count - 1 {
                    DispatchQueue.main.async {
                        let backList = webView.backForwardList.backList
                        if backList.indices.contains(self.restoredHistoryIndex) {
                            webView.go(to: backList[self.restoredHistoryIndex])
                            TabPersistenceManager.debugMessages.append("히스토리 복원 완료: \(webView.url?.absoluteString ?? "없음")")
                        } else {
                            TabPersistenceManager.debugMessages.append("히스토리 복원 실패: backList 인덱스 범위 초과")
                        }
                        // 버퍼 정리
                        self.restoredHistoryURLs = []
                        self.restoredHistoryIndex = 0
                        // 🛠 [수정] 순차 복원 종료 시점에만 플래그 내림
                        self.finishSessionRestore()
                    }
                }
            }
        }
    }

    // MARK: 스냅샷/저장을 위한 히스토리 조회 (webView 우선)
    // 🛠 [수정] webView가 있으면 back/forward 리스트를 사용하고, 없으면 커스텀 스택 사용
    var historyURLs: [String] {
        if let webView = webView {
            let back = webView.backForwardList.backList.map { $0.url.absoluteString }
            let current = webView.backForwardList.currentItem.map { [$0.url.absoluteString] } ?? []
            let forward = webView.backForwardList.forwardList.map { $0.url.absoluteString }
            return back + current + forward
        }
        return historyStack.map { $0.absoluteString }
    }

    // 현재 인덱스 (webView.backList.count 또는 커스텀 인덱스)
    var currentHistoryIndex: Int {
        if let webView = webView { return webView.backForwardList.backList.count }
        return max(0, min(currentIndexInStack, max(0, historyStack.count - 1)))
    }

    // TabPersistenceManager용 스냅샷 API
    // 🛠 [수정] webView가 있으면 webView 기준으로 반환
    func historyStackIfAny() -> [URL] {
        if let webView = webView {
            let back = webView.backForwardList.backList.map { $0.url }
            let current = webView.backForwardList.currentItem?.url
            let forward = webView.backForwardList.forwardList.map { $0.url }
            return back + (current.map { [$0] } ?? []) + forward
        }
        return historyStack
    }

    func currentIndexInSafeBounds() -> Int {
        if let webView = webView { return webView.backForwardList.backList.count }
        guard !historyStack.isEmpty,
              currentIndexInStack >= 0,
              currentIndexInStack < historyStack.count else { return 0 }
        return currentIndexInStack
    }

    // MARK: 네비게이션 명령 (Notification → CustomWebView.Coordinator가 처리)
    func goBack()    { NotificationCenter.default.post(name: .init("WebViewGoBack"), object: nil) }
    func goForward() { NotificationCenter.default.post(name: .init("WebViewGoForward"), object: nil) }
    func reload()    { NotificationCenter.default.post(name: .init("WebViewReload"), object: nil) }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward

        // currentURL 업데이트 (didSet에서 복원 중이면 히스토리 추가 안 함)
        currentURL = webView.url

        // 페이지 타이틀
        let title = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "제목 없음")

        // 🛠 [수정] 복원 중에는 전역 방문 기록을 추가하지 않음(중복/오염 방지)
        if let finalURL = webView.url, !isRestoringSession {
            addToHistory(url: finalURL, title: title)
        }

        TabPersistenceManager.debugMessages.append("페이지 로드 완료: \(webView.url?.absoluteString ?? "없음")")

        // 순차 로드 체인 진행
        onLoadCompletion?()
        onLoadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        TabPersistenceManager.debugMessages.append("로드 실패 (Provisional): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        TabPersistenceManager.debugMessages.append("로드 실패 (Navigation): \(error.localizedDescription)")
    }

    // MARK: 방문기록 화면
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
                                // 방문기록에서 항목 선택 → 현재 탭으로 이동
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
                Button(action: { WebViewStateModel.clearGlobalHistory() }) {
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