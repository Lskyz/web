//
//  WebViewStateModel.swift
//  설명: WKWebView 상태/히스토리/세션 저장·복원(지연로드) 관리 + 상세 디버그 로그
//  변경 요약(안정화 포인트)
//  1) KVO 옵저버 추가: canGoBack/canGoForward/url/isLoading/title 를 관찰하여 버튼 상태와 currentURL 동기화
//  2) 가상 히스토리 사용 시: 버튼 상태는 항상 가상 스택을 ‘단일 진실 원본(SSOT)’으로 계산, KVO는 참고만
//  3) 네비게이션 직렬화/디바운스: 빠른 연타로 중복 호출되는 문제 방지 (탭 최소간격 + isNavigating 융합)
//  4) 메인 스레드 보장: 퍼블리시/상태 갱신은 DispatchQueue.main에서 수행
//  5) 옵저버 해제 안전성: webView 교체/해제 시 옵저버 정리
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
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {
    // 외부에서 구분용
    var tabID: UUID?

    // 로드 완료 신호 (HistoryPage 등에서 구독)
    let navigationDidFinish = PassthroughSubject<Void, Never>()

    // 현재 URL (설정 시 커스텀/가상 히스토리 갱신 및 UserDefaults 기록)
    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }
            // 메인 스레드 보장
            if !Thread.isMainThread {
                DispatchQueue.main.async { [weak self] in self?.currentURL = url }
                return
            }

            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            dbg("URL 업데이트 → \(url.absoluteString)")

            // 세션 복원 중이면 히스토리 누적 방지
            if isRestoringSession { return }

            // ✅ 커스텀 히스토리(백업 스택) 유지
            if currentIndexInStack < historyStack.count - 1 {
                historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1))
            }
            historyStack.append(url)
            currentIndexInStack = historyStack.count - 1

            // ✅ 가상 히스토리: 세부 주소 기록 보장(중복 허용, forward 정리)
            if isUsingVirtualHistory {
                if virtualCurrentIndex < virtualHistoryStack.count - 1 {
                    virtualHistoryStack = Array(virtualHistoryStack.prefix(upTo: virtualCurrentIndex + 1))
                }
                virtualHistoryStack.append(url)
                virtualCurrentIndex = virtualHistoryStack.count - 1
                // 버튼 상태는 가상 스택을 단일 진실원본으로 계산
                canGoBack = virtualCurrentIndex > 0
                canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
                let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
                dbg("🧩 V-HIST 업데이트: idx=\(virtualCurrentIndex), stack=\(virtualHistoryStack.count), canGoBack=\(canGoBack), canGoForward=\(canGoForward) | urls=[\(urlList)]")
            }

            // 전역 히스토리에 기록 (타이틀은 일단 host 또는 '제목 없음')
            WebViewStateModel.globalHistory.append(.init(url: url, title: url.host ?? "제목 없음", date: Date()))
            WebViewStateModel.saveGlobalHistory()
        }
    }

    // 하단 버튼 상태 (메인스레드에서만 변경)
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var showAVPlayer = false

    // ====== 가상 히스토리(세밀 기록/복원 용) ======
    private var virtualHistoryStack: [URL] = []
    private var virtualCurrentIndex: Int = -1
    internal var isUsingVirtualHistory: Bool = false

    // 네비 직렬화/진행 상태
    private var isNavigating: Bool = false

    // 탭 디바운스 (빠른 연타 안정화)
    private var lastNavTapAt: TimeInterval = 0
    private let navTapMinInterval: TimeInterval = 0.22 // 220ms 최소 간격

    // 지연 복원 세션
    var pendingSession: WebViewSession?

    // 기본 커스텀(백업) 히스토리
    private var historyStack: [URL] = []
    private var currentIndexInStack: Int = -1

    // 세션 복원 중 플래그
    private(set) var isRestoringSession: Bool = false
    func beginSessionRestore() {
        isRestoringSession = true
        isNavigating = false
        dbg("🧭 RESTORE 시작 (가상히스토리 \(isUsingVirtualHistory ? "ON" : "OFF"))")
    }
    func finishSessionRestore() {
        isRestoringSession = false
        isNavigating = false
        dbg("🧭 RESTORE 종료 (가상히스토리 유지: \(isUsingVirtualHistory ? "ON" : "OFF"))")
    }

    // ====== WKWebView 연결 및 KVO ======
    // KVO 토큰
    private var kvCanGoBack: NSKeyValueObservation?
    private var kvCanGoForward: NSKeyValueObservation?
    private var kvURL: NSKeyValueObservation?
    private var kvIsLoading: NSKeyValueObservation?
    private var kvTitle: NSKeyValueObservation?

    // 안전한 옵저버 제거
    private func removeObservers() {
        kvCanGoBack?.invalidate(); kvCanGoBack = nil
        kvCanGoForward?.invalidate(); kvCanGoForward = nil
        kvURL?.invalidate(); kvURL = nil
        kvIsLoading?.invalidate(); kvIsLoading = nil
        kvTitle?.invalidate(); kvTitle = nil
    }

    // 옵저버 설치
    private func installObservers(on webView: WKWebView) {
        // canGoBack / canGoForward : 가상 히스토리 미사용시에만 직접 반영
        kvCanGoBack = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if !self.isUsingVirtualHistory {
                    self.canGoBack = wv.canGoBack
                }
            }
        }
        kvCanGoForward = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if !self.isUsingVirtualHistory {
                    self.canGoForward = wv.canGoForward
                }
            }
        }
        // URL 변경 관찰: currentURL 동기화 (복원/가상 시에는 현재 로드 중 URL이 final과 다를 수 있음)
        kvURL = webView.observe(\.url, options: [.new]) { [weak self] wv, change in
            guard let self = self else { return }
            guard let url = change.newValue as? URL? ?? wv.url else { return }
            DispatchQueue.main.async {
                // Provisional 단계에서 nil 또는 about:blank가 올 수 있음 -> 실제 URL일 때만 반영
                if url.scheme != nil && url.absoluteString != "about:blank" {
                    self.currentURL = url
                }
            }
        }
        // 로딩 상태 관찰: 로딩 종료 근처에서 버튼 상태/스냅샷 재검
        kvIsLoading = webView.observe(\.isLoading, options: [.new]) { [weak self] wv, change in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.isUsingVirtualHistory {
                    // 가상 모드에서는 스택 기반 계산 유지
                    self.canGoBack = self.virtualCurrentIndex > 0
                    self.canGoForward = self.virtualCurrentIndex < self.virtualHistoryStack.count - 1
                } else {
                    // 일반 모드에서는 웹뷰 상태 반영
                    self.canGoBack = wv.canGoBack
                    self.canGoForward = wv.canGoForward
                }
            }
        }
        // 타이틀 관찰 → 캐시 타이틀 최신화
        kvTitle = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let u = wv.url {
                    HistoryCacheManager.shared.cacheEntry(for: u, title: wv.title ?? "")
                }
            }
        }
    }

    weak var webView: WKWebView? {
        didSet {
            // 이전 옵저버 해제
            if oldValue !== webView {
                removeObservers()
            }

            if let webView {
                dbg("🔗 webView 연결됨: canGoBack=\(webView.canGoBack) canGoForward=\(webView.canGoForward)")
                installObservers(on: webView) // ✅ 연결 즉시 옵저버 설치
            }
            // 지연 복원 되어 있을 경우 최적화된 복원 실행
            if let _ = webView, let session = pendingSession {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.executeOptimizedRestore(session: session)
                }
            }
        }
    }

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

    // MARK: - 세션 저장/복원
    func saveSession() -> WebViewSession? {
        if let _ = webView {
            let urls = historyURLs.compactMap { URL(string: $0) }
            let idx = currentHistoryIndex
            guard !urls.isEmpty, idx >= 0, idx < urls.count else {
                dbg("💾 세션 저장 실패: webView 히스토리 없음")
                return nil
            }
            let urlList = urls.map { $0.absoluteString }.joined(separator: ", ")
            dbg("💾 세션 저장(webView): \(urls.count) URLs, 인덱스 \(idx) | urls=[\(urlList)]")
            return WebViewSession(urls: urls, currentIndex: idx)
        }

        if isUsingVirtualHistory {
            guard !virtualHistoryStack.isEmpty, virtualCurrentIndex >= 0 else {
                dbg("💾 세션 저장 실패: 가상 히스토리 없음")
                return nil
            }
            let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
            dbg("💾 세션 저장(가상): \(virtualHistoryStack.count) URLs, 인덱스 \(virtualCurrentIndex) | urls=[\(urlList)]")
            return WebViewSession(urls: virtualHistoryStack, currentIndex: virtualCurrentIndex)
        }

        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 또는 인덱스 없음")
            return nil
        }
        let urlList = historyStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("💾 세션 저장(fallback): \(historyStack.count) URLs, 인덱스 \(currentIndexInStack) | urls=[\(urlList)]")
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }

    func restoreSession(_ session: WebViewSession) {
        beginSessionRestore()
        
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, session.urls.count - 1))
        
        if !urls.isEmpty && urls.indices.contains(targetIndex) {
            // 가상 스택/백업 스택 모두 동기화
            virtualHistoryStack = urls
            virtualCurrentIndex = targetIndex
            isUsingVirtualHistory = true
            
            historyStack = urls
            currentIndexInStack = targetIndex
            
            pendingSession = session
            
            currentURL = urls[targetIndex]
            canGoBack = targetIndex > 0
            canGoForward = targetIndex < urls.count - 1
            let urlList = urls.map { $0.absoluteString }.joined(separator: ", ")
            dbg("🧭 RESTORE 준비: \(urls.count) URLs, 목표 idx \(targetIndex) | currentURL=\(urls[targetIndex].absoluteString) | canGoBack=\(canGoBack) canGoForward=\(canGoForward) | urls=[\(urlList)]")
        } else {
            currentURL = nil
            finishSessionRestore()
            dbg("🧭 RESTORE 실패: 유효한 URL/인덱스 없음")
        }
    }

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
        currentURL = targetURL
        isNavigating = true
        let urlList = urls.map { $0.absoluteString }.joined(separator: ", ")
        dbg("🧭 RESTORE 실행: 마지막 페이지만 로드 → idx \(targetIndex) | \(targetURL.absoluteString) | currentURL=\(currentURL?.absoluteString ?? "nil") | canGoBack=\(canGoBack) canGoForward=\(canGoForward) | urls=[\(urlList)]")
        
        onLoadCompletion = { [weak self] in
            guard let self = self else { return }
            self.virtualCurrentIndex = targetIndex
            self.canGoBack = targetIndex > 0
            self.canGoForward = targetIndex < urls.count - 1
            if let url = webView.url {
                self.currentURL = url
            }
            self.isNavigating = false
            
            self.pendingSession = nil
            self.finishSessionRestore()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.navigationDidFinish.send(())
                let urlList = self.virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
                self.dbg("🧭 RESTORE 완료 신호 전송 (navigationDidFinish) | currentURL=\(self.currentURL?.absoluteString ?? "nil") | canGoBack=\(self.canGoBack) canGoForward=\(self.canGoForward) | urls=[\(urlList)]")
                self.logHistorySnapshot(reason: "RESTORE")
            }
        }
        
        webView.load(URLRequest(url: targetURL))
        HistoryCacheManager.shared.cacheEntry(for: targetURL)
    }

    // MARK: - 히스토리 조회 유틸
    var historyURLs: [String] {
        if isUsingVirtualHistory {
            return virtualHistoryStack.map { $0.absoluteString }
        }
        if let webView = webView {
            let back = webView.backForwardList.backList.map { $0.url.absoluteString }
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
            let back = webView.backForwardList.backList.map { $0.url }
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

    // MARK: - 하단 버튼 액션(안정화)
    func goBack() {
        // 탭 디바운스: 너무 빠른 연타 방지
        guard !throttleTap() else {
            dbg("⬅️ 뒤로가기 차단: 연속 탭")
            return
        }
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .back)
        } else {
            // 네비 직렬화: 이미 이동 중이면 차단
            guard !isNavigating else {
                dbg("⬅️ 뒤로가기 차단: isNavigating 진행 중")
                return
            }
            isNavigating = true
            NotificationCenter.default.post(name: .init("WebViewGoBack"), object: nil)
            // iOS에서 실제 네비 완료는 delegate/didFinish에서 isNavigating=false로
        }
    }

    func goForward() {
        guard !throttleTap() else {
            dbg("➡️ 앞으로가기 차단: 연속 탭")
            return
        }
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .forward)
        } else {
            guard !isNavigating else {
                dbg("➡️ 앞으로가기 차단: isNavigating 진행 중")
                return
            }
            isNavigating = true
            NotificationCenter.default.post(name: .init("WebViewGoForward"), object: nil)
        }
    }

    func reload() {
        NotificationCenter.default.post(name: .init("WebViewReload"), object: nil)
    }

    // 탭 디바운서
    private func throttleTap() -> Bool {
        let now = CACurrentMediaTime()
        defer { lastNavTapAt = now }
        return (now - lastNavTapAt) < navTapMinInterval
    }

    private enum NavigationDirection { case back, forward }
    
    private func performVirtualNavigation(direction: NavigationDirection) {
        guard isUsingVirtualHistory, let webView = webView else {
            dbg("🧩 V-NAV 실패: 가상 히스토리 비활성 또는 webView 없음 | vhist=\(isUsingVirtualHistory) webView=\(webView != nil)")
            return
        }
        
        guard !isNavigating else {
            dbg("🧩 V-NAV 차단: 네비게이션 진행 중 | currentURL=\(currentURL?.absoluteString ?? "nil") | isNavigating=\(isNavigating)")
            return
        }
        
        let newIndex: Int
        switch direction {
        case .back:
            guard virtualCurrentIndex > 0 else {
                NotificationCenter.default.post(name: .init("WebViewNavigationBlocked"), object: nil, userInfo: ["message": "뒤로 갈 페이지가 없습니다"])
                let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
                dbg("⬅️ 가상 네비: 뒤로가기 불가 | vIndex=\(virtualCurrentIndex) | urls=[\(urlList)]")
                return
            }
            newIndex = virtualCurrentIndex - 1
        case .forward:
            guard virtualCurrentIndex < virtualHistoryStack.count - 1 else {
                NotificationCenter.default.post(name: .init("WebViewNavigationBlocked"), object: nil, userInfo: ["message": "앞으로 갈 페이지가 없습니다"])
                let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
                dbg("➡️ 가상 네비: 앞으로가기 불가 | vIndex=\(virtualCurrentIndex) vStack=\(virtualHistoryStack.count) | urls=[\(urlList)]")
                return
            }
            newIndex = virtualCurrentIndex + 1
        }
        
        let targetURL = virtualHistoryStack[newIndex]
        isNavigating = true // ✅ 직렬화: 이 줄이 중요 (중복 load 방지)
        currentURL = targetURL
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("🧩 V-NAV \(direction == .back ? "BACK" : "FWD") → idx \(newIndex) | \(targetURL.absoluteString) | currentURL=\(currentURL?.absoluteString ?? "nil") | canGoBack=\(canGoBack) canGoForward=\(canGoForward) | urls=[\(urlList)]")
        
        virtualCurrentIndex = newIndex
        canGoBack = virtualCurrentIndex > 0
        canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
        
        if webView.url != targetURL {
            webView.load(URLRequest(url: targetURL))
            HistoryCacheManager.shared.cacheEntry(for: targetURL)
        } else {
            isNavigating = false
            navigationDidFinish.send(())
            dbg("🧩 V-NAV 스킵: 동일 URL | targetURL=\(targetURL.absoluteString)")
        }
        
        let backList = Array(virtualHistoryStack.prefix(upTo: newIndex))
        let forwardList = Array(virtualHistoryStack.suffix(from: newIndex + 1))
        dbg("🧩 V-HIST SYNC: back=\(backList.count), forward=\(forwardList.count), current=\(targetURL.absoluteString) | urls=[\(urlList)]")
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("🌐 LOAD 시작 → \(webView.url?.absoluteString ?? "(pending)") | restoring=\(isRestoringSession) vhist=\(isUsingVirtualHistory) | isNavigating=\(isNavigating) | urls=[\(urlList)]")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView // 옵저버 유지 목적(재연결 시도)

        // ✅ WKWebView의 backForwardList와 virtualHistoryStack 동기화
        if isUsingVirtualHistory {
            let backList = webView.backForwardList.backList.map { $0.url }
            let currentItem = webView.backForwardList.currentItem?.url
            let forwardList = webView.backForwardList.forwardList.map { $0.url }
            let webViewHistory = backList + (currentItem.map { [$0] } ?? []) + forwardList
            
            // ✅ 가상 스택을 웹뷰 히스토리로 재동기화(리다이렉트/해시 변경 등 포함)
            if !webViewHistory.isEmpty {
                virtualHistoryStack = webViewHistory
                virtualCurrentIndex = backList.count
                canGoBack = virtualCurrentIndex > 0
                canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1
            }
        } else {
            // 일반 모드: KVO가 기본 반영하지만 didFinish에서도 최종 스냅
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
        }
        
        if let url = webView.url {
            currentURL = url
        }
        
        let title = (webView.title?.isEmpty == false) ? webView.title! : (webView.url?.host ?? "제목 없음")
        
        if let finalURL = webView.url, !isRestoringSession {
            if WebViewStateModel.globalHistory.last?.url != finalURL {
                WebViewStateModel.globalHistory.append(.init(url: finalURL, title: title, date: Date()))
                WebViewStateModel.saveGlobalHistory()
                HistoryCacheManager.shared.cacheEntry(for: finalURL, title: title)
            } else {
                // 동일 URL이라도 타이틀이 갱신되면 캐시 타이틀 업데이트
                HistoryCacheManager.shared.cacheEntry(for: finalURL, title: title)
            }
        }
        
        isNavigating = false // ✅ 직렬화 해제 지점
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("🌐 LOAD 완료 → \(webView.url?.absoluteString ?? "nil") | restoring=\(isRestoringSession) vhist=\(isUsingVirtualHistory) | currentURL=\(currentURL?.absoluteString ?? "nil") | isNavigating=\(isNavigating) | canGoBack=\(canGoBack) canGoForward=\(canGoForward) | urls=[\(urlList)]")
        logHistorySnapshot(reason: "LOAD_FINISH")
        
        onLoadCompletion?()
        onLoadCompletion = nil
        
        navigationDidFinish.send(())
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("❌ 로드 실패(Provisional): \(error.localizedDescription) | isNavigating=\(isNavigating) | urls=[\(urlList)]")
        if isRestoringSession { finishSessionRestore() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        dbg("❌ 로드 실패(Navigation): \(error.localizedDescription) | isNavigating=\(isNavigating) | urls=[\(urlList)]")
        if isRestoringSession { finishSessionRestore() }
    }

    // MARK: - 디버그/로깅
    private func dbg(_ msg: String) {
        let id = tabID?.uuidString.prefix(6) ?? "noTab"
        let currentURLStr = currentURL?.absoluteString ?? "nil"
        let vHistCount = virtualHistoryStack.count
        let vIndex = virtualCurrentIndex
        let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)] \(msg) | currentURL=\(currentURLStr) | vHistory=\(vHistCount) | vIndex=\(vIndex) | isNavigating=\(isNavigating) | urls=[\(urlList)]")
    }

    private func logHistorySnapshot(reason: String) {
        if isUsingVirtualHistory {
            let list = virtualHistoryStack.map { $0.absoluteString }
            let idx = max(0, min(virtualCurrentIndex, max(0, list.count - 1)))
            let cur = list.indices.contains(idx) ? list[idx] : "(없음)"
            let urlList = list.joined(separator: ", ")
            dbg("🧩 V-HIST(\(reason)) ⏪\(idx) ▶︎\(max(0, list.count - idx - 1)) | \(cur) | urls=[\(urlList)]")
        } else if let wv = webView {
            let back = wv.backForwardList.backList.count
            let fwd = wv.backForwardList.forwardList.count
            let cur = wv.url?.absoluteString ?? "(없음)"
            let urlList = (wv.backForwardList.backList.map { $0.url.absoluteString } + [cur] + wv.backForwardList.forwardList.map { $0.url.absoluteString }).joined(separator: ", ")
            dbg("📜 H-HIST(\(reason)) ⏪\(back) ▶︎\(fwd) | \(cur) | urls=[\(urlList)]")
        } else {
            dbg("📜 HIST(\(reason)) 웹뷰 미연결")
        }
    }

    // MARK: - 히스토리 페이지 UI
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel
        @State private var searchQuery: String = ""
        @Environment(\.dismiss) private var dismiss
        
        private var dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        private var filteredHistory: [HistoryEntry] {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return WebViewStateModel.globalHistory.sorted { $0.date > $1.date } }
            return WebViewStateModel.globalHistory
                .filter { $0.url.absoluteString.lowercased().contains(q) || $0.title.lowercased().contains(q) }
                .sorted { $0.date > $1.date }
        }

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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.currentURL = item.url
                        state.loadURLIfReady()
                        dismiss()
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
            .onReceive(state.navigationDidFinish) { _ in
                print("HistoryPage: navigationDidFinish received, URL=\(state.currentURL?.absoluteString ?? "nil"), canGoBack=\(state.canGoBack), canGoForward=\(state.canGoForward)")
            }
        }

        func delete(at offsets: IndexSet) {
            let items = filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
            WebViewStateModel.saveGlobalHistory()
            TabPersistenceManager.debugMessages.append("[\(ts())] 🧹 방문 기록 삭제: \(targets.count)개")
        }
    }

    // MARK: - 로드 편의 함수
    func loadURLIfReady() {
        guard let webView = webView, let url = currentURL else {
            dbg("🚫 loadURLIfReady 실패: webView 또는 URL 없음 | currentURL=\(currentURL?.absoluteString ?? "nil")")
            return
        }
        // 이미 동일 URL이면 불필요한 로드 방지
        if webView.url != url {
            isNavigating = true // ✅ 중복 호출 방지
            webView.load(URLRequest(url: url))
            HistoryCacheManager.shared.cacheEntry(for: url)
            let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
            dbg("🌐 loadURLIfReady: \(url.absoluteString) | urls=[\(urlList)]")
        }
    }
}
