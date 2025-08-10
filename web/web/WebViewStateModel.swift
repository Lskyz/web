//
//  WebViewStateModel.swift
//  페이지 고유번호 기반 히스토리 시스템 (앱 재실행 후 forward 히스토리 복원 문제 해결)
//  ✨ 에러 처리 및 로딩 상태 관리 추가
//  ✅ 시간 기반 중복 저장 방지 + 연속 중복 제거
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

// MARK: - WebViewStateModel (앱 재실행 후 forward 히스토리 복원 문제 해결)
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate {

    var tabID: UUID?
    
    // 페이지 기록 기반 히스토리 (기존 복잡한 시스템 교체)
    @Published private var pageHistory: [PageRecord] = []
    @Published private var currentPageIndex: Int = -1
    
    // ✨ 로딩 상태 관리 추가
    @Published var isLoading: Bool = false {
        didSet {
            if oldValue != isLoading {
                dbg("📡 로딩 상태 변경: \(oldValue) → \(isLoading)")
            }
        }
    }
// ✨ 로딩 진행률 추가 (별도 선언)
@Published var loadingProgress: Double = 0.0
    
    let navigationDidFinish = PassthroughSubject<Void, Never>()

    @Published var currentURL: URL? {
        didSet {
            guard let url = currentURL else { return }

            UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
            dbg("🎯 currentURL 업데이트 → \(url.absoluteString) | 이전: \(oldValue?.absoluteString ?? "nil")")

            // ✅ 콜스택 추적 로그 강화 (더 많은 정보)
            dbg("📞 === 호출 스택 추적 ===")
            Thread.callStackSymbols.prefix(8).enumerated().forEach { index, symbol in
                dbg("📞[\(index)] \(symbol)")
            }
            dbg("📞 === 스택 추적 끝 ===")

            // 🔧 주소창에서 직접 입력한 경우 웹뷰 로드
            let shouldLoad = url != oldValue && 
                           !isRestoringSession && 
                           !isNavigatingFromWebView &&
                           !isHistoryNavigationActive()  // ✅ 강화된 히스토리 네비게이션 체크
            
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
                dbg("⛔️ webView.load 생략됨 - 중복 또는 복원 중 또는 내부 네비게이션")
            }
        }
    }
    

    // ✅ 웹뷰 내부 네비게이션인지 구분하는 플래그 강화
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
    
    // ✅ 🔧 히스토리 네비게이션 중인지 구분 (뒤로/앞으로 버튼) - 강화
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
    
    // ✅ 히스토리 네비게이션 시작 시간 추적
    private var historyNavigationStartTime: Date?

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

    // 복원 상태 관리 (단순화)
    private(set) var isRestoringSession: Bool = false {
        didSet {
            if oldValue != isRestoringSession {
                dbg("🏁 isRestoringSession: \(oldValue) → \(isRestoringSession)")
            }
        }
    }
    
    // 🔧 WebView 연결 시 네이티브 히스토리 상태 무시
    weak var webView: WKWebView? {
        didSet {
            if webView != nil {
                dbg("🔗 webView 연결됨")
                // 네이티브 히스토리 상태 대신 커스텀 히스토리 상태만 사용
                DispatchQueue.main.async {
                    self.updateNavigationState()
                    self.dbg("🔧 WebView 연결 후 커스텀 상태 강제 적용: back=\(self.canGoBack), forward=\(self.canGoForward)")
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

    // ✨ 로딩 중지 메서드 추가
    func stopLoading() {
        webView?.stopLoading()
        isLoading = false
        dbg("⏹️ 로딩 중지")
    }

    func clearHistory() {
        WebViewStateModel.globalHistory = []
        WebViewStateModel.saveGlobalHistory()
        pageHistory.removeAll()
        currentPageIndex = -1
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

    // MARK: - ✅ 히스토리 네비게이션 상태 체크 강화
    
    private func isHistoryNavigationActive() -> Bool {
        // 기본 플래그 체크
        if isHistoryNavigation {
            dbg("✅ 히스토리 네비게이션 활성: isHistoryNavigation = true")
            return true
        }
        
        // 시간 기반 체크 (최근 2초 내에 히스토리 네비게이션이 시작된 경우)
        if let startTime = historyNavigationStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 2.0 {  // 2초 내
                dbg("✅ 히스토리 네비게이션 활성: 시작 후 \(elapsed)초 경과")
                return true
            } else {
                dbg("⏰ 히스토리 네비게이션 타임아웃: \(elapsed)초 경과, 플래그 자동 해제")
                // 타임아웃으로 플래그 자동 해제
                isHistoryNavigation = false
                historyNavigationStartTime = nil
                return false
            }
        }
        
        return false
    }

    // MARK: - ✅ URL 정규화 (네이버 카페 등 동적 파라미터 제거)
    
    private func normalizeURL(_ url: URL) -> String {
        let urlString = url.absoluteString
        
        // 네이버 카페 정규화
        if urlString.contains("cafe.naver.com") {
            if let articleRange = urlString.range(of: "articleid="),
               let clubRange = urlString.range(of: "clubid=") {
                
                let articleStart = articleRange.upperBound
                let clubStart = clubRange.upperBound
                
                // articleid 추출
                let articleSubstring = urlString[articleStart...]
                let articleEnd = articleSubstring.firstIndex(where: { $0 == "&" || $0 == "#" || $0 == "?" }) ?? articleSubstring.endIndex
                let articleId = String(articleSubstring[..<articleEnd])
                
                // clubid 추출  
                let clubSubstring = urlString[clubStart...]
                let clubEnd = clubSubstring.firstIndex(where: { $0 == "&" || $0 == "#" || $0 == "?" }) ?? clubSubstring.endIndex
                let clubId = String(clubSubstring[..<clubEnd])
                
                let normalizedUrl = "https://cafe.naver.com/normalized?clubid=\(clubId)&articleid=\(articleId)"
                dbg("🔧 네이버 카페 URL 정규화: \(urlString) → \(normalizedUrl)")
                return normalizedUrl
            }
        }
        
        // 일반적인 URL에서 불필요한 파라미터 제거
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let parametersToRemove = [
                "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term",
                "fbclid", "gclid", "ref", "referrer", "timestamp", "t", "ts", 
                "_", "sessionid", "sid", "s", "from", "channel"
            ]
            
            if let queryItems = components.queryItems {
                let filteredItems = queryItems.filter { item in
                    !parametersToRemove.contains(item.name.lowercased())
                }
                components.queryItems = filteredItems.isEmpty ? nil : filteredItems
            }
            
            components.fragment = nil
            
            let normalizedUrl = components.url?.absoluteString ?? urlString
            if normalizedUrl != urlString {
                dbg("🔧 일반 URL 정규화: \(urlString) → \(normalizedUrl)")
            }
            return normalizedUrl
        }
        
        return urlString
    }

    // MARK: - ✅ 새로운 페이지 기록 시스템 (시간 기반 중복 방지 + 연속 중복 제거)
    
    private func addNewPage(url: URL, title: String = "") {
        dbg("📋 === addNewPage 호출 ===")
        dbg("📋 추가하려는 URL: \(url.absoluteString)")
        
        // ✅ 강화된 조건 체크
        if isHistoryNavigationActive() {
            dbg("🚫 히스토리 네비게이션 활성 중 - 새 페이지 추가 방지")
            return
        }
        
        let newNormalizedURL = normalizeURL(url)
        
        // ✅ 시간 기반 중복 체크 (현재 페이지와 30초 이내)
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count {
            let currentRecord = pageHistory[currentPageIndex]
            let currentNormalizedURL = normalizeURL(currentRecord.url)
            
            if currentNormalizedURL == newNormalizedURL {
                let timeDifference = Date().timeIntervalSince(currentRecord.lastAccessed)
                if timeDifference < 30.0 {
                    dbg("🚫 30초 이내 중복 URL 감지 - 제목만 업데이트")
                    var mutableRecord = currentRecord
                    mutableRecord.updateTitle(title.isEmpty ? (url.host ?? "제목 없음") : title)
                    pageHistory[currentPageIndex] = mutableRecord
                    return
                }
            }
        }
        
        // ✅ 최근 3개 페이지에서 10초 이내 중복 체크
        let recentPages = pageHistory.suffix(3)
        for (index, record) in recentPages.enumerated() {
            let actualIndex = pageHistory.count - 3 + index
            let recordNormalizedURL = normalizeURL(record.url)
            
            if recordNormalizedURL == newNormalizedURL {
                let timeDifference = Date().timeIntervalSince(record.lastAccessed)
                if timeDifference < 10.0 {
                    dbg("🚫 10초 이내 최근 히스토리 중복 - 기존 페이지로 이동")
                    currentPageIndex = actualIndex
                    var mutableRecord = record
                    mutableRecord.updateTitle(title.isEmpty ? (url.host ?? "제목 없음") : title)
                    mutableRecord.updateAccess()
                    pageHistory[actualIndex] = mutableRecord
                    
                    if actualIndex < pageHistory.count - 1 {
                        pageHistory.removeSubrange((actualIndex + 1)...)
                    }
                    updateNavigationState()
                    return
                }
            }
        }
        
        // 현재 위치 이후의 forward 기록 제거
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            pageHistory.removeSubrange((currentPageIndex + 1)...)
        }
        
        // ✅ 연속된 중복 기록 제거 (네이버→네이버→네이버 문제 해결)
        while !pageHistory.isEmpty {
            let lastRecord = pageHistory.last!
            let lastNormalizedURL = normalizeURL(lastRecord.url)
            
            if lastNormalizedURL == newNormalizedURL {
                let removedRecord = pageHistory.removeLast()
                dbg("🔄 연속 중복 제거: '\(removedRecord.title)'")
                
                if currentPageIndex >= pageHistory.count {
                    currentPageIndex = pageHistory.count - 1
                }
            } else {
                break
            }
        }
        
        let newRecord = PageRecord(url: url, title: title.isEmpty ? (url.host ?? "제목 없음") : title)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // 최대 50개 유지
        if pageHistory.count > 50 {
            pageHistory.removeFirst()
            currentPageIndex -= 1
        }
        
        updateNavigationState()
        dbg("📄 ✅ 새 페이지 추가 완료: '\(newRecord.title)' 인덱스: \(currentPageIndex)/\(pageHistory.count)")
    }
    
    // 🔧 완전히 커스텀 히스토리 기반으로 상태 업데이트 (연속 중복 고려)
    private func updateNavigationState() {
        let oldBack = canGoBack
        let oldForward = canGoForward
        
        // ✅ 연속 중복을 고려한 실제 네비게이션 가능 여부 계산
        canGoBack = canActuallyGoBack()
        canGoForward = canActuallyGoForward()
        
        if oldBack != canGoBack || oldForward != canGoForward {
            dbg("🔄 네비게이션 상태 업데이트: back=\(canGoBack), forward=\(canGoForward)")
        }
    }
    
    // ✅ 연속 중복을 고려한 실제 뒤로가기 가능 여부
    private func canActuallyGoBack() -> Bool {
        guard currentPageIndex > 0, !pageHistory.isEmpty else { return false }
        
        let currentNormalizedURL = normalizeURL(pageHistory[currentPageIndex].url)
        
        for i in (0..<currentPageIndex).reversed() {
            let targetNormalizedURL = normalizeURL(pageHistory[i].url)
            if targetNormalizedURL != currentNormalizedURL {
                return true
            }
        }
        return false
    }
    
    // ✅ 연속 중복을 고려한 실제 앞으로가기 가능 여부
    private func canActuallyGoForward() -> Bool {
        guard currentPageIndex < pageHistory.count - 1, !pageHistory.isEmpty else { return false }
        
        let currentNormalizedURL = normalizeURL(pageHistory[currentPageIndex].url)
        
        for i in (currentPageIndex + 1)..<pageHistory.count {
            let targetNormalizedURL = normalizeURL(pageHistory[i].url)
            if targetNormalizedURL != currentNormalizedURL {
                return true
            }
        }
        return false
    }
    
    func updateCurrentPageTitle(_ title: String) {
        guard currentPageIndex >= 0, 
              currentPageIndex < pageHistory.count,
              !title.isEmpty else { return }
        
        var updatedRecord = pageHistory[currentPageIndex]
        updatedRecord.updateTitle(title)
        pageHistory[currentPageIndex] = updatedRecord
        
        dbg("📝 페이지 제목 업데이트: '\(title)'")
    }
    
    var currentPageRecord: PageRecord? {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return nil }
        return pageHistory[currentPageIndex]
    }

    // MARK: - 세션 저장/복원 (단순화)
    
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
        
        if let webView = webView, let url = currentURL {
            webView.load(URLRequest(url: url))
            dbg("🌐 복원 시 웹뷰 로드: \(url.absoluteString)")
        }
    }

    // MARK: - ✅ 네비게이션 메서드 (연속 중복 건너뛰기 적용)
    
    func goBack() {
        guard canActuallyGoBack() else { 
            dbg("⬅️ 뒤로가기 불가")
            return 
        }
        
        let currentNormalizedURL = normalizeURL(pageHistory[currentPageIndex].url)
        var targetIndex = currentPageIndex - 1
        
        // ✅ 연속된 중복 건너뛰기
        while targetIndex >= 0 {
            let targetNormalizedURL = normalizeURL(pageHistory[targetIndex].url)
            if targetNormalizedURL != currentNormalizedURL {
                break
            } else {
                dbg("⬅️ 연속 중복 건너뛰기: 인덱스 \(targetIndex)")
                targetIndex -= 1
            }
        }
        
        if targetIndex < 0 {
            dbg("⬅️ 뒤로가기 불가: 모든 이전 기록이 중복됨")
            return
        }
        
        currentPageIndex = targetIndex
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            isHistoryNavigation = true
            isNavigatingFromWebView = true
            currentURL = record.url
            
            if let webView = webView {
                webView.load(URLRequest(url: record.url))
            }
            
            updateNavigationState()
            dbg("⬅️ 뒤로가기 성공: '\(record.title)' 인덱스: \(currentPageIndex)")
        }
    }
    
    func goForward() {
        guard canActuallyGoForward() else { 
            dbg("➡️ 앞으로가기 불가")
            return 
        }
        
        let currentNormalizedURL = normalizeURL(pageHistory[currentPageIndex].url)
        var targetIndex = currentPageIndex + 1
        
        // ✅ 연속된 중복 건너뛰기
        while targetIndex < pageHistory.count {
            let targetNormalizedURL = normalizeURL(pageHistory[targetIndex].url)
            if targetNormalizedURL != currentNormalizedURL {
                break
            } else {
                dbg("➡️ 연속 중복 건너뛰기: 인덱스 \(targetIndex)")
                targetIndex += 1
            }
        }
        
        if targetIndex >= pageHistory.count {
            dbg("➡️ 앞으로가기 불가: 모든 다음 기록이 중복됨")
            return
        }
        
        currentPageIndex = targetIndex
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            isHistoryNavigation = true
            isNavigatingFromWebView = true
            currentURL = record.url
            
            if let webView = webView {
                webView.load(URLRequest(url: record.url))
            }
            
            updateNavigationState()
            dbg("➡️ 앞으로가기 성공: '\(record.title)' 인덱스: \(currentPageIndex)")
        }
    }
    
    func reload() { 
        guard let webView = webView else { return }
        webView.reload()
        dbg("🔄 페이지 새로고침")
    }

    // MARK: - 기존 호환성 API (기존 코드가 계속 작동하도록)
    
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

    // ✅ 전역 히스토리에서도 시간 기반 중복 체크
    private func addToGlobalHistoryIfNotDuplicate(url: URL, title: String) {
        let recentGlobalHistory = WebViewStateModel.globalHistory.suffix(5)
        let newNormalizedURL = normalizeURL(url)
        
        for entry in recentGlobalHistory {
            let entryNormalizedURL = normalizeURL(entry.url)
            if entryNormalizedURL == newNormalizedURL {
                let timeDifference = Date().timeIntervalSince(entry.date)
                if timeDifference < 60.0 {
                    dbg("🚫 전역 히스토리 60초 이내 중복")
                    return
                }
            }
        }
        
        WebViewStateModel.globalHistory.append(.init(url: url, title: title, date: Date()))
        WebViewStateModel.saveGlobalHistory()
        dbg("✅ 전역 히스토리에 추가: \(title)")
    }

    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        
        let startURL = webView.url
        dbg("🌐 로드 시작 → \(startURL?.absoluteString ?? "(pending)")")
        
        // 🔧 리다이렉트 체인 감지 시작
        if let url = startURL {
            let now = Date()
            
            if redirectionChain.isEmpty || redirectionStartTime == nil || 
               now.timeIntervalSince(redirectionStartTime!) > 3.0 {
                redirectionChain = [url]
                redirectionStartTime = now
                dbg("🔗 새 네비게이션 체인 시작")
            } else {
                redirectionChain.append(url)
                dbg("🔗 리다이렉트 체인 연장")
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        self.webView = webView
        
        let title = webView.title ?? webView.url?.host ?? "제목 없음"
        let wasRestoringSession = isRestoringSession
        
        if let finalURL = webView.url {
            dbg("🌐 didFinish: \(finalURL.absoluteString) '\(title)'")
            
            if isRestoringSession {
                dbg("🔄 복원 중 처리")
                updateCurrentPageTitle(title)
                isRestoringSession = false
                updateNavigationState()
                
            } else if isHistoryNavigationActive() {
                dbg("🔄 히스토리 네비게이션 처리")
                updateCurrentPageTitle(title)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.isHistoryNavigation = false
                    self.isNavigatingFromWebView = false
                }
                return
                
            } else {
                dbg("🆕 일반 네비게이션 처리")
                let shouldAddNewPage = shouldAddPageToHistory(finalURL: finalURL)
                
                if shouldAddNewPage {
                    isNavigatingFromWebView = true
                    addNewPage(url: finalURL, title: title)
                    addToGlobalHistoryIfNotDuplicate(url: finalURL, title: title)
                    currentURL = finalURL
                    isNavigatingFromWebView = false
                } else {
                    updateCurrentPageTitle(title)
                    currentURL = finalURL
                }
            }
            
            redirectionChain.removeAll()
            redirectionStartTime = nil
        }
        
        if !wasRestoringSession {
            updateNavigationState()
            navigationDidFinish.send(())
        }
    }
    
    private func shouldAddPageToHistory(finalURL: URL) -> Bool {
        if isHistoryNavigationActive() {
            return false
        }
        
        if pageHistory.isEmpty {
            return true
        }
        
        let finalNormalizedURL = normalizeURL(finalURL)
        
        // 현재 페이지와 30초 이내 같은 URL이면 추가 안함
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count {
            let currentRecord = pageHistory[currentPageIndex]
            let currentNormalizedURL = normalizeURL(currentRecord.url)
            
            if currentNormalizedURL == finalNormalizedURL {
                let timeDifference = Date().timeIntervalSince(currentRecord.lastAccessed)
                if timeDifference < 30.0 {
                    return false
                }
            }
        }
        
        // 최근 3개 페이지에서 10초 이내 같은 URL이면 추가 안함
        let recentPages = pageHistory.suffix(3)
        for record in recentPages {
            let recordNormalizedURL = normalizeURL(record.url)
            if recordNormalizedURL == finalNormalizedURL {
                let timeDifference = Date().timeIntervalSince(record.lastAccessed)
                if timeDifference < 10.0 {
                    return false
                }
            }
        }
        
        return true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        dbg("❌ 로드 실패(Provisional): \(error.localizedDescription)")
        
        if let tabID = tabID {
            NotificationCenter.default.post(
                name: .webViewDidFailLoad,
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
        isRestoringSession = false
        isHistoryNavigation = false
        historyNavigationStartTime = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        dbg("❌ 로드 실패(Navigation): \(error.localizedDescription)")
        
        if let tabID = tabID {
            NotificationCenter.default.post(
                name: .webViewDidFailLoad,
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
        isRestoringSession = false
        isHistoryNavigation = false
        historyNavigationStartTime = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            dbg("📡 HTTP 상태 코드: \(statusCode)")
            
            if statusCode >= 400 {
                dbg("❌ HTTP 에러 상태 코드 감지: \(statusCode)")
                
                if let tabID = tabID {
                    NotificationCenter.default.post(
                        name: .webViewDidFailLoad,
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

    // MARK: - 디버그 로그
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

    // MARK: - 방문기록 페이지 (기존 UI 유지하면서 새 시스템 연동)
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

// MARK: - DateFormatter 확장
extension DateFormatter {
    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
