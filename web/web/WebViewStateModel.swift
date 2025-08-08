```swift
// WebViewStateModel.swift
// WKWebView를 관리하는 상태 모델로, 웹 뷰의 네비게이션 상태, 히스토리, 세션 저장/복원 등을 처리합니다.
// 주요 수정사항:
// 1) KVO 옵저버 URL 타입 캐스팅 오류 수정
// 2) 누락된 헬퍼 메서드 추가 (historyStackIfAny, currentIndexInSafeBounds)
// 3) 경고 사항 수정 및 코드 최적화

import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 세션 스냅샷 (저장/복원에 사용)
// 웹 뷰의 히스토리와 현재 인덱스를 저장/복원하기 위한 구조체
struct WebViewSession: Codable {
    let urls: [URL] // 히스토리 URL 목록
    let currentIndex: Int // 현재 페이지 인덱스
}

// MARK: - 타임스탬프 유틸
// 디버깅 로그에 사용할 타임스탬프를 생성하는 유틸리티 함수
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS" // 시간 형식을 밀리초 단위로 설정
    return f.string(from: Date())
}

// MARK: - 히스토리 캐시 엔트리
// URL, 제목, 마지막 접근 시간을 저장하는 클래스
private class HistoryCacheEntry {
    let url: URL // 캐시된 URL
    var title: String // 페이지 제목
    var lastAccessed: Date // 마지막 접근 시간
    weak var webView: WKWebView? // 연결된 WKWebView (약한 참조)
    
    init(url: URL, title: String = "") {
        self.url = url
        self.title = title
        self.lastAccessed = Date()
    }
    
    // 마지막 접근 시간 갱신
    func updateAccess() { lastAccessed = Date() }
}

// MARK: - 히스토리 캐시 매니저
// 웹 페이지 캐시를 관리하는 싱글톤 클래스
private class HistoryCacheManager {
    static let shared = HistoryCacheManager() // 싱글톤 인스턴스
    private init() {} // 외부에서 초기화 방지
    
    private var cache: [URL: HistoryCacheEntry] = [:] // URL을 키로 한 캐시 저장소
    private let maxCacheCount = 200 // 최대 캐시 수
    
    // URL과 제목을 캐시에 저장
    func cacheEntry(for url: URL, title: String = "") {
        if let entry = cache[url] {
            if !title.isEmpty { entry.title = title } // 제목 업데이트
            entry.updateAccess() // 접근 시간 갱신
        } else {
            cache[url] = HistoryCacheEntry(url: url, title: title) // 새 엔트리 추가
            pruneIfNeeded() // 캐시 크기 조정
        }
    }
    
    // URL에 해당하는 캐시 엔트리 반환
    func entry(for url: URL) -> HistoryCacheEntry? { cache[url] }
    
    // 캐시 크기가 최대치를 초과하면 오래된 항목 제거
    private func pruneIfNeeded() {
        guard cache.count > maxCacheCount else { return }
        let sorted = cache.values.sorted(by: { $0.lastAccessed < $1.lastAccessed }) // 오래된 순으로 정렬
        let toRemove = sorted.prefix(cache.count - maxCacheCount/2) // 제거할 항목 선택
        for e in toRemove { cache.removeValue(forKey: e.url) } // 캐시에서 제거
    }
    
    // 모든 캐시 제거
    func clearCache() { cache.removeAll() }
}

// MARK: - WebViewStateModel
// WKWebView의 상태를 관리하는 주요 클래스
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID? // 탭 식별자
    let navigationDidFinish = PassthroughSubject<Void, Never>() // 네비게이션 완료 신호
    
    // 현재 URL, 변경 시 히스토리와 상태 업데이트
    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL, oldValue != url else { return } // 동일 URL 무시
            
            if !Thread.isMainThread {
                DispatchQueue.main.async { [weak self] in self?.currentURL = url } // 메인 스레드 보장
                return
            }
            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL") // 마지막 URL 저장
            dbg("URL 업데이트 → \(url.absoluteString)")
            if isRestoringSession { return } // 세션 복원 중 히스토리 업데이트 방지
            
            // 새로운 페이지 로드 시 히스토리 업데이트
            if !isInternalNavigation {
                updateHistoryStacks(with: url)
            }
            // 전역 히스토리 업데이트 (중복 방지)
            if WebViewStateModel.globalHistory.last?.url != url {
                WebViewStateModel.globalHistory.append(.init(url: url, title: url.host ?? "제목 없음", date: Date()))
                WebViewStateModel.saveGlobalHistory()
            }
        }
    }
    
    @Published var canGoBack: Bool = false // 뒤로가기 가능 여부
    @Published var canGoForward: Bool = false // 앞으로가기 가능 여부
    @Published var showAVPlayer = false // AVPlayer 표시 여부
    
    // 가상 히스토리 관리
    private var virtualHistoryStack: [URL] = [] // 가상 히스토리 스택
    private var virtualCurrentIndex: Int = -1 // 현재 가상 히스토리 인덱스
    internal var isUsingVirtualHistory: Bool = false // 가상 히스토리 사용 여부
    
    private var isInternalNavigation: Bool = false // 내부 네비게이션 플래그
    private var isNavigating: Bool = false // 네비게이션 진행 상태
    private var navigationStartTime: TimeInterval = 0 // 네비게이션 시작 시간
    private var lastNavTapAt: TimeInterval = 0 // 마지막 네비게이션 탭 시간
    private let navTapMinInterval: TimeInterval = 0.1 // 네비게이션 탭 간 최소 간격 (100ms)
    
    var pendingSession: WebViewSession? // 복원 대기 중인 세션
    
    // 기본 히스토리 스택
    private var historyStack: [URL] = [] // 커스텀 히스토리 스택
    private var currentIndexInStack: Int = -1 // 현재 히스토리 인덱스
    
    private(set) var isRestoringSession: Bool = false // 세션 복원 상태
    
    // 세션 복원 시작
    func beginSessionRestore() {
        isRestoringSession = true
        isNavigating = false
        dbg("🧭 RESTORE 시작")
    }
    
    // 세션 복원 종료
    func finishSessionRestore() {
        isRestoringSession = false
        isNavigating = false
        dbg("🧭 RESTORE 종료")
    }
    
    // 히스토리 스택 업데이트
    private func updateHistoryStacks(with url: URL) {
        // 커스텀 히스토리 업데이트
        if currentIndexInStack < historyStack.count - 1 {
            historyStack = Array(historyStack.prefix(upTo: currentIndexInStack + 1)) // 이후 히스토리 제거
        }
        historyStack.append(url) // 새 URL 추가
        currentIndexInStack = historyStack.count - 1 // 인덱스 업데이트
        
        // 가상 히스토리 업데이트
        if isUsingVirtualHistory {
            if virtualCurrentIndex < virtualHistoryStack.count - 1 {
                virtualHistoryStack = Array(virtualHistoryStack.prefix(upTo: virtualCurrentIndex + 1)) // 이후 히스토리 제거
            }
            virtualHistoryStack.append(url) // 새 URL 추가
            virtualCurrentIndex = virtualHistoryStack.count - 1 // 인덱스 업데이트
            updateNavigationButtons() // 버튼 상태 갱신
            
            let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
            dbg("🧩 V-HIST 업데이트: idx=\(virtualCurrentIndex), stack=\(virtualHistoryStack.count) | urls=[\(urlList)]")
        }
    }
    
    // 네비게이션 버튼 상태 업데이트
    private func updateNavigationButtons() {
        if isUsingVirtualHistory {
            canGoBack = virtualCurrentIndex > 0 // 뒤로가기 가능 여부
            canGoForward = virtualCurrentIndex < virtualHistoryStack.count - 1 // 앞으로가기 가능 여부
        } else {
            if webView != nil {
                canGoBack = webView?.canGoBack ?? false // WKWebView의 뒤로가기 상태
                canGoForward = webView?.canGoForward ?? false // WKWebView의 앞으로가기 상태
            }
        }
    }
    
    // 현재 히스토리 스택 반환
    func historyStackIfAny() -> [URL] {
        if isUsingVirtualHistory {
            return virtualHistoryStack // 가상 히스토리 반환
        }
        if let webView = webView {
            let back = webView.backForwardList.backList.map { $0.url } // 뒤로가기 목록
            let current = webView.backForwardList.currentItem.map { [$0.url] } ?? [] // 현재 페이지
            let forward = webView.backForwardList.forwardList.map { $0.url } // 앞으로가기 목록
            return back + current + forward // 전체 히스토리 반환
        }
        return historyStack // 기본 히스토리 반환
    }
    
    // 안전한 인덱스 범위 반환
    func currentIndexInSafeBounds() -> Int {
        if isUsingVirtualHistory {
            return max(0, min(virtualCurrentIndex, max(0, virtualHistoryStack.count - 1))) // 가상 히스토리 인덱스
        }
        if let webView = webView {
            return webView.backForwardList.backList.count // WKWebView의 뒤로가기 수
        }
        return max(0, min(currentIndexInStack, max(0, historyStack.count - 1))) // 기본 히스토리 인덱스
    }
    
    // MARK: - KVO 관리
    private var kvCanGoBack: NSKeyValueObservation? // 뒤로가기 KVO
    private var kvCanGoForward: NSKeyValueObservation? // 앞으로가기 KVO
    private var kvURL: NSKeyValueObservation? // URL KVO
    private var kvIsLoading: NSKeyValueObservation? // 로딩 상태 KVO
    private var kvTitle: NSKeyValueObservation? // 제목 KVO
    
    // 모든 KVO 옵저버 제거
    private func removeObservers() {
        kvCanGoBack?.invalidate(); kvCanGoBack = nil
        kvCanGoForward?.invalidate(); kvCanGoForward = nil
        kvURL?.invalidate(); kvURL = nil
        kvIsLoading?.invalidate(); kvIsLoading = nil
        kvTitle?.invalidate(); kvTitle = nil
    }
    
    // WKWebView에 KVO 옵저버 설치
    private func installObservers(on webView: WKWebView) {
        // 뒤로가기 상태 관찰
        kvCanGoBack = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
            guard self != nil else { return }
            DispatchQueue.main.async {
                if !self!.isUsingVirtualHistory {
                    self!.canGoBack = wv.canGoBack // 가상 히스토리 미사용 시 상태 업데이트
                }
            }
        }
        
        // 앞으로가기 상태 관찰
        kvCanGoForward = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
            guard self != nil else { return }
            DispatchQueue.main.async {
                if !self!.isUsingVirtualHistory {
                    self!.canGoForward = wv.canGoForward // 가상 히스토리 미사용 시 상태 업데이트
                }
            }
        }
        
        // URL 변경 관찰
        kvURL = webView.observe(\.url, options: [.new]) { [weak self] wv, change in
            guard let self = self else { return }
            guard let url: URL? = change.newValue as? URL ?? wv.url else { return } // 명시적 URL? 타입
            
            DispatchQueue.main.async {
                if let validURL = url, // url은 URL?로 처리됨
                   validURL.scheme != nil,
                   validURL.absoluteString != "about:blank",
                   self.currentURL != validURL {
                    self.isInternalNavigation = true
                    self.currentURL = validURL
                    self.isInternalNavigation = false
                }
            }
        }
        
        // 로딩 상태 관찰
        kvIsLoading = webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            guard self != nil else { return }
            DispatchQueue.main.async {
                self!.updateNavigationButtons() // 네비게이션 버튼 갱신
            }
        }
        
        // 제목 변경 관찰
        kvTitle = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard self != nil else { return }
            DispatchQueue.main.async {
                if let u = wv.url {
                    HistoryCacheManager.shared.cacheEntry(for: u, title: wv.title ?? "") // 캐시 업데이트
                }
            }
        }
    }
    
    // WKWebView 속성
    weak var webView: WKWebView? {
        didSet {
            if oldValue !== webView {
                removeObservers() // 기존 옵저버 제거
            }
            if let webView {
                dbg("🔗 webView 연결됨")
                installObservers(on: webView) // 새 옵저버 설치
                updateNavigationButtons() // 버튼 상태 갱신
            }
            
            // 대기 중인 세션 복원
            if webView != nil, let session = pendingSession {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.executeOptimizedRestore(session: session)
                }
            }
        }
    }
    
    var onLoadCompletion: (() -> Void)? // 로드 완료 콜백
    
    // 히스토리 항목 구조체
    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID() // 고유 식별자
        let url: URL // 페이지 URL
        let title: String // 페이지 제목
        let date: Date // 방문 시간
    }
    
    static var globalHistory: [HistoryEntry] = [] { // 전역 히스토리
        didSet { saveGlobalHistory() } // 변경 시 저장
    }
    
    // 전역 히스토리 초기화
    func clearHistory() {
        WebViewStateModel.globalHistory = []
        WebViewStateModel.saveGlobalHistory()
        HistoryCacheManager.shared.clearCache()
        dbg("🧹 전역 방문 기록 삭제")
    }
    
    // 전역 히스토리 저장
    private static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
        }
    }
    
    // 전역 히스토리 로드
    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
        }
    }
    
    // MARK: - 세션 저장/복원
    // 현재 세션 저장
    func saveSession() -> WebViewSession? {
        if isUsingVirtualHistory {
            guard !virtualHistoryStack.isEmpty, virtualCurrentIndex >= 0 else {
                dbg("💾 세션 저장 실패: 가상 히스토리 없음")
                return nil
            }
            let urlList = virtualHistoryStack.map { $0.absoluteString }.joined(separator: ", ")
            dbg("💾 세션 저장(가상): \(virtualHistoryStack.count) URLs, 인덱스 \(virtualCurrentIndex) | urls=[\(urlList)]")
            return WebViewSession(urls: virtualHistoryStack, currentIndex: virtualCurrentIndex)
        }
        
        if webView != nil {
            let urls = historyURLs.compactMap { URL(string: $0) }
            let idx = currentHistoryIndex
            guard !urls.isEmpty, idx >= 0, idx < urls.count else {
                dbg("💾 세션 저장 실패: webView 히스토리 없음")
                return nil
            }
            dbg("💾 세션 저장(webView): \(urls.count) URLs, 인덱스 \(idx)")
            return WebViewSession(urls: urls, currentIndex: idx)
        }
        guard !historyStack.isEmpty, currentIndexInStack >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 없음")
            return nil
        }
        dbg("💾 세션 저장(fallback): \(historyStack.count) URLs")
        return WebViewSession(urls: historyStack, currentIndex: currentIndexInStack)
    }
    
    // 세션 복원
    func restoreSession(_ session: WebViewSession) {
        beginSessionRestore()
        
        let urls = session.urls
        let targetIndex = max(0, min(session.currentIndex, urls.count - 1))
        
        if !urls.isEmpty && urls.indices.contains(targetIndex) {
            virtualHistoryStack = urls // 가상 히스토리 설정
            virtualCurrentIndex = targetIndex // 가상 인덱스 설정
            isUsingVirtualHistory = true // 가상 히스토리 활성화
            
            historyStack = urls // 기본 히스토리 설정
            currentIndexInStack = targetIndex // 기본 인덱스 설정
            
            pendingSession = session // 대기 세션 설정
            
            isInternalNavigation = true // 중복 히스토리 방지
            currentURL = urls[targetIndex] // 현재 URL 설정
            isInternalNavigation = false
            
            updateNavigationButtons() // 버튼 상태 갱신
            
            let urlList = urls.map { $0.absoluteString }.joined(separator: ", ")
            dbg("🧭 RESTORE 준비: \(urls.count) URLs, 목표 idx \(targetIndex) | urls=[\(urlList)]")
        } else {
            currentURL = nil
            finishSessionRestore()
            dbg("🧭 RESTORE 실패: 유효한 URL/인덱스 없음")
        }
    }
    
    // 최적화된 세션 복원 실행
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
        isNavigating = true
        navigationStartTime = CACurrentMediaTime()
        
        dbg("🧭 RESTORE 실행: \(targetURL.absoluteString)")
        
        onLoadCompletion = { [weak self] in
            guard let self = self else { return }
            
            self.virtualCurrentIndex = targetIndex // 가상 인덱스 갱신
            self.updateNavigationButtons() // 버튼 상태 갱신
            
            if let url = webView.url {
                self.isInternalNavigation = true
                self.currentURL = url // URL 동기화
                self.isInternalNavigation = false
            }
            
            self.isNavigating = false
            self.pendingSession = nil
            self.finishSessionRestore()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.navigationDidFinish.send(())
                self.dbg("🧭 RESTORE 완료")
            }
        }
        
        webView.load(URLRequest(url: targetURL)) // URL 로드
        HistoryCacheManager.shared.cacheEntry(for: targetURL) // 캐시 업데이트
    }
    
    // MARK: - 히스토리 조회 유틸
    // 현재 히스토리 URL 목록 반환
    var historyURLs: [String] {
        if isUsingVirtualHistory {
            return virtualHistoryStack.map { $0.absoluteString } // 가상 히스토리 URL
        }
        if let webView = webView {
            let back = webView.backForwardList.backList.map { $0.url.absoluteString } // 뒤로가기 목록
            let current = webView.backForwardList.currentItem.map { [$0.url.absoluteString] } ?? [] // 현재 페이지
            let forward = webView.backForwardList.forwardList.map { $0.url.absoluteString } // 앞으로가기 목록
            return back + current + forward
        }
        return historyStack.map { $0.absoluteString } // 기본 히스토리 URL
    }
    
    // 현재 히스토리 인덱스 반환
    var currentHistoryIndex: Int {
        if isUsingVirtualHistory {
            return max(0, min(virtualCurrentIndex, max(0, virtualHistoryStack.count - 1))) // 가상 인덱스
        }
        if let webView = webView { return webView.backForwardList.backList.count } // WKWebView 인덱스
        return max(0, min(currentIndexInStack, max(0, historyStack.count - 1))) // 기본 인덱스
    }
    
    // MARK: - 네비게이션 액션
    // 뒤로가기
    func goBack() {
        guard !throttleTap() else {
            dbg("⬅️ 뒤로가기 차단: 연속 탭")
            return
        }
        
        guard !isNavigating else {
            dbg("⬅️ 뒤로가기 차단: 네비게이션 진행 중")
            return
        }
        
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .back) // 가상 히스토리 뒤로가기
        } else {
            isNavigating = true
            navigationStartTime = CACurrentMediaTime()
            NotificationCenter.default.post(name: .init("WebViewGoBack"), object: nil) // 네이티브 뒤로가기
            dbg("⬅️ 네이티브 뒤로가기 실행")
        }
    }
    
    // 앞으로가기
    func goForward() {
        guard !throttleTap() else {
            dbg("➡️ 앞으로가기 차단: 연속 탭")
            return
        }
        
        guard !isNavigating else {
            dbg("➡️ 앞으로가기 차단: 네비게이션 진행 중")
            return
        }
        
        if isUsingVirtualHistory {
            performVirtualNavigation(direction: .forward) // 가상 히스토리 앞으로가기
        } else {
            isNavigating = true
            navigationStartTime = CACurrentMediaTime()
            NotificationCenter.default.post(name: .init("WebViewGoForward"), object: nil) // 네이티브 앞으로가기
            dbg("➡️ 네이티브 앞으로가기 실행")
        }
    }
    
    // 페이지 새로고침
    func reload() {
        NotificationCenter.default.post(name: .init("WebViewReload"), object: nil) // 새로고침 알림
    }
    
    // 네비게이션 탭 디바운스 체크
    private func throttleTap() -> Bool {
        let now = CACurrentMediaTime()
        defer { lastNavTapAt = now }
        return (now - lastNavTapAt) < navTapMinInterval // 100ms 이내 연속 탭 방지
    }
    
    // 네비게이션 방향 열거형
    private enum NavigationDirection { case back, forward }
    
    // 가상 네비게이션 수행
    private func performVirtualNavigation(direction: NavigationDirection) {
        guard isUsingVirtualHistory, let webView = webView else {
            dbg("🧩 V-NAV 실패: 가상 히스토리 비활성 또는 webView 없음")
            return
        }
        
        let newIndex: Int
        switch direction {
        case .back:
            guard virtualCurrentIndex > 0 else {
                NotificationCenter.default.post(name: .init("WebViewNavigationBlocked"),
                                               object: nil,
                                               userInfo: ["message": "뒤로 갈 페이지가 없습니다"])
                dbg("⬅️ 가상 네비: 뒤로가기 불가 (인덱스: \(virtualCurrentIndex))")
                return
            }
            newIndex = virtualCurrentIndex - 1
        case .forward:
            guard virtualCurrentIndex < virtualHistoryStack.count - 1 else {
                NotificationCenter.default.post(name: .init("WebViewNavigationBlocked"),
                                               object: nil,
                                               userInfo: ["message": "앞으로 갈 페이지가 없습니다"])
                dbg("➡️ 가상 네비: 앞으로가기 불가 (인덱스: \(virtualCurrentIndex)/\(virtualHistoryStack.count-1))")
                return
            }
            newIndex = virtualCurrentIndex + 1
        }
        
        let targetURL = virtualHistoryStack[newIndex]
        isNavigating = true
        navigationStartTime = CACurrentMediaTime()
        
        virtualCurrentIndex = newIndex // 인덱스 업데이트
        updateNavigationButtons() // 버튼 상태 갱신
        
        dbg("🧩 V-NAV \(direction == .back ? "BACK" : "FWD") → idx \(newIndex) (\(targetURL.absoluteString))")
        
        // 동일 URL이면 로드 생략
        if webView.url == targetURL {
            isNavigating = false
            navigationDidFinish.send(())
            dbg("🧩 V-NAV 스킵: 동일 URL")
        } else {
            isInternalNavigation = true
            currentURL = targetURL // URL 업데이트
            isInternalNavigation = false
            webView.load(URLRequest(url: targetURL)) // URL 로드
            HistoryCacheManager.shared.cacheEntry(for: targetURL) // 캐시 업데이트
        }
    }
    
    // MARK: - WKNavigationDelegate
    // 네비게이션 시작
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        dbg("🌐 LOAD 시작 → \(webView.url?.absoluteString ?? "(pending)")")
    }
    
    // 네비게이션 완료
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView // 웹뷰 연결 유지
        
        // 가상 히스토리 동기화
        if isUsingVirtualHistory && !isRestoringSession {
            let backList = webView.backForwardList.backList.map { $0.url }
            let currentItem = webView.backForwardList.currentItem?.url
            let forwardList = webView.backForwardList.forwardList.map { $0.url }
            let webViewHistory = backList + (currentItem.map { [$0] } ?? []) + forwardList
            
            // 웹뷰 히스토리가 더 정확할 경우 업데이트
            if !webViewHistory.isEmpty && webViewHistory.count >= virtualHistoryStack.count {
                let oldCount = virtualHistoryStack.count
                virtualHistoryStack = webViewHistory
                virtualCurrentIndex = backList.count
                dbg("🧩 V-HIST 동기화: \(oldCount) → \(webViewHistory.count) URLs")
            }
        }
        
        updateNavigationButtons() // 버튼 상태 갱신
        
        if let url = webView.url {
            let title = (webView.title?.isEmpty == false) ? webView.title! : (url.host ?? "제목 없음")
            
            // 전역 히스토리 업데이트
            if !isRestoringSession && WebViewStateModel.globalHistory.last?.url != url {
                WebViewStateModel.globalHistory.append(.init(url: url, title: title, date: Date()))
                WebViewStateModel.saveGlobalHistory()
            }
            
            HistoryCacheManager.shared.cacheEntry(for: url, title: title) // 캐시 업데이트
            
            // URL 동기화
            if currentURL != url {
                isInternalNavigation = true
                currentURL = url
                isInternalNavigation = false
            }
        }
        
        isNavigating = false // 네비게이션 완료
        
        let navigationTime = CACurrentMediaTime() - navigationStartTime
        dbg("🌐 LOAD 완료 → \(webView.url?.absoluteString ?? "nil") (소요시간: \(String(format: "%.3f", navigationTime))초)")
        
        onLoadCompletion?() // 로드 완료 콜백 실행
        onLoadCompletion = nil
        
        navigationDidFinish.send(()) // 네비게이션 완료 신호
    }
    
    // 네비게이션 실패 (Provisional)
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        dbg("❌ 로드 실패(Provisional): \(error.localizedDescription)")
        if isRestoringSession { finishSessionRestore() }
    }
    
    // 네비게이션 실패 (Navigation)
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isNavigating = false
        dbg("❌ 로드 실패(Navigation): \(error.localizedDescription)")
        if isRestoringSession { finishSessionRestore() }
    }
    
    // MARK: - 기타 메서드들
    // URL 로드 (조건 확인 후)
    func loadURLIfReady() {
        guard let webView = webView, let url = currentURL else {
            dbg("🚫 loadURLIfReady 실패: webView 또는 URL 없음")
            return
        }
        
        if webView.url != url {
            isNavigating = true
            navigationStartTime = CACurrentMediaTime()
            webView.load(URLRequest(url: url)) // URL 로드
            HistoryCacheManager.shared.cacheEntry(for: url) // 캐시 업데이트
            dbg("🌐 loadURLIfReady: \(url.absoluteString)")
        }
    }
    
    // 디버깅 로그 출력
    private func dbg(_ msg: String) {
        let id = tabID?.uuidString.prefix(6) ?? "noTab"
        let timestamp = ts()
        print("[\(timestamp)][\(id)] \(msg)")
    }
    
    // MARK: - 히스토리 페이지 UI
    // 방문 기록을 표시하는 SwiftUI 뷰
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel // 상태 모델
        @State private var searchQuery: String = "" // 검색 쿼리
        @Environment(\.dismiss) private var dismiss // 뷰 닫기 환경 변수
        
        // 날짜 포맷터
        private var dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()
        
        // 검색 쿼리에 따라 필터링된 히스토리
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
                            .font(.headline) // 제목 표시
                        Text(item.url.absoluteString)
                            .font(.caption) // URL 표시
                            .foregroundColor(.gray)
                        Text(dateFormatter.string(from: item.date))
                            .font(.caption2) // 방문 시간 표시
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.currentURL = item.url // 선택한 URL로 이동
                        state.loadURLIfReady()
                        dismiss() // 뷰 닫기
                    }
                }
                .onDelete(perform: delete) // 항목 삭제 가능
            }
            .navigationTitle("방문 기록") // 네비게이션 제목
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always)) // 검색바
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("모두 지우기") {
                        WebViewStateModel.globalHistory.removeAll() // 전체 히스토리 삭제
                        WebViewStateModel.saveGlobalHistory()
                    }
                }
            }
            .onReceive(state.navigationDidFinish) { _ in
                print("HistoryPage: navigationDidFinish received") // 네비게이션 완료 로그
            }
        }
        
        // 히스토리 항목 삭제
        func delete(at offsets: IndexSet) {
            let items = filteredHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
            WebViewStateModel.saveGlobalHistory()
        }
    }
}
