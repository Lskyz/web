//
//  WebViewStateModel.swift
//  페이지 고유번호 기반 히스토리 시스템 (기존 구조 유지하며 동기화 강화)
//  ✨ CustomWebView와 호환되는 스와이프-버튼 동기화 개선
//  🖥️ 강화된 데스크탑 모드 지원
//

import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 페이지 식별자 (제목, 주소, 시간 포함)
struct PageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let url: URL
    var title: String
    let timestamp: Date
    var lastAccessed: Date
    
    init(url: URL, title: String = "") {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? (url.host ?? "제목 없음") : title
        self.timestamp = Date()
        self.lastAccessed = Date()
    }
    
    mutating func updateTitle(_ newTitle: String) {
        if !newTitle.isEmpty {
            title = newTitle
        }
        lastAccessed = Date()
    }
    
    mutating func updateAccess() {
        lastAccessed = Date()
    }
}

// MARK: - 간단한 히스토리 세션 
struct WebViewSession: Codable {
    let pageRecords: [PageRecord]
    let currentIndex: Int
    let sessionId: UUID
    let createdAt: Date
    
    init(pageRecords: [PageRecord], currentIndex: Int) {
        self.pageRecords = pageRecords
        self.currentIndex = currentIndex
        self.sessionId = UUID()
        self.createdAt = Date()
    }
    
