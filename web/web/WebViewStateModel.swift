//
//  WebViewStateModel.swift
//  설명: WKWebView 상태/히스토리/세션 저장·복원(지연로드) 관리 + 상세 디버그 로그
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

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
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
    
    func updateAccess() { lastAccessed = Date() }
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
    
    func entry(for url: URL) -> HistoryCacheEntry? { cache[url] }
    
    private func pruneIfNeeded() {
        guard cache.count > maxCacheCount else { return }
        let sorted = cache.values.sorted(by: { $0.lastAccessed < $1.lastAccessed })
        let toRemove = sorted.prefix(cache.count - maxCacheCount/2)
        for e in toRemove { cache.removeValue(forKey: e.url) }
    }
    
    func clearCache() { cache.removeAll() }
}

// MARK: - WebViewStateModel
/// WKWebView의 상태/히스토리/세션 저장·복원을 관리하는 ViewModel
/// ✅ 개선사항:
///   - 지연로드 방식: 현재 페이지만 로드하고 앞/뒤는 누를 때 로드
///   - 가상 히스토리 유지: 복원 직후에도 back/forward 동작 보장
///   - 상세 디버그 로그: 단계별로 시각/인덱스/URL을 기록
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {

    // 탭 식별자 (외부에서 셋; 로그에 같이 찍힘)
    var tabID: UUID?

    // MARK: — 네비게이션 완료 퍼블리셔
    /// 페이지 로드가 "완료"됐을 때 emit. ContentView는 이 신호만 받아 탭 스냅샷을 저장한다.
    /// ⚠️ 복원 중엔 didFinish에서 이 신호를 보내지 않고, 복원 마지막 점프가 끝난 뒤 한 번만 보냄.
    let navigationDidFinish = PassthroughSubject<Void, Never>()

    // MARK: 상태 바인딩
    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }

            // 마지막 URL 메모
            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            dbg("URL 업데이트 → \(url.absoluteString)")

            // 🛠 복원 중엔 커스텀/전역 히스토리에 손대지 않음(중간 오염 방지)
            if isRestoringSession { return }

            // 커스텀 히스토리(웹뷰가 아직 없거나 fallback용)
            if currentIndexInStack < historyStack.count - 1 {
                historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
            }
            historyStack.append(url)
            currentIndexInStack = historyStack.count - 1

            // ✅ 가상 히스토리 사용 중일 때도 스택에 반영하여 동기화
            //  - 복원 이후 새 페이지를 방문하면 기존 가상 스택의 앞뒤 부분이 올바르게 잘려야 함
            //  - 새 URL을 스택에 추가하고 현재 인덱스를 갱신하여 앞으로/뒤로가기 상태를 정확히 유지
            if isUsingVirtualHistory {
                // 가상 스택에서 현재 인덱스 이후의 요소는 제거 (새 경로 탐색에 대비)
                if virtualCurrentIndex < virtualHistoryStack.count - 1 {
                    virtualHistoryStack = Array(virtualHistoryStack.prefix(upTo: virtualCurrentIndex + 1))
                }
                virtualHistoryStack.append(url)
                virtualCurrentIndex = virtualHistoryStack.count - 1
                // 가상 히스토리 기반으로 뒤로/앞으로 가능 여부 업데이트
                canGoBack = virtualCurrentIndex > 0
                canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
            }

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
    internal var isUsingVirtualHistory: Bool = false  // 복원 후에도 유지하여 back/forward 동작 보장

    // 세션 복원 대기 (CustomWebView.makeUIView에서 사용)
    var pendingSession: WebViewSession?

    // MARK: 내부 히스토리(커스텀; webView 없을 때를 위한 백업)
    private var historyStack: [URL] = []
    private var currentIndexInStack: Int = -1

    // 🛠 복원 상태 플래그와 제어 메서드 (복원 중엔 저장/히스토리 오염 금지)
    private(set) var isRestoringSession: Bool = false
    func beginSessionRestore() {
        isRestoringSession = true
        dbg("🧭 RESTORE 시작 (가상히스토리 \(isUsingVirtualHistory ? "ON" : "OFF"))")
    }
    func finishSessionRestore() {
        isRestoringSession = false
        // ❌ 끄지 않음: isUsingVirtualHistory = false
        dbg("🧭 RESTORE 종료 (가상히스토리 유지: \(isUsingVirtualHistory ? "ON" : "OFF"))")
    }

    // 현재 연결된 웹뷰
    weak var webView: WKWebView? {
        didSet {
            if let webView {
                dbg("🔗 webView 연결됨: canGoBack=\(webView.canGoBack) canGoForward=\(webView.canGoForward)")
            }
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

    private func addToHistory(url: URL, title: String) {
        WebViewStateModel.globalHistory.append(.init(url: url, title: title, date: Date()))
        WebViewStateModel.saveGlobalHistory()
    }

    func clearHistory() {
        WebViewStateModel.globalHistory = []
        WebViewStateModel.saveGlobalHistory()
        HistoryCacheManager.shared.clearCache()
        dbg("🧹 전역 방문 기록 삭제")
    }

    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
            TabPersistenceManager.debugMessages.append("[\(ts())] ☁️ 전역 방문 기록 저장: \(globalHistory.count)개")
        }
    }

    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
            TabPersistenceManager.debugMessages.append("[\(ts())] ☁️ 전역 방문 기록 로드: \(loaded.count)개")
        }
    }

    // MARK: 세션 저장(스냅샷)
    func saveSession() -> WebViewSession? {
        // webView가 있으면 back/forward 리스트 우선 사용 (정확도↑)
        if let _ = webView {
            let urls = historyURLs.compactMap { URL(string: $0) }
            let idx  = currentHistoryIndex
            guard !urls.isEmpty, idx >= 0, idx < urls.count else {
                dbg("💾 세션 저장 실패: webView 히스토리 없음")
                return nil
            }
            dbg("💾 세션 저장(webView): \(urls.count) URLs, 인덱스 \(idx)")
            return WebViewSession(urls: urls, currentIndex: idx)
        }

        // 가상 히스토리 사용 중이면 가상 스택 기준으로 저장
        if isUsingVirtualHistory {
            guard !virtualHistoryStack.isEmpty, virtualCurrentIndex >= 0 else {
                dbg("💾 세션 저장 실패: 가상 히스토리 없음")
                return nil
            }
            dbg("💾 세션 저장(가상): \(virtualHistoryStack.count) URLs, 인덱스 \(virtualCurrentIndex)")
            return WebViewSession(urls: virtualHistoryStack, currentIndex: virtualCurrentIndex)
        }

        // fallback: 커스텀 스택 사용
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 또는 인덱스 없음")
            return nil
        }
        dbg("💾 세션 저장(fallback): \(historyStack.count) URLs, 인덱스 \(currentIndexInStack)")
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    // MARK: 세션 복원(지연로드)
    func restoreSession(_ session: WebViewSession) {
        beginSessionRestore()
        
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, session.urls.count - 1))
        
        if !urls.isEmpty && urls.indices.contains(targetIndex) {
            // 가상 히스토리 스택 설정 (실제 로드는 하지 않음)
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
            dbg("🧭 RESTORE 준비: \(urls.count) URLs, 목표 idx \(targetIndex)")
        } else {
            currentURL = nil
            finishSessionRestore()
            dbg("🧭 RESTORE 실패: 유효한 URL/인덱스 없음")
        }
    }

    // MARK: ✅ 최적화된 복원 실행 (마지막 페이지만 로드)
    private func executeOptimizedRestore(session: WebViewSession) {
        guard let webView = webView else {
            dbg("🧭 RESTORE 실행 실패: webView 없음")
            return
        }
        
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, urls.count - 1))
        guard urls.indices.contains(targetIndex) else {
            dbg("🧭 RESTORE 실행 실패: 인덱스 범위 초과")
            finishSessionRestore()
            return
        }
        
        let targetURL = urls[targetIndex]
        dbg("🧭 RESTORE 실행: 마지막 페이지만 로드 → idx \(targetIndex) | \(targetURL.absoluteString)")
        
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
                self.dbg("🧭 RESTORE 완료 신호 전송 (navigationDidFinish)")
                self.logHistorySnapshot(reason: "RESTORE")
            }
        }
        
        // 현재 페이지만 로드 (나머지는 앞뒤 버튼 클릭 시 지연로드)
        webView.load(URLRequest(url: targetURL))
        
        // 히스토리 캐시에 현재 URL 등록
        HistoryCacheManager.shared.cacheEntry(for: targetURL)
    }

    // MARK: ✅ 지연로드를 위한 히스토리 조회 API
    var historyURLs: [String] {
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
    private enum NavigationDirection { case back, forward }
    
    private func performVirtualNavigation(direction: NavigationDirection) {
        guard isUsingVirtualHistory, let webView = webView else { return }
        
        let newIndex: Int
        switch direction {
        case .back:
            guard virtualCurrentIndex > 0 else { dbg("⬅️ 가상 네비: 뒤로가기 불가"); return }
            newIndex = virtualCurrentIndex - 1
        case .forward:
            guard virtualCurrentIndex < virtualHistoryStack.count - 1 else { dbg("➡️ 가상 네비: 앞으로가기 불가"); return }
            newIndex = virtualCurrentIndex + 1
        }
        
        let targetURL = virtualHistoryStack[newIndex]
        dbg("🧩 V-NAV \(direction == .back ? "BACK" : "FWD") → idx \(newIndex) | \(targetURL.absoluteString)")
        
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
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        dbg("🌐 LOAD 시작 → \(webView.url?.absoluteString ?? "(pending)") | restoring=\(isRestoringSession) vhist=\(isUsingVirtualHistory)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView
        
        // 가상 히스토리 사용 중이 아닐 때만 기본 네비게이션 상태 업데이트
        if !isUsingVirtualHistory {
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
            
            // 복원 중이 아닐 때만 currentURL 업데이트 (복원 중에는 오염 방지)
            if !isRestoringSession {
                currentURL = webView.url
            }
        }

        let title = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "제목 없음")

        // 복원 중에는 전역 방문 기록 추가 금지(중간 오염 방지)
        if let finalURL = webView.url, !isRestoringSession {
            WebViewStateModel.globalHistory.append(.init(url: finalURL, title: title, date: Date()))
            WebViewStateModel.saveGlobalHistory()
            HistoryCacheManager.shared.cacheEntry(for: finalURL, title: title)
        }

        dbg("🌐 LOAD 완료 → \(webView.url?.absoluteString ?? "nil") | restoring=\(isRestoringSession) vhist=\(isUsingVirtualHistory)")
        logHistorySnapshot(reason: "LOAD_FINISH")

        // 순차 로드 체인 진행
        onLoadCompletion?()
        onLoadCompletion = nil

        // 저장 트리거는 복원 중이 아닌 경우에만 여기서 보냄
        if !isRestoringSession {
            navigationDidFinish.send(())
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dbg("❌ 로드 실패(Provisional): \(error.localizedDescription)")
        if isRestoringSession { finishSessionRestore() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dbg("❌ 로드 실패(Navigation): \(error.localizedDescription)")
        if isRestoringSession { finishSessionRestore() }
    }

    // MARK: - 디버그 로그 도우미
    private func dbg(_ msg: String) {
        let id = tabID?.uuidString.prefix(6) ?? "noTab"
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)] \(msg)")
    }
    private func logHistorySnapshot(reason: String) {
        if isUsingVirtualHistory {
            let list = virtualHistoryStack.map { $0.absoluteString }
            let idx  = max(0, min(virtualCurrentIndex, max(0, list.count - 1)))
            let cur  = list.indices.contains(idx) ? list[idx] : "(없음)"
            dbg("🧩 V-HIST(\(reason)) ⏪\(idx) ▶︎\(max(0, list.count - idx - 1)) | \(cur)")
        } else if let wv = webView {
            let back = wv.backForwardList.backList.count
            let fwd  = wv.backForwardList.forwardList.count
            let cur  = wv.url?.absoluteString ?? "(없음)"
            dbg("📜 H-HIST(\(reason)) ⏪\(back) ▶︎\(fwd) | \(cur)")
        } else {
            dbg("📜 HIST(\(reason)) 웹뷰 미연결")
        }
    }

    // MARK: 방문기록 화면 (내부 View)
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel
        @State private var searchQuery: String = ""
        @Environment(\.dismiss) private var dismiss
        
        // 기본 날짜 포맷터 (private이므로 멤버와이즈 init가 private로 떨어질 수 있어 명시 init 제공)
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

        // ✅ 명시 이니셜라이저: 외부에서 접근 가능
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
                    // ▶ 수정 시작: 클릭 시 페이지 이동 & 시트 닫기
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.currentURL = item.url
                        state.loadURLIfReady()
                        dismiss()
                    }
                    // ◀ 수정 끝
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

        // 로컬 filteredHistory 기반 삭제 (state.filteredHistory 아님)
        func delete(at offsets: IndexSet) {
            let items = filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
            WebViewStateModel.saveGlobalHistory()
            TabPersistenceManager.debugMessages.append("[\(ts())] 🧹 방문 기록 삭제: \(targets.count)개")
        }
    }
}