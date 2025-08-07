//
//  WebViewStateModel.swift
//  설명: WKWebView 상태/히스토리/세션 저장·복원(지연로드) 관리
//

import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 세션 스냅샷 (저장/복원에 사용)
struct WebViewSession: Codable {
    let urls: [URL]       // 히스토리 전체 (back + current + forward)
    let currentIndex: Int // 현재 위치(= backList.count)
}

// MARK: - 히스토리 캐시 엔트리
/// 메모리 효율성을 위한 히스토리 캐시 관리
private class HistoryCacheEntry {
    let url: URL
    var title: String
    var lastAccessed: Date
    weak var webView: WKWebView?
    
    init(url: URL, title: String = "") {
        self.url = url
        self.title = title
        self.lastAccessed = Date()
    }
    
    func updateAccess() {
        lastAccessed = Date()
    }
}

// MARK: - 히스토리 캐시 매니저
private class HistoryCacheManager {
    static let shared = HistoryCacheManager()
    private init() {}
    
    private var cache: [URL: HistoryCacheEntry] = [:]
    private let maxCacheCount = 200
    
    func cacheEntry(for url: URL, title: String = "") {
        if let entry = cache[url] {
            if !title.isEmpty { entry.title = title }
            entry.updateAccess()
        } else {
            cache[url] = HistoryCacheEntry(url: url, title: title)
            pruneIfNeeded()
        }
    }
    
    func entry(for url: URL) -> HistoryCacheEntry? {
        cache[url]
    }
    
    func pruneIfNeeded() {
        guard cache.count > maxCacheCount else { return }
        let sorted = cache.values.sorted(by: { $0.lastAccessed < $1.lastAccessed })
        let toRemove = sorted.prefix(cache.count - maxCacheCount/2)
        for e in toRemove { cache.removeValue(forKey: e.url) }
    }
    
    func clearCache() { cache.removeAll() }
}