    // 기존 시스템과의 호환성을 위한 computed properties
    var urls: [URL] { pageRecords.map { $0.url } }
}

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - WebViewStateModel (기존 구조 유지하며 동기화 강화)
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {

    var tabID: UUID?
    
    // 페이지 기록 기반 히스토리
    @Published private var pageHistory: [PageRecord] = []
    @Published private var currentPageIndex: Int = -1
    
    // ✨ 로딩 상태 관리
    @Published var isLoading: Bool = false {
        didSet {
            if oldValue != isLoading {
                dbg("📡 로딩 상태 변경: \(oldValue) → \(isLoading)")
            }
        }
    }
    
    @Published var loadingProgress: Double = 0.0
    
    let navigationDidFinish = PassthroughSubject<Void, Never>()

    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }

            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            dbg("🎯 currentURL 업데이트 → \(url.absoluteString) | 이전: \(oldValue?.absoluteString ?? "nil")")

            // ✅ 콜스택 추적 로그
            dbg("📞 === 호출 스택 추적 ===")
            Thread.callStackSymbols.prefix(6).enumerated().forEach { index, symbol in
                dbg("📞[\(index)] \(symbol)")
            }
            dbg("📞 === 스택 추적 끝 ===")

            // ✅ 웹뷰 로드 조건 개선
            let shouldLoad = url != oldValue && 
                           !isRestoringSession &&
                           !isNavigatingFromWebView &&
                           !isHistoryNavigationActive()
            
            dbg("🤔 webView.load 여부 판단:")
            dbg("🤔   url != oldValue: \(url != oldValue)")
            dbg("🤔   !isRestoringSession: \(!isRestoringSession)")
            dbg("🤔   !isNavigatingFromWebView: \(!isNavigatingFromWebView)")
            dbg("🤔   !isHistoryNavigationActive(): \(!isHistoryNavigationActive())")
            dbg("🤔   shouldLoad: \(shouldLoad)")
            
            if shouldLoad {
                if let webView = webView {
                    webView.load(URLRequest(url: url))
                    dbg("🌐 주소창에서 웹뷰 로드: \(url.absoluteString)")
                } else {
                    dbg("⚠️ 웹뷰가 없어서 로드 불가")
                }
            } else {
                dbg("⛔️ webView.load 생략됨 - 네비게이션 중")
            }
        }
    }
    
    // ✅ 웹뷰 내부 네비게이션 플래그
    internal var isNavigatingFromWebView: Bool = false {
        didSet {
            if oldValue != isNavigatingFromWebView {
                dbg("🏁 isNavigatingFromWebView: \(oldValue) → \(isNavigatingFromWebView)")
            }
        }
    }
    
    // 리다이렉트 감지용
    private var redirectionChain: [URL] = []
    private var redirectionStartTime: Date?
    
    // ✅ 강화된 히스토리 네비게이션 플래그
    private var isHistoryNavigation: Bool = false {
        didSet {
            if oldValue != isHistoryNavigation {
                dbg("🏁 isHistoryNavigation: \(oldValue) → \(isHistoryNavigation)")
                if isHistoryNavigation {
                    historyNavigationStartTime = Date()
                    dbg("⏰ 히스토리 네비게이션 시작 시간 기록")
                } else {
                    historyNavigationStartTime = nil
                    dbg("⏰ 히스토리 네비게이션 시간 초기화")
                }
            }
        }
    }
    
    private var historyNavigationStartTime: Date?
    
    // ✅ 스와이프 제스처 관련 추가 플래그
    private var swipeDetectedTargetIndex: Int? = nil
    private var swipeConfirmationTimer: Timer?

    @Published var canGoBack: Bool = false {
        didSet {
            if oldValue != canGoBack {
                dbg("canGoBack 업데이트: \(oldValue) → \(canGoBack)")
            }
        }
    }
    @Published var canGoForward: Bool = false {
        didSet {
            if oldValue != canGoForward {
                dbg("canGoForward 업데이트: \(oldValue) → \(canGoForward)")
            }
        }
    }
    @Published var showAVPlayer = false
    
    // ✨ 강화된 데스크탑 모드 상태
    @Published var isDesktopMode: Bool = false {
        didSet {
            if oldValue != isDesktopMode {
                dbg("🖥️ 데스크탑 모드 변경: \(oldValue) → \(isDesktopMode)")
                applyDesktopModeChanges()
            }
        }
    }

    // 복원 상태 관리
    private(set) var isRestoringSession: Bool = false {
        didSet {
            if oldValue != isRestoringSession {
                dbg("🏁 isRestoringSession: \(oldValue) → \(isRestoringSession)")
            }
        }
    }
    
    weak var webView: WKWebView? {
        didSet {
            if webView != nil {
                dbg("🔗 webView 연결됨")
                DispatchQueue.main.async {
                    self.updateNavigationState()
                    self.dbg("🔧 WebView 연결 후 상태 강제 적용: back=\(self.canGoBack), forward=\(self.canGoForward)")
                    
                    // ✨ 데스크탑 모드가 활성화되어 있다면 즉시 적용
                    if self.isDesktopMode {
                        self.applyDesktopModeChanges()
                    }
                }
            }
        }
    }

    // 기존 방문기록 구조체 유지
    struct HistoryEntry: Identifiable, Hashable, Codable {
        var id = UUID()
        let url: URL
        let title: String
        let date: Date
    }

    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }

    // ✨ 로딩 중지 메서드
    func stopLoading() {
        webView?.stopLoading()
        isLoading = false
        resetNavigationFlags()
        dbg("⏹️ 로딩 중지")
    }

    func clearHistory() {
        WebViewStateModel.globalHistory = []
        WebViewStateModel.saveGlobalHistory()
        pageHistory.removeAll()
        currentPageIndex = -1
        resetNavigationFlags()
        updateNavigationState()
        dbg("🧹 전체 히스토리 삭제")
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

    // MARK: - ✅ 강화된 네비게이션 상태 관리
    
    private func resetNavigationFlags() {
        isHistoryNavigation = false
        historyNavigationStartTime = nil
        swipeDetectedTargetIndex = nil
        swipeConfirmationTimer?.invalidate()
        swipeConfirmationTimer = nil
        dbg("🔄 네비게이션 플래그 초기화")
    }
    
    private func isHistoryNavigationActive() -> Bool {
        // 기본 플래그 체크
        if isHistoryNavigation {
            dbg("✅ 히스토리 네비게이션 활성: isHistoryNavigation = true")
            return true
        }
        
        // 시간 기반 체크
        if let startTime = historyNavigationStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 2.0 {
                dbg("✅ 히스토리 네비게이션 활성: 시작 후 \(elapsed)초 경과")
                return true
            } else {
                dbg("⏰ 히스토리 네비게이션 타임아웃: \(elapsed)초 경과, 플래그 자동 해제")
                isHistoryNavigation = false
                historyNavigationStartTime = nil
                return false
            }
        }
        
        return false
    }

    // MARK: - 새로운 페이지 기록 시스템
    
    private func addNewPage(url: URL, title: String = "") {
        dbg("📋 === addNewPage 호출 상세 분석 ===")
        dbg("📋 추가하려는 URL: \(url.absoluteString)")
        dbg("📋 추가하려는 제목: \(title)")
        
        // ✅ 히스토리 네비게이션 중인지 체크
        if isHistoryNavigationActive() {
            dbg("🚫 히스토리 네비게이션 활성 중 - 새 페이지 추가 방지")
            dbg("📋 === addNewPage 호출 분석 끝 (추가 안함) ===")
            return
        }
        
        // 현재 위치 이후의 forward 기록 제거
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🧹 Forward 히스토리 정리: \(removedCount)개 제거, \(pageHistory.count)개 남음")
        }
        
        let newRecord = PageRecord(url: url, title: title)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // 최대 50개 유지
        if pageHistory.count > 50 {
            pageHistory.removeFirst()
            currentPageIndex -= 1
            dbg("🧹 히스토리 크기 제한: 첫 페이지 제거")
        }
        
        updateNavigationState()
        dbg("📄 ✅ 새 페이지 추가 완료: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] 인덱스: \(currentPageIndex)/\(pageHistory.count)")
        dbg("📋 === addNewPage 호출 분석 끝 (추가 완료) ===")
    }
    
    private func updateNavigationState() {
        let oldBack = canGoBack
        let oldForward = canGoForward
        
        canGoBack = currentPageIndex > 0
        canGoForward = currentPageIndex < pageHistory.count - 1
        
        if oldBack != canGoBack || oldForward != canGoForward {
            dbg("🔄 네비게이션 상태 업데이트: back=\(canGoBack), forward=\(canGoForward), 인덱스=\(currentPageIndex)/\(pageHistory.count)")
        }
    }
    
    func updateCurrentPageTitle(_ title: String) {
        guard currentPageIndex >= 0, 
              currentPageIndex < pageHistory.count,
              !title.isEmpty else { 
            dbg("📝 제목 업데이트 실패: 인덱스=\(currentPageIndex), 총개수=\(pageHistory.count), 제목='\(title)'")
            return 
        }
        
        var updatedRecord = pageHistory[currentPageIndex]
        let oldTitle = updatedRecord.title
        updatedRecord.updateTitle(title)
        pageHistory[currentPageIndex] = updatedRecord
        
        dbg("📝 페이지 제목 업데이트: '\(oldTitle)' → '\(title)' [ID: \(String(updatedRecord.id.uuidString.prefix(8)))]")
    }
    
    var currentPageRecord: PageRecord? {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return nil }
        return pageHistory[currentPageIndex]
    }

    // MARK: - 세션 저장/복원
    
    func saveSession() -> WebViewSession? {
        guard !pageHistory.isEmpty, currentPageIndex >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 없음")
            return nil
        }
        
        let session = WebViewSession(pageRecords: pageHistory, currentIndex: currentPageIndex)
        dbg("💾 세션 저장: \(pageHistory.count)개 페이지, 현재 인덱스 \(currentPageIndex)")
        return session
    }

    func restoreSession(_ session: WebViewSession) {
        dbg("🔄 === 세션 복원 시작 ===")
        isRestoringSession = true
        
        pageHistory = session.pageRecords
        currentPageIndex = max(0, min(session.currentIndex, pageHistory.count - 1))
        
        dbg("🔄 복원된 히스토리:")
        for (index, record) in pageHistory.enumerated() {
            let marker = index == currentPageIndex ? "👉" : "  "
            dbg("🔄\(marker) [\(index)] \(record.title) | \(record.url.absoluteString)")
        }
        
        if let currentRecord = currentPageRecord {
            isNavigatingFromWebView = true
            currentURL = currentRecord.url
            isNavigatingFromWebView = false
            
            dbg("🔄 세션 복원: \(pageHistory.count)개 페이지, 현재 '\(currentRecord.title)'")
        } else {
            currentURL = nil
            dbg("🔄 세션 복원 실패: 유효한 페이지 없음")
        }
        
        updateNavigationState()
        dbg("🔧 복원 후 즉시 상태: back=\(canGoBack), forward=\(canGoForward), 인덱스=\(currentPageIndex)/\(pageHistory.count)")
        
        if let webView = webView, let url = currentURL {
            webView.load(URLRequest(url: url))
            dbg("🌐 복원 시 웹뷰 로드: \(url.absoluteString)")
        }
    }

    // MARK: - ✅ 강화된 네비게이션 메서드
    
    func goBack() {
        guard canGoBack, currentPageIndex > 0 else { 
            dbg("⬅️ 뒤로가기 불가: canGoBack=\(canGoBack), index=\(currentPageIndex)")
            return 
        }
        
        dbg("⬅️ === 뒤로가기 시작 ===")
        dbg("⬅️ 현재 인덱스: \(currentPageIndex) → \(currentPageIndex - 1)")
        
        // ✅ 히스토리 네비게이션 플래그 설정
        isHistoryNavigation = true
        isNavigatingFromWebView = true
        
        currentPageIndex -= 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            // ✅ currentURL 즉시 동기화
            currentURL = record.url
            
            if let webView = webView {
                webView.load(URLRequest(url: record.url))
                dbg("🌐 뒤로가기 웹뷰 로드: \(record.url.absoluteString)")
            }
            
            updateNavigationState()
            dbg("⬅️ 뒤로가기 성공: '\(record.title)' [ID: \(String(record.id.uuidString.prefix(8)))] | 인덱스: \(currentPageIndex)/\(pageHistory.count)")
        }
        dbg("⬅️ === 뒤로가기 끝 ===")
    }
    
    func goForward() {
        guard canGoForward, currentPageIndex < pageHistory.count - 1 else { 
            dbg("➡️ 앞으로가기 불가: canGoForward=\(canGoForward), index=\(currentPageIndex), total=\(pageHistory.count)")
            return 
        }
        
        dbg("➡️ === 앞으로가기 시작 ===")
        dbg("➡️ 현재 인덱스: \(currentPageIndex) → \(currentPageIndex + 1)")
        
        // ✅ 히스토리 네비게이션 플래그 설정
        isHistoryNavigation = true
        isNavigatingFromWebView = true
        
        currentPageIndex += 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            // ✅ currentURL 즉시 동기화
            currentURL = record.url
            
            if let webView = webView {
                webView.load(URLRequest(url: record.url))
                dbg("🌐 앞으로가기 웹뷰 로드: \(record.url.absoluteString)")
            }
            
            updateNavigationState()
            dbg("➡️ 앞으로가기 성공: '\(record.title)' [ID: \(String(record.id.uuidString.prefix(8)))] | 인덱스: \(currentPageIndex)/\(pageHistory.count)")
        }
        dbg("➡️ === 앞으로가기 끝 ===")
    }
    
    func reload() { 
        guard let webView = webView else { return }
        webView.reload()
        dbg("🔄 페이지 새로고침")
    }
    
    // ✨ 강화된 데스크탑 모드 토글 메서드
    func toggleDesktopMode() {
        isDesktopMode.toggle()
        dbg("🖥️ 데스크탑 모드 토글: \(isDesktopMode)")
    }
    
    // ✨ 강화된 데스크탑 모드 적용 메서드
    private func applyDesktopModeChanges() {
        guard let webView = webView else {
            dbg("⚠️ WebView가 없어서 데스크탑 모드 적용 불가")
            return
        }
        
        // 사용자 에이전트 업데이트
        updateUserAgent()
        
        // 페이지 새로고침으로 변경사항 적용
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            webView.reload()
            self.dbg("🔄 데스크탑 모드 변경으로 인한 페이지 새로고침")
        }
    }
    
    // ✨ 강화된 사용자 에이전트 업데이트 메서드
    private func updateUserAgent() {
        guard let webView = webView else { return }
        
        if isDesktopMode {
            // ✨ 최신 Windows Chrome 사용자 에이전트 (더욱 강력한 데스크탑 인식)
            let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
            webView.customUserAgent = desktopUA
            dbg("🖥️ 강화된 데스크탑 사용자 에이전트 설정: Windows Chrome/Edge")
            
            // ✨ 추가 데스크탑 설정들을 CustomWebView의 Coordinator에 위임
            // (실제 스크립트 주입은 CustomWebView의 updateUserAgentIfNeeded에서 처리)
            
        } else {
            // 모바일 기본 사용자 에이전트로 복원
            webView.customUserAgent = nil
            dbg("📱 모바일 사용자 에이전트로 복원")
        }
    }

    // MARK: - ✅ CustomWebView와 연동을 위한 메서드들
    
    /// CustomWebView에서 사용하는 isNavigatingFromWebView 플래그 제어
    func setNavigatingFromWebView(_ value: Bool) {
        self.isNavigatingFromWebView = value
    }
    
    // CustomWebView에서 호출할 수 있는 스와이프 감지 메서드
    func handleSwipeGestureDetected(to url: URL) {
        guard !isHistoryNavigationActive() else {
            dbg("👆 스와이프 감지 무시: 이미 네비게이션 중")
            return
        }
        
        if let foundIndex = pageHistory.firstIndex(where: { $0.url == url }) {
            dbg("👆 === 스와이프 제스처 감지 ===")
            dbg("👆 감지된 URL: \(url.absoluteString)")
            dbg("👆 목표 인덱스: \(foundIndex), 현재 인덱스: \(currentPageIndex)")
            
            if foundIndex != currentPageIndex {
                swipeDetectedTargetIndex = foundIndex
                
                // ✅ 스와이프 확정 타이머 (didCommit가 CustomWebView에서 처리되므로)
                swipeConfirmationTimer?.invalidate()
                swipeConfirmationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    self?.confirmSwipeGesture()
                }
                
                dbg("👆 스와이프 목표 인덱스 예약: \(foundIndex)")
            }
        }
    }
    
    private func confirmSwipeGesture() {
        guard let targetIndex = swipeDetectedTargetIndex else { return }
        
        dbg("👆 ✅ 스와이프 제스처 확정: \(currentPageIndex) → \(targetIndex)")
        
        isHistoryNavigation = true
        currentPageIndex = targetIndex
        
        // 히스토리 기록 접근 시간 업데이트
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count {
            var mutableRecord = pageHistory[currentPageIndex]
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
        }
        
        // ✅ currentURL 즉시 동기화
        if let record = currentPageRecord {
            isNavigatingFromWebView = true
            currentURL = record.url
            dbg("👆 🔄 스와이프 currentURL 즉시 동기화: \(record.url.absoluteString)")
        }
        
        updateNavigationState()
        swipeDetectedTargetIndex = nil
        
        dbg("👆 스와이프 제스처 확정 완료: 인덱스=\(currentPageIndex)/\(pageHistory.count)")
    }
    
    // ✅ CustomWebView의 didCommit에서 호출할 쿠키 동기화 메서드
    func handleDidCommitNavigation() {
        // 쿠키 동기화는 CustomWebView에서 처리하므로 여기서는 로그만
        dbg("🍪 didCommit 호출됨 (쿠키 동기화는 CustomWebView에서 처리)")
    }

    // MARK: - 기존 호환성 API
    
    var historyURLs: [String] {
        return pageHistory.map { $0.url.absoluteString }
    }

    var currentHistoryIndex: Int {
        return max(0, currentPageIndex)
    }

    func historyStackIfAny() -> [URL] {
        return pageHistory.map { $0.url }
    }

    func currentIndexInSafeBounds() -> Int {
        return max(0, min(currentPageIndex, pageHistory.count - 1))
    }
    
    func loadURLIfReady() {
        if let url = currentURL, let webView = webView {
            webView.load(URLRequest(url: url))
            dbg("URL 로드 시도: \(url.absoluteString)")
        } else {
            dbg("URL 로드 실패: WebView 또는 URL 없음")
        }
    }

    // MARK: - WKNavigationDelegate (기존 구조 유지)
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        
        let startURL = webView.url
        dbg("🌐 로드 시작 → \(startURL?.absoluteString ?? "(pending)")")
        
        // ✅ 자동 스와이프 감지 (기존 로직 유지하되 개선)
        if let startURL = startURL, 
           !isRestoringSession, 
           !isHistoryNavigationActive(),
           currentURL != startURL {
            
            handleSwipeGestureDetected(to: startURL)
        }
        
        // 리다이렉트 체인 관리
        if let url = startURL {
            let now = Date()
            
            if redirectionChain.isEmpty || redirectionStartTime == nil || 
               now.timeIntervalSince(redirectionStartTime!) > 3.0 {
                redirectionChain = [url]
                redirectionStartTime = now
                dbg("🔗 새 네비게이션 체인 시작: \(url.absoluteString)")
            } else {
                redirectionChain.append(url)
                dbg("🔗 리다이렉트 체인 연장: \(url.absoluteString) (총 \(redirectionChain.count)개)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        self.webView = webView
        
        let title = webView.title ?? webView.url?.host ?? "제목 없음"
        
        let wasRestoringSession = isRestoringSession
        
        if let finalURL = webView.url {
            dbg("🌐 === didFinish 상세 분석 ===")
            dbg("🌐 didFinish URL: \(finalURL.absoluteString)")
            dbg("🌐 didFinish 제목: '\(title)'")
            
            // ✅ 복원 상태 우선 처리
            if isRestoringSession {
                dbg("🔄 === 복원 중 처리 ===")
                updateCurrentPageTitle(title)
                isRestoringSession = false
                updateNavigationState()
                dbg("🔄 복원 완료: '\(title)'")
                
            } else if isHistoryNavigationActive() {
                dbg("🔄 === 히스토리 네비게이션 처리 ===")
                updateCurrentPageTitle(title)
                
                // URL 동기화 확인
                if currentURL != finalURL {
                    dbg("🔄 ⚠️ URL 불일치 감지 - 강제 동기화")
                    isNavigatingFromWebView = true
                    currentURL = finalURL
                    isNavigatingFromWebView = false
                } else {
                    dbg("🔄 ✅ currentURL 동기화 확인됨")
                }
                
                // ✅ 플래그 지연 해제
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.isNavigatingFromWebView = false
                    self.resetNavigationFlags()
                    self.dbg("🏁 히스토리 네비게이션 완료 정리")
                }
                
                dbg("🔄 히스토리 네비게이션 완료: '\(title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
                
            } else {
                dbg("🆕 === 일반 네비게이션 처리 ===")
                let shouldAddNewPage = shouldAddPageToHistory(finalURL: finalURL)
                
                if shouldAddNewPage {
                    isNavigatingFromWebView = true
                    addNewPage(url: finalURL, title: title)
                    WebViewStateModel.globalHistory.append(.init(url: finalURL, title: title, date: Date()))
                    WebViewStateModel.saveGlobalHistory()
                    currentURL = finalURL
                    isNavigatingFromWebView = false
                    dbg("🆕 새 페이지 기록: '\(title)'")
                } else {
                    updateCurrentPageTitle(title)
                    currentURL = finalURL
                    dbg("📝 기존 페이지 업데이트: '\(title)'")
                }
            }
            
            // 리다이렉트 체인 정리
            redirectionChain.removeAll()
            redirectionStartTime = nil
            
            dbg("🌐 === didFinish 분석 끝 ===")
        }
        
        updateNavigationState()
        
        if !wasRestoringSession {
            navigationDidFinish.send(())
        }
        
        dbg("🌐 로드 완료 → '\(title)' | back=\(canGoBack) forward=\(canGoForward) | 히스토리: \(pageHistory.count)개")
    }
    
    private func shouldAddPageToHistory(finalURL: URL) -> Bool {
        dbg("🤔 === shouldAddPageToHistory 분석 ===")
        
        if isHistoryNavigationActive() {
            dbg("🚫 히스토리 네비게이션 중 - 새 페이지 추가 방지")
            return false
        }
        
        if pageHistory.isEmpty {
            dbg("✅ 첫 페이지이므로 추가")
            return true
        }
        
        guard let lastRecord = pageHistory.last else {
            dbg("✅ 마지막 기록이 없으므로 추가")
            return true
        }
        
        if lastRecord.url != finalURL {
            // 리다이렉트 분석
            if redirectionChain.count > 1 {
                let firstURL = redirectionChain.first!
                let lastURL = redirectionChain.last!
                
                if lastRecord.url == firstURL && lastURL == finalURL {
                    if firstURL.host == finalURL.host {
                        dbg("🏠 같은 도메인 리다이렉트 - 기존 페이지 업데이트")
                        return false
                    } else {
                        dbg("🌍 다른 도메인 리다이렉트 - 새 페이지 추가")
                        return true
                    }
                }
            }
            
            dbg("✅ 다른 URL이므로 새 페이지 추가")
            return true
        } else {
            dbg("📝 같은 URL - 제목만 업데이트")
            return false
        }
    }

    // ✨ 에러 처리
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        resetNavigationFlags()
        
        dbg("❌ 로드 실패(Provisional): \(error.localizedDescription)")
        
        if let tabID = tabID {
            NotificationCenter.default.post(
                name: Notification.Name("webViewDidFailLoad"),
                object: nil,
                userInfo: [
                    "tabID": tabID.uuidString,
                    "error": error,
                    "url": webView.url?.absoluteString ?? currentURL?.absoluteString ?? ""
                ]
            )
        }
        
        redirectionChain.removeAll()
        redirectionStartTime = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        resetNavigationFlags()
        
        dbg("❌ 로드 실패(Navigation): \(error.localizedDescription)")
        
        if let tabID = tabID {
            NotificationCenter.default.post(
                name: Notification.Name("webViewDidFailLoad"),
                object: nil,
                userInfo: [
                    "tabID": tabID.uuidString,
                    "error": error,
                    "url": webView.url?.absoluteString ?? currentURL?.absoluteString ?? ""
                ]
            )
        }
        
        redirectionChain.removeAll()
        redirectionStartTime = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            dbg("📡 HTTP 상태 코드: \(statusCode) - \(navigationResponse.response.url?.absoluteString ?? "")")
            
            if statusCode >= 400 {
                dbg("❌ HTTP 에러 상태 코드 감지: \(statusCode)")
                
                if let tabID = tabID {
                    NotificationCenter.default.post(
                        name: Notification.Name("webViewDidFailLoad"),
                        object: nil,
                        userInfo: [
                            "tabID": tabID.uuidString,
                            "statusCode": statusCode,
                            "url": navigationResponse.response.url?.absoluteString ?? ""
                        ]
                    )
                }
            }
        }
        
        if #available(iOS 14.0, *) {
            if let http = navigationResponse.response as? HTTPURLResponse,
               let disp = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
               disp.contains("attachment") {
                decisionHandler(.download)
                return
            }
        }
        
        decisionHandler(.allow)
    }

    // MARK: - 디버그 메서드
    
    private func dbg(_ msg: String) {
        let id: String
        if let tabID = tabID {
            id = String(tabID.uuidString.prefix(6))
        } else {
            id = "noTab"
        }
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)] \(msg)")
    }

    func printHistoryState(reason: String = "") {
        if !reason.isEmpty {
            dbg("📋 === 히스토리 상태 출력 (\(reason)) ===")
        } else {
            dbg("📋 === 현재 히스토리 상태 ===")
        }
        
        dbg("📋 총 \(pageHistory.count)개 페이지, 현재 인덱스: \(currentPageIndex)")
        
        if pageHistory.isEmpty {
            dbg("📋 (히스토리가 비어있음)")
        } else {
            for (index, record) in pageHistory.enumerated() {
                let marker = index == currentPageIndex ? "👉" : "  "
                dbg("📋\(marker) [\(index)] \(record.title) | \(record.url.absoluteString)")
            }
        }
        
        dbg("📋 네비게이션 상태: back=\(canGoBack), forward=\(canGoForward)")
        dbg("📋 === 히스토리 상태 출력 끝 ===")
    }
    
    func checkSyncState(reason: String = "") {
        dbg("🔍 === 동기화 상태 체크 (\(reason)) ===")
        dbg("🔍 currentURL: \(currentURL?.absoluteString ?? "nil")")
        dbg("🔍 현재 인덱스: \(currentPageIndex)")
        
        if let currentRecord = currentPageRecord {
            dbg("🔍 현재 레코드 URL: \(currentRecord.url.absoluteString)")
            dbg("🔍 URL 일치 여부: \(currentURL == currentRecord.url)")
        } else {
            dbg("🔍 현재 레코드: nil")
        }
        
        dbg("🔍 네비게이션 버튼 상태: back=\(canGoBack), forward=\(canGoForward)")
        dbg("🔍 플래그 상태: history=\(isHistoryNavigation), webview=\(isNavigatingFromWebView), restore=\(isRestoringSession)")
        dbg("🔍 === 동기화 상태 체크 끝 ===")
    }
    
    // MARK: - 메모리 정리
    deinit {
        swipeConfirmationTimer?.invalidate()
    }

    // MARK: - 방문기록 페이지
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

        private var sessionHistory: [PageRecord] {
            return state.pageHistory.reversed()
        }
        
        private var filteredGlobalHistory: [HistoryEntry] {
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
                if !sessionHistory.isEmpty {
                    Section("현재 세션") {
                        ForEach(sessionHistory) { record in
                            SessionHistoryRowView(
                                record: record, 
                                isCurrent: record.id == state.currentPageRecord?.id
                            )
                            .onTapGesture {
                                if let index = state.pageHistory.firstIndex(where: { $0.id == record.id }) {
                                    state.currentPageIndex = index
                                    state.currentURL = record.url
                                    if let webView = state.webView {
                                        webView.load(URLRequest(url: record.url))
                                    }
                                    state.updateNavigationState()
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                
                Section("전체 기록") {
                    ForEach(filteredGlobalHistory) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "globe")
                                    .frame(width: 16, height: 16)
                                    .foregroundColor(.blue)
                                
                                Text(item.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                Text(dateFormatter.string(from: item.date))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(item.url.absoluteString)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .onTapGesture {
                            state.currentURL = item.url
                            dismiss()
                        }
                    }
                    .onDelete(perform: deleteGlobalHistory)
                }
            }
            .navigationTitle("방문 기록")
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("모두 지우기") {
                        state.clearHistory()
                    }
                }
            }
        }

        func deleteGlobalHistory(at offsets: IndexSet) {
            let items = filteredGlobalHistory
            let targets = offsets.map { items[$0] }
            WebViewStateModel.globalHistory.removeAll { targets.contains($0) }
            WebViewStateModel.saveGlobalHistory()
            TabPersistenceManager.debugMessages.append("[\(ts())] 🧹 방문 기록 삭제: \(targets.count)개")
        }
    }
}

// MARK: - 세션 히스토리 행 뷰
struct SessionHistoryRowView: View {
    let record: PageRecord
    let isCurrent: Bool
    
    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "arrow.right.circle.fill" : "circle")
                .foregroundColor(isCurrent ? .blue : .gray)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(isCurrent ? .headline : .body)
                    .fontWeight(isCurrent ? .bold : .regular)
                    .lineLimit(1)
                
                Text(record.url.absoluteString)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                
                HStack {
                    Text("ID: \(String(record.id.uuidString.prefix(8)))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(DateFormatter.shortTime.string(from: record.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .background(isCurrent ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }
}

extension DateFormatter {
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
