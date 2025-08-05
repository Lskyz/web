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
/// WKWebView의 상태와 히스토리, 세션 저장·복원을 관리하는 ViewModel
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {

    // 탭 식별자 (외부에서 셋)
    var tabID: UUID?

    // MARK: — 네비게이션 완료 퍼블리셔
    /// 페이지 로드가 "완료"됐을 때 emit. ContentView는 이 신호만 받아 탭 스냅샷을 저장한다.
    /// ⚠️ 복원 중엔 didFinish에서 이 신호를 보내지 않고, 복원 마지막 점프(go(to:))가 끝난 뒤 한 번만 보냄.
    let navigationDidFinish = PassthroughSubject<Void, Never>()   // 🛠 추가

    // MARK: 상태 바인딩
    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }

            // 마지막 URL 메모
            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            TabPersistenceManager.debugMessages.append("URL 업데이트: \(url.absoluteString)")

            // 🛠 복원 중엔 커스텀/전역 히스토리에 손대지 않음(중간 단계 오염 방지)
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

    // 🛠 복원 상태 플래그와 제어 메서드 (복원 중엔 저장/히스토리 오염 금지)
    private(set) var isRestoringSession: Bool = false
    func beginSessionRestore() { isRestoringSession = true }
    func finishSessionRestore() { isRestoringSession = false }

    // 히스토리 복원용 임시 버퍼 (TabPersistenceManager.loadTabs에서 채움)
    var restoredHistoryURLs: [String] = []
    var restoredHistoryIndex: Int = 0

    // 현재 연결된 웹뷰
    weak var webView: WKWebView?

    // 순차 로드 동기화를 위한 콜백 훅 (didFinish에서 호출됨)
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

    // MARK: 세션 저장(스냅샷)
    func saveSession() -> WebViewSession? {
        // 🛠 webView가 있으면 back/forward 리스트 우선 사용 (정확도↑)
        if let _ = webView {
            let urls = historyURLs.compactMap { URL(string: $0) }
            let idx  = currentHistoryIndex
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

    // MARK: 세션 복원(스냅샷 → pendingSession, 실제 로드는 CustomWebView)
    func restoreSession(_ session: WebViewSession) {
        beginSessionRestore()
        historyStack = session.urls
        currentIndexInStack = max(0, min(session.currentIndex, session.urls.count - 1))
        pendingSession = session

        if session.urls.indices.contains(currentIndexInStack) {
            // 현재 URL만 세팅(실제 로드는 CustomWebView에서)
            currentURL = session.urls[currentIndexInStack]
            TabPersistenceManager.debugMessages.append("세션 복원 준비: URL \(currentURL?.absoluteString ?? "없음"), 인덱스 \(currentIndexInStack)")
        } else {
            currentURL = nil
            TabPersistenceManager.debugMessages.append("세션 복원 실패: 유효한 인덱스 없음")
        }

        // 앱 전역 복원 버퍼 사용 시 — 여기서 순차 복원 수행
        if !restoredHistoryURLs.isEmpty {
            prepareRestoredHistoryIfNeeded()
        }
    }

    // MARK: 히스토리 복원(★순차 로드 체인★ → 마지막에 목표 인덱스로 go(to:))
    func prepareRestoredHistoryIfNeeded() {
        guard !restoredHistoryURLs.isEmpty, let webView = webView else {
            TabPersistenceManager.debugMessages.append("히스토리 복원 실패: URL 없음 또는 webView 없음")
            return
        }

        let urls = restoredHistoryURLs.compactMap { URL(string: $0) }
        TabPersistenceManager.debugMessages.append("히스토리 복원(순차) 시작: \(urls.count) URLs, 인덱스 \(restoredHistoryIndex)")

        guard urls.indices.contains(restoredHistoryIndex) else {
            TabPersistenceManager.debugMessages.append("히스토리 복원 실패: 인덱스 범위 초과")
            return
        }

        // 복원 플래그 켠 상태에서 순차 로드 시작
        beginSessionRestore()

        // 내부 재귀 함수로 순차 로드
        func loadSequentially(_ i: Int) {
            // 모두 로드 끝 → backList 기준 목표 인덱스로 점프
            if i >= urls.count {
                DispatchQueue.main.async {
                    let backList = webView.backForwardList.backList
                    if backList.indices.contains(self.restoredHistoryIndex) {
                        // 💡 마지막 점프가 끝난 "그 didFinish"에서 복원 종료 + 저장 신호를 보내도록 onLoadCompletion 등록
                        self.onLoadCompletion = { [weak self] in
                            guard let self = self else { return }
                            // 복원 종료 → 이제부터 didFinish는 일반 저장 트리거로 동작
                            self.finishSessionRestore()
                            // 복원 완료 시점에 딱 한 번 저장 트리거 발행
                            self.navigationDidFinish.send(())
                            TabPersistenceManager.debugMessages.append("히스토리 복원 최종 완료(신호 발행)")
                        }
                        webView.go(to: backList[self.restoredHistoryIndex])
                        TabPersistenceManager.debugMessages.append("히스토리 복원 go(to:) 실행")
                    } else {
                        // 실패 시에도 복원 종료 플래그 내리고 종료
                        self.finishSessionRestore()
                        TabPersistenceManager.debugMessages.append("히스토리 복원 실패: backList 인덱스 범위 초과")
                    }

                    // 버퍼 정리
                    self.restoredHistoryURLs = []
                    self.restoredHistoryIndex = 0
                }
                return
            }

            // i번째 URL 로드 → 로드 완료되면 다음으로
            let url = urls[i]
            webView.load(URLRequest(url: url))
            self.onLoadCompletion = { [weak self] in
                guard let self = self else { return }
                TabPersistenceManager.debugMessages.append("히스토리 URL 로드 완료(순차): \(url)")
                self.onLoadCompletion = nil
                loadSequentially(i + 1)
            }
        }

        loadSequentially(0)
    }

    // MARK: 히스토리 조회 API (webView 우선)
    var historyURLs: [String] {
        if let webView = webView {
            let back    = webView.backForwardList.backList.map { $0.url.absoluteString }
            let current = webView.backForwardList.currentItem.map { [$0.url.absoluteString] } ?? []
            let forward = webView.backForwardList.forwardList.map { $0.url.absoluteString }
            return back + current + forward
        }
        return historyStack.map { $0.absoluteString }
    }

    var currentHistoryIndex: Int {
        if let webView = webView {
            return webView.backForwardList.backList.count
        }
        return max(0, min(currentIndexInStack, historyStack.count - 1))
    }

    func historyStackIfAny() -> [URL] {
        if let webView = webView {
            let back    = webView.backForwardList.backList.map { $0.url }
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

        // currentURL 업데이트 (복원 중이면 didSet에서 히스토리 추가 안 함)
        currentURL = webView.url

        // 페이지 타이틀
        let title = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "제목 없음")

        // 복원 중에는 전역 방문 기록 추가 금지(중간 오염 방지)
        if let finalURL = webView.url, !isRestoringSession {
            addToHistory(url: finalURL, title: title)
        }

        TabPersistenceManager.debugMessages.append("페이지 로드 완료: \(webView.url?.absoluteString ?? "없음")")

        // ⚠️ 저장 트리거는 복원 중이 아닌 경우에만 여기서 보냄.
        //     복원 마지막 점프는 onLoadCompletion에서 finish 후 수동 발행(중복 방지)
        let shouldEmit = !isRestoringSession

        // 순차 로드 체인 진행
        onLoadCompletion?()
        onLoadCompletion = nil

        if shouldEmit {
            navigationDidFinish.send(())
        }
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
                                    .font(.headline).lineLimit(1)
                                Text(entry.url.absoluteString)
                                    .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                                Text(Self.dateFormatter.string(from: entry.date))
                                    .font(.caption).foregroundColor(.gray)
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