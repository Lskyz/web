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
    let navigationDidFinish = PassthroughSubject<Void, Never>()

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
    func beginSessionRestore() { 
        isRestoringSession = true 
        TabPersistenceManager.debugMessages.append("세션 복원 시작 플래그 ON")
    }
    func finishSessionRestore() { 
        isRestoringSession = false 
        TabPersistenceManager.debugMessages.append("세션 복원 완료 플래그 OFF")
    }

    // 🔧 히스토리 복원 관련 개선된 상태 관리
    private var pendingHistoryRestore: HistoryRestoreTask?
    
    private struct HistoryRestoreTask {
        let urls: [URL]
        let targetIndex: Int
        var currentLoadIndex: Int = 0
    }

    // 현재 연결된 웹뷰
    weak var webView: WKWebView? {
        didSet {
            // webView가 설정되면 대기 중인 히스토리 복원 실행
            if let _ = webView, pendingHistoryRestore != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.executeHistoryRestore()
                }
            }
        }
    }

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
        
        // 히스토리 복원 태스크 준비
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, session.urls.count - 1))
        
        if !urls.isEmpty && urls.indices.contains(targetIndex) {
            pendingHistoryRestore = HistoryRestoreTask(urls: urls, targetIndex: targetIndex)
            
            // 커스텀 스택도 업데이트 (fallback용)
            historyStack = urls
            currentIndexInStack = targetIndex
            
            // pendingSession 설정 (기존 로직과 호환)
            pendingSession = session
            
            // 현재 URL만 세팅 (실제 히스토리 로드는 webView 연결 후)
            currentURL = urls[targetIndex]
            TabPersistenceManager.debugMessages.append("세션 복원 준비: \(urls.count) URLs, 목표 인덱스 \(targetIndex)")
        } else {
            currentURL = nil
            finishSessionRestore()
            TabPersistenceManager.debugMessages.append("세션 복원 실패: 유효한 URL/인덱스 없음")
        }
    }

    // MARK: 🔧 개선된 히스토리 복원 실행
    private func executeHistoryRestore() {
        guard let webView = webView,
              let task = pendingHistoryRestore else {
            TabPersistenceManager.debugMessages.append("히스토리 복원 실행 실패: webView 또는 복원 태스크 없음")
            return
        }
        
        let urls = task.urls
        let targetIndex = task.targetIndex
        
        TabPersistenceManager.debugMessages.append("히스토리 복원 실행 시작: \(urls.count) URLs, 목표 인덱스 \(targetIndex)")
        
        // 🔧 비동기로 순차 로드 시작 (안정성을 위해 약간의 딜레이)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startSequentialLoad(urls: urls, targetIndex: targetIndex, webView: webView)
        }
    }

    // MARK: 🔧 개선된 순차 로드
    private func startSequentialLoad(urls: [URL], targetIndex: Int, webView: WKWebView) {
        guard !urls.isEmpty else { 
            finishSessionRestore()
            return 
        }
        
        TabPersistenceManager.debugMessages.append("순차 로드 시작: 첫 번째 URL \(urls[0].absoluteString)")
        
        // 첫 번째 URL 로드
        loadURLSequentially(urls: urls, currentIndex: 0, targetIndex: targetIndex, webView: webView)
    }
    
    private func loadURLSequentially(urls: [URL], currentIndex: Int, targetIndex: Int, webView: WKWebView) {
        // 모든 URL 로드 완료 → 목표 인덱스로 이동
        if currentIndex >= urls.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.navigateToTargetIndex(targetIndex: targetIndex, webView: webView)
            }
            return
        }
        
        let url = urls[currentIndex]
        TabPersistenceManager.debugMessages.append("순차 로드 중: [\(currentIndex)/\(urls.count-1)] \(url.absoluteString)")
        
        // 로드 완료 콜백 설정
        onLoadCompletion = { [weak self] in
            TabPersistenceManager.debugMessages.append("순차 로드 완료: [\(currentIndex)] \(url.absoluteString)")
            // 다음 URL로 진행
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.loadURLSequentially(urls: urls, currentIndex: currentIndex + 1, targetIndex: targetIndex, webView: webView)
            }
        }
        
        // URL 로드
        webView.load(URLRequest(url: url))
    }
    
    private func navigateToTargetIndex(targetIndex: Int, webView: WKWebView) {
        let backList = webView.backForwardList.backList
        
        if backList.indices.contains(targetIndex) {
            TabPersistenceManager.debugMessages.append("목표 인덱스로 이동: \(targetIndex)")
            
            // 최종 네비게이션 완료 콜백 설정
            onLoadCompletion = { [weak self] in
                guard let self = self else { return }
                TabPersistenceManager.debugMessages.append("히스토리 복원 최종 완료")
                
                // 복원 완료 처리
                self.pendingHistoryRestore = nil
                self.finishSessionRestore()
                
                // 저장 신호 발송
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.navigationDidFinish.send(())
                }
            }
            
            // 목표 위치로 이동
            webView.go(to: backList[targetIndex])
        } else {
            TabPersistenceManager.debugMessages.append("목표 인덱스 이동 실패: 범위 초과 \(targetIndex)")
            pendingHistoryRestore = nil
            finishSessionRestore()
        }
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

        // 🔧 복원 중이 아닐 때만 currentURL 업데이트 (복원 중에는 오염 방지)
        if !isRestoringSession {
            currentURL = webView.url
        }

        // 페이지 타이틀
        let title = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "제목 없음")

        // 복원 중에는 전역 방문 기록 추가 금지(중간 오염 방지)
        if let finalURL = webView.url, !isRestoringSession {
            addToHistory(url: finalURL, title: title)
        }

        TabPersistenceManager.debugMessages.append("페이지 로드 완료: \(webView.url?.absoluteString ?? "없음"), 복원중: \(isRestoringSession)")

        // 순차 로드 체인 진행 (복원 중이든 아니든 항상 호출)
        onLoadCompletion?()
        onLoadCompletion = nil

        // ⚠️ 저장 트리거는 복원 중이 아닌 경우에만 여기서 보냄
        if !isRestoringSession {
            navigationDidFinish.send(())
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        TabPersistenceManager.debugMessages.append("로드 실패 (Provisional): \(error.localizedDescription)")
        
        // 복원 중 실패 시 복원 중단
        if isRestoringSession {
            pendingHistoryRestore = nil
            finishSessionRestore()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        TabPersistenceManager.debugMessages.append("로드 실패 (Navigation): \(error.localizedDescription)")
        
        // 복원 중 실패 시 복원 중단
        if isRestoringSession {
            pendingHistoryRestore = nil
            finishSessionRestore()
        }
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