// MARK: - WebViewStateModel
/// WKWebView의 상태와 히스토리, 세션 저장·복원을 관리하는 ViewModel
/// ✅ 개선사항: 지연로드 방식으로 마지막 페이지만 로드하고 나머지는 필요시 로드
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

            // 전역 방문 기록 업데이트 (⚠️ 타입 명시로 정정)
            WebViewStateModel.globalHistory.append(.init(url: url, title: url.host ?? "제목 없음", date: Date()))
            WebViewStateModel.saveGlobalHistory()
        }
    }

    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var showAVPlayer = false

    // ✅ 지연로드를 위한 가상 히스토리 스택 (실제 로드되지 않은 URL들)
    private var virtualHistoryStack: [URL] = []
    private var virtualCurrentIndex: Int = -1
    internal var isUsingVirtualHistory: Bool = false  // ✅ internal로 유지

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
        // [FIX] 가상 히스토리 모드 유지 (복원 후 뒤/앞 이동용)
        // isUsingVirtualHistory = false
        TabPersistenceManager.debugMessages.append("세션 복원 완료 플래그 OFF")
    }

    // 현재 연결된 웹뷰
    weak var webView: WKWebView? {
        didSet {
            // webView가 설정되면 대기 중인 히스토리 복원 실행 (지연로드 방식)
            if let _ = webView, let session = pendingSession {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.executeOptimizedRestore(session: session)
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

    // ⚠️ addToHistory는 더 이상 사용하지 않지만, 남겨두는 경우를 대비해 타입 명시로 안전하게 유지
    private func addToHistory(url: URL, title: String) {
        WebViewStateModel.globalHistory.append(.init(url: url, title: title, date: Date()))
        WebViewStateModel.saveGlobalHistory()
    }

    func clearHistory() {
        WebViewStateModel.globalHistory = []
        WebViewStateModel.saveGlobalHistory()
        HistoryCacheManager.shared.clearCache()
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

        // ✅ 가상 히스토리 사용 중이면 가상 스택 기준으로 저장
        if isUsingVirtualHistory {
            guard !virtualHistoryStack.isEmpty, virtualCurrentIndex >= 0 else {
                TabPersistenceManager.debugMessages.append("세션 저장 실패: 가상 히스토리 없음")
                return nil
            }
            TabPersistenceManager.debugMessages.append("세션 저장(가상): \(virtualHistoryStack.count) URLs, 인덱스 \(virtualCurrentIndex)")
            return WebViewSession(urls: virtualHistoryStack, currentIndex: virtualCurrentIndex)
        }

        // fallback: 커스텀 스택 사용
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            TabPersistenceManager.debugMessages.append("세션 저장 실패: 히스토리 또는 인덱스 없음")
            return nil
        }
        TabPersistenceManager.debugMessages.append("세션 저장(fallback): \(historyStack.count) URLs, 인덱스 \(currentIndexInStack)")
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    // MARK: 세션 복원(지연로드)
    func restoreSession(_ session: WebViewSession) {
        beginSessionRestore()
        
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, session.urls.count - 1))
        
        if !urls.isEmpty && urls.indices.contains(targetIndex) {
            // ✅ 가상 히스토리 스택 설정 (실제 로드는 하지 않음)
            virtualHistoryStack = urls
            virtualCurrentIndex = targetIndex
            isUsingVirtualHistory = true
            
            // 커스텀 스택도 업데이트 (fallback용)
            historyStack = urls
            currentIndexInStack = targetIndex
            
            // pendingSession 설정
            pendingSession = session
            
            // 현재 URL만 세팅 (실제 로드는 executeOptimizedRestore에서)
            currentURL = urls[targetIndex]
            TabPersistenceManager.debugMessages.append("✅ 지연로드 세션 복원 준비: \(urls.count) URLs, 목표 인덱스 \(targetIndex)")
        } else {
            currentURL = nil
            finishSessionRestore()
            TabPersistenceManager.debugMessages.append("세션 복원 실패: 유효한 URL/인덱스 없음")
        }
    }

    // MARK: ✅ 최적화된 복원 실행 (마지막 페이지만 로드)
    private func executeOptimizedRestore(session: WebViewSession) {
        guard let webView = webView else {
            TabPersistenceManager.debugMessages.append("최적화된 복원 실패: webView 없음")
            return
        }
        
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, urls.count - 1))
        
        guard urls.indices.contains(targetIndex) else {
            TabPersistenceManager.debugMessages.append("최적화된 복원 실패: 인덱스 범위 초과")
            finishSessionRestore()
            return
        }
        
        let targetURL = urls[targetIndex]
        TabPersistenceManager.debugMessages.append("✅ 최적화된 복원: 마지막 페이지만 로드 \(targetURL.absoluteString)")
        
        // 복원 완료 콜백 설정
        onLoadCompletion = { [weak self] in
            guard let self = self else { return }
            self.canGoBack = targetIndex > 0
            self.canGoForward = targetIndex < urls.count - 1
            
            // pending 정리 + 복원 종료
            self.pendingSession = nil
            self.finishSessionRestore()
            
            // 저장 신호 발송
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.navigationDidFinish.send(())
            }
        }
        
        // ✅ 현재 페이지만 로드 (나머지는 앞뒤 버튼 클릭 시 지연로드)
        webView.load(URLRequest(url: targetURL))
        
        // 히스토리 캐시에 현재 URL 등록
        HistoryCacheManager.shared.cacheEntry(for: targetURL)
    }

    // MARK: ✅ 지연로드를 위한 히스토리 조회 API
    var historyURLs: [String] {
        // 가상 히스토리 사용 중이면 가상 스택 반환
        if isUsingVirtualHistory {
            return virtualHistoryStack.map { $0.absoluteString }
        }
        
        if let webView = webView {
            let back    = webView.backForwardList.backList.map { $0.url.absoluteString }
            let current = webView.backForwardList.currentItem.map { [$0.url.absoluteString] } ?? []
            let forward = webView.backForwardList.forwardList.map { $0.url.absoluteString }
            return back + current + forward
        }
        return historyStack.map { $0.absoluteString }
    }

    var currentHistoryIndex: Int {
        // 가상 히스토리 사용 중이면 가상 인덱스 반환
        if isUsingVirtualHistory {
            return max(0, min(virtualCurrentIndex, max(0, virtualHistoryStack.count - 1)))
        }
        
        if let webView = webView { return webView.backForwardList.backList.count }
        guard !historyStack.isEmpty,
              currentIndexInStack >= 0,
              currentIndexInStack < historyStack.count else { return 0 }
        return currentIndexInStack
    }

    func historyStackIfAny() -> [URL] {
        // 가상 히스토리 사용 중이면 가상 스택 반환
        if isUsingVirtualHistory {
            return virtualHistoryStack
        }
        
        if let webView = webView {
            let back    = webView.backForwardList.backList.map { $0.url }
            let current = webView.backForwardList.currentItem?.url
            let forward = webView.backForwardList.forwardList.map { $0.url }
            return back + (current.map { [$0] } ?? []) + forward
        }
        return historyStack
    }

    func currentIndexInSafeBounds() -> Int {
        // 가상 히스토리 사용 중이면 가상 인덱스 반환
        if isUsingVirtualHistory {
            return max(0, min(virtualCurrentIndex, virtualHistoryStack.count - 1))
        }
        
        if let webView = webView { return webView.backForwardList.backList.count }
        guard !historyStack.isEmpty,
              currentIndexInStack >= 0,
              currentIndexInStack < historyStack.count else { return 0 }
        return currentIndexInStack
    }

    // MARK: ✅ 최적화된 네비게이션 명령 (지연로드 지원)
    func goBack() { 
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .back)
        } else {
            NotificationCenter.default.post(name: .init("WebViewGoBack"), object: nil) 
        }
    }
    
    func goForward() { 
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .forward)
        } else {
            NotificationCenter.default.post(name: .init("WebViewGoForward"), object: nil) 
        }
    }
    
    func reload() { NotificationCenter.default.post(name: .init("WebViewReload"), object: nil) }

    // MARK: ✅ 가상 네비게이션 (지연로드)
    private enum NavigationDirection {
        case back, forward
    }
    
    private func performVirtualNavigation(direction: NavigationDirection) {
        guard isUsingVirtualHistory, let webView = webView else { return }
        
        let newIndex: Int
        switch direction {
        case .back:
            guard virtualCurrentIndex > 0 else { 
                TabPersistenceManager.debugMessages.append("가상 네비게이션: 뒤로가기 불가")
                return 
            }
            newIndex = virtualCurrentIndex - 1
        case .forward:
            guard virtualCurrentIndex < virtualHistoryStack.count - 1 else { 
                TabPersistenceManager.debugMessages.append("가상 네비게이션: 앞으로가기 불가")
                return 
            }
            newIndex = virtualCurrentIndex + 1
        }
        
        let targetURL = virtualHistoryStack[newIndex]
        TabPersistenceManager.debugMessages.append("✅ 지연로드 네비게이션: \(direction) → \(targetURL.absoluteString)")
        
        // 인덱스 업데이트
        virtualCurrentIndex = newIndex
        canGoBack = virtualCurrentIndex > 0
        canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
        
        // 해당 페이지 지연로드
        currentURL = targetURL
        webView.load(URLRequest(url: targetURL))
        
        // 히스토리 캐시 업데이트
        HistoryCacheManager.shared.cacheEntry(for: targetURL)
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView
        
        // ✅ 가상 히스토리 사용 중이 아닐 때만 기본 네비게이션 상태 업데이트
        if !isUsingVirtualHistory {
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
            
            // 🔧 복원 중이 아닐 때만 currentURL 업데이트 (복원 중에는 오염 방지)
            if !isRestoringSession {
                currentURL = webView.url
            }
        }

        // 페이지 타이틀
        let title = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "제목 없음")

        // 복원 중에는 전역 방문 기록 추가 금지(중간 오염 방지)
        if let finalURL = webView.url, !isRestoringSession {
            WebViewStateModel.globalHistory.append(.init(url: finalURL, title: title, date: Date()))
            WebViewStateModel.saveGlobalHistory()
            // 히스토리 캐시에 타이틀 업데이트
            HistoryCacheManager.shared.cacheEntry(for: finalURL, title: title)
        }

        TabPersistenceManager.debugMessages.append("페이지 로드 완료: \(webView.url?.absoluteString ?? "nil"), 복원중: \(isRestoringSession), 가상히스토리: \(isUsingVirtualHistory)")

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
            finishSessionRestore()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        TabPersistenceManager.debugMessages.append("로드 실패 (Navigation): \(error.localizedDescription)")
        
        // 복원 중 실패 시 복원 중단
        if isRestoringSession {
            finishSessionRestore()
        }
    }

    // MARK: 방문기록 화면 (내부 View)
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel
        @State private var searchQuery: String = ""
        @Environment(\.dismiss) private var dismiss
        
        // 기본 날짜 포맷터 (private이어서 멤버와이즈 init이 private로 떨어질 수 있음)
        // → 이슈 방지를 위해 아래에 명시 init(state:) 추가
        private var dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        // 검색 필터링 결과 (전역 방문기록 기반)
        private var filteredHistory: [HistoryEntry] {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return WebViewStateModel.globalHistory.sorted { $0.date > $1.date } }
            return WebViewStateModel.globalHistory
                .filter { $0.url.absoluteString.lowercased().contains(q) || $0.title.lowercased().contains(q) }
                .sorted { $0.date > $1.date }
        }

        // ✅ 명시 이니셜라이저: 외부에서 접근 가능하게 보장
        init(state: WebViewStateModel) {
            self._state = ObservedObject(wrappedValue: state)
        }

        var body: some View {
            List {
                ForEach(filteredHistory) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title.isEmpty ? (item.url.host ?? "제목 없음") : item.title)
                            .font(.headline)
                        Text(item.url.absoluteString)
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(dateFormatter.string(from: item.date))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("방문 기록")
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("모두 지우기") {
                        WebViewStateModel.globalHistory.removeAll()
                        WebViewStateModel.saveGlobalHistory()
                    }
                }
            }
        }

        // ✅ 여기서는 state.filteredHistory가 아니라 로컬 filteredHistory 사용
        func delete(at offsets: IndexSet) {
            let items = filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
            WebViewStateModel.saveGlobalHistory()
            TabPersistenceManager.debugMessages.append("방문 기록 삭제: \(targets.count)개")
        }
    }
}
