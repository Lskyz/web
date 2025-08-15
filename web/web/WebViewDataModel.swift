//
//  WebViewDataModel.swift
//  🌐 홈클릭 마지막세션 유지 + 정규식 기반 중복제거 + 자연스러운 히스토리 흐름
//

import Foundation
import SwiftUI
import WebKit

// MARK: - 네비게이션 타입 정의
enum NavigationType: String, Codable, CaseIterable {
    case normal = "normal"
    case reloadSoft = "reloadSoft"
    case reloadHard = "reloadHard"
    case navHome = "navHome"
    case navListFirst = "navListFirst"
    case spaNavigation = "spaNavigation"
    case loginRedirect = "loginRedirect"
}

// MARK: - 페이지 식별자
struct PageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    let timestamp: Date
    var lastAccessed: Date
    
    var siteType: String?
    var isLoginRelated: Bool = false
    var isTemporary: Bool = false
    var navigationType: NavigationType = .normal
    
    init(url: URL, title: String = "", siteType: String? = nil, navigationType: NavigationType = .normal) {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? (url.host ?? "제목 없음") : title
        self.timestamp = Date()
        self.lastAccessed = Date()
        self.siteType = siteType
        self.navigationType = navigationType
        
        self.isLoginRelated = Self.isLoginRelatedURL(url)
        self.isTemporary = Self.isTemporaryURL(url)
    }
    
    mutating func updateTitle(_ title: String) {
        if !title.isEmpty {
            self.title = title
        }
        lastAccessed = Date()
    }
    
    mutating func updateAccess() {
        lastAccessed = Date()
    }
    
    static func isLoginRelatedURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()
        let loginPatterns = [
            "login", "signin", "auth", "oauth", "sso", "redirect", "callback",
            "nid.naver.com", "accounts.google.com", "facebook.com/login", "twitter.com/oauth",
            "returnurl=", "redirect_uri=", "continue=", "state=", "code="
        ]
        return loginPatterns.contains { urlString.contains($0) }
    }
    
    static func isTemporaryURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()
        let tempPatterns = [
            "loading", "wait", "processing", "intermediate", "bridge", "proxy",
            "temp", "tmp", "cache", "blank", "about:blank", "javascript:"
        ]
        return tempPatterns.contains { urlString.contains($0) }
    }
    
    static func normalizeURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        if components?.scheme == "http" {
            components?.scheme = "https"
        }
        
        if let path = components?.path, path.hasSuffix("/") && path.count > 1 {
            components?.path = String(path.dropLast())
        }
        
        if let queryItems = components?.queryItems {
            components?.queryItems = queryItems.sorted { $0.name < $1.name }
        }
        
        components?.fragment = nil
        
        return components?.url?.absoluteString ?? url.absoluteString
    }
    
    func normalizedURL() -> String {
        return Self.normalizeURL(self.url)
    }
}

// MARK: - 세션 구조체
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
    
    var urls: [URL] { pageRecords.map { $0.url } }
}

// MARK: - 전역 히스토리 엔트리
struct HistoryEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    let url: URL
    let title: String
    let date: Date
}

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - WebViewDataModel
final class WebViewDataModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID?
    
    // 페이지 기록 기반 히스토리
    @Published private(set) var pageHistory: [PageRecord] = []
    @Published private(set) var currentPageIndex: Int = -1
    
    // 독립형 네비게이션 상태
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    
    // 상태 관리
    private(set) var isRestoringSession: Bool = false
    private var isHistoryNavigation: Bool = false
    private var historyNavigationStartTime: Date?
    
    // 새로고침 윈도 관리
    private var isInReloadWindow: Bool = false
    private var reloadWindowStartTime: Date?
    private let reloadWindowDuration: TimeInterval = 0.5
    
    // 홈 클릭 처리 상태
    private var isHandlingHomeNavigation: Bool = false
    private var homeNavigationEndTime: Date?
    
    // 스와이프 제스처 관련
    private var swipeDetectedTargetIndex: Int? = nil
    private var swipeConfirmationTimer: Timer?
    
    // 리다이렉트 감지
    private var redirectionChain: [URL] = []
    private var redirectionStartTime: Date?
    
    // SPA 네비게이션 상태 관리
    private var isSPANavigation: Bool = false
    private var lastSPANavigationTime: Date?
    
    // 로그인 리다이렉트 체인 추적
    private var loginRedirectChain: [URL] = []
    private var loginRedirectStartTime: Date?
    private var isInLoginFlow: Bool = false
    
    // 전역 방문기록
    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }
    
    // WebViewStateModel 참조
    weak var stateModel: WebViewStateModel?
    
    override init() {
        super.init()
        Self.loadGlobalHistory()
    }
    
    // MARK: - 네비게이션 상태 관리
    
    private func updateNavigationState() {
        let newCanGoBack = currentPageIndex > 0
        let newCanGoForward = currentPageIndex < pageHistory.count - 1
        
        if canGoBack != newCanGoBack || canGoForward != newCanGoForward {
            canGoBack = newCanGoBack
            canGoForward = newCanGoForward
            objectWillChange.send()
        }
    }
    
    private func setCurrentPageIndex(_ newIndex: Int, reason: String) {
        let oldIndex = currentPageIndex
        currentPageIndex = newIndex
        
        if oldIndex != newIndex {
            dbg("📍 인덱스 변경: \(oldIndex) → \(newIndex) (이유: \(reason))")
            updateNavigationState()
        }
    }
    
    // MARK: - 홈 클릭 상태 관리
    
    private func startHomeNavigationHandling() {
        isHandlingHomeNavigation = true
        homeNavigationEndTime = Date().addingTimeInterval(1.5)
        dbg("🏠 홈 클릭 처리 시작 - 1.5초간 보호")
    }
    
    private func isInHomeNavigationHandling() -> Bool {
        guard isHandlingHomeNavigation, let endTime = homeNavigationEndTime else { return false }
        
        if Date() > endTime {
            isHandlingHomeNavigation = false
            homeNavigationEndTime = nil
            dbg("🏠 홈 클릭 처리 완료")
            return false
        }
        
        return true
    }
    
    // MARK: - 정규식 기반 강화된 URL 정규화
    
    private func normalizeURLForDuplicateCheck(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        // HTTPS 우선 정규화
        if components?.scheme == "http" {
            components?.scheme = "https"
        }
        
        // 트레일링 슬래시 제거
        if let path = components?.path, path.hasSuffix("/") && path.count > 1 {
            components?.path = String(path.dropLast())
        }
        
        // 쿼리 파라미터와 해시 완전 제거
        components?.query = nil
        components?.fragment = nil
        
        // 정규식 기반 추가 정규화
        var normalizedString = components?.url?.absoluteString ?? url.absoluteString
        
        // 추적 파라미터 등 제거
        let patternsToRemove = [
            "\\?utm_[^&]*",           // utm 파라미터
            "\\?fbclid=[^&]*",        // Facebook 추적
            "\\?gclid=[^&]*",         // Google 추적  
            "\\?sessionid=[^&]*",     // 세션 ID
            "\\?PHPSESSID=[^&]*",     // PHP 세션
            "\\?jsessionid=[^&]*",    // Java 세션
            "\\?_ga=[^&]*",           // Google Analytics
            "\\?ref=[^&]*",           // 레퍼러
            "\\?source=[^&]*",        // 소스 추적
            "\\?campaign=[^&]*",      // 캠페인 추적
            "/\\?$",                  // 끝의 물음표
            "/$"                      // 끝의 슬래시 (루트 제외)
        ]
        
        for pattern in patternsToRemove {
            normalizedString = normalizedString.replacingOccurrences(
                of: pattern, 
                with: "", 
                options: .regularExpression
            )
        }
        
        return normalizedString
    }
    
    // MARK: - 인접 중복 제거 (URL 기반)
    
    private func removeAdjacentDuplicates() {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return }
        
        let currentRecord = pageHistory[currentPageIndex]
        let currentNormalizedURL = normalizeURLForDuplicateCheck(currentRecord.url)
        var removedCount = 0
        
        // 바로 앞 페이지 체크
        if currentPageIndex > 0 {
            let prevIndex = currentPageIndex - 1
            let prevRecord = pageHistory[prevIndex]
            let prevNormalizedURL = normalizeURLForDuplicateCheck(prevRecord.url)
            
            if currentNormalizedURL == prevNormalizedURL {
                dbg("🔄 인접 중복 제거 (앞): '\(prevRecord.title)' [인덱스: \(prevIndex)]")
                pageHistory.remove(at: prevIndex)
                setCurrentPageIndex(currentPageIndex - 1, reason: "앞 페이지 중복 제거")
                removedCount += 1
            }
        }
        
        // 바로 뒤 페이지 체크
        if currentPageIndex < pageHistory.count - 1 {
            let nextIndex = currentPageIndex + 1
            let nextRecord = pageHistory[nextIndex]
            let nextNormalizedURL = normalizeURLForDuplicateCheck(nextRecord.url)
            
            if currentNormalizedURL == nextNormalizedURL {
                dbg("🔄 인접 중복 제거 (뒤): '\(nextRecord.title)' [인덱스: \(nextIndex)]")
                pageHistory.remove(at: nextIndex)
                removedCount += 1
            }
        }
        
        if removedCount > 0 {
            dbg("🔄 인접 중복 제거 완료: \(removedCount)개 제거")
        }
    }
    
    // MARK: - SPA 네비게이션 처리
    
    func handleSPANavigation(type: String, url: URL, title: String, timestamp: Double, siteType: String = "unknown") {
        // 홈 클릭 처리 중이면 차단
        if isInHomeNavigationHandling() {
            dbg("🏠 홈 클릭 처리 중 - SPA \(type) 무시: \(url.absoluteString)")
            return
        }
        
        // 새로고침 윈도에서 replace만 차단
        if isInActiveReloadWindow() && type == "replace" {
            dbg("🔄 새로고침 윈도 중 SPA replace 무시: \(url.absoluteString)")
            return
        }
        
        isSPANavigation = true
        lastSPANavigationTime = Date()
        
        dbg("🌐 SPA \(type) 감지: \(siteType) | \(url.absoluteString) | '\(title)'")
        
        // 네비게이션 타입 감지
        let navigationType = detectNavigationType(url: url, type: type, siteType: siteType)
        
        switch navigationType {
        case .navHome:
            handleHomeNavigation(url: url, title: title, siteType: siteType)
        case .reloadSoft, .reloadHard:
            handleRefreshNavigation(url: url, title: title, type: type, siteType: siteType)
        default:
            handleRegularSPANavigation(type: type, url: url, title: title, siteType: siteType, navigationType: navigationType)
        }
        
        // 전역 히스토리에 추가
        if type != "title" && !PageRecord.isLoginRelatedURL(url) && !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
        
        // 1초 후 플래그 해제
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isSPANavigation = false
        }
    }
    
    private func detectNavigationType(url: URL, type: String, siteType: String) -> NavigationType {
        // 홈 클릭 감지
        if url.path == "/" || url.path.isEmpty {
            if let currentRecord = currentPageRecord,
               url.host == currentRecord.url.host &&
               currentRecord.url.path != "/" && !currentRecord.url.path.isEmpty {
                return .navHome
            }
        }
        
        // 리로드 감지
        if let currentRecord = currentPageRecord,
           PageRecord.normalizeURL(currentRecord.url) == PageRecord.normalizeURL(url) {
            return type == "replace" ? .reloadSoft : .reloadHard
        }
        
        // 보드 내 첫 페이지 이동 감지
        if siteType.contains("list") || siteType.contains("page_1") {
            return .navListFirst
        }
        
        return .normal
    }
    
    private func handleHomeNavigation(url: URL, title: String, siteType: String) {
        dbg("🏠 홈 클릭 감지: \(url.absoluteString)")
        
        // SPA 로직 차단 시작
        startHomeNavigationHandling()
        
        // ✅ **수정**: 홈 클릭도 더 신중하게 forward 스택 제거
        // 현재 페이지가 같은 사이트의 홈이 아닐 때만 제거
        let shouldClearForwardStack = currentPageRecord?.url.host != url.host || 
                                     !(currentPageRecord?.url.path == "/" || currentPageRecord?.url.path.isEmpty)
        
        if shouldClearForwardStack && currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🗑️ 홈 클릭 - 다른 사이트/섹션, forward 스택 \(removedCount)개 제거")
        } else {
            dbg("💾 홈 클릭 - forward 스택 보존 (같은 사이트 홈)")
        }
        
        // 새 홈 페이지 추가
        let newRecord = PageRecord(url: url, title: title, siteType: siteType, navigationType: .navHome)
        pageHistory.append(newRecord)
        setCurrentPageIndex(pageHistory.count - 1, reason: "홈 클릭")
        
        dbg("🏠 홈 클릭 - 새 페이지 추가: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
        
        // 세션 위치 보호
        let targetIndex = pageHistory.count - 1
        for delay in [0.1, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if self.currentPageIndex != targetIndex {
                    self.dbg("🏠 세션 위치 보호(\(delay)초): \(self.currentPageIndex) → \(targetIndex)")
                    self.setCurrentPageIndex(targetIndex, reason: "홈 클릭 세션 보호")
                }
            }
        }
        
        // StateModel URL 동기화
        stateModel?.syncCurrentURL(url)
    }
    
    private func handleRefreshNavigation(url: URL, title: String, type: String, siteType: String) {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else {
            dbg("❌ 새로고침 실패: 유효하지 않은 현재 인덱스")
            return
        }
        
        var rec = pageHistory[currentPageIndex]
        rec.url = url
        rec.updateTitle(title)
        rec.siteType = siteType
        rec.navigationType = (type == "replace") ? .reloadSoft : .reloadHard
        pageHistory[currentPageIndex] = rec
        
        startReloadWindow()
        
        dbg("🔄 새로고침 감지: '\(title)' [ID: \(String(rec.id.uuidString.prefix(8)))]")
        
        stateModel?.syncCurrentURL(url)
    }
    
    private func handleRegularSPANavigation(type: String, url: URL, title: String, siteType: String, navigationType: NavigationType) {
        switch type {
        case "push":
            handleSPAPushState(url: url, title: title, siteType: siteType, navigationType: navigationType)
        case "replace":
            handleSPAReplaceState(url: url, title: title, siteType: siteType)
        case "pop", "hash":
            handleSPAPopState(url: url, title: title, siteType: siteType)
        case "iframe_push":
            handleSPAIframePush(url: url, title: title, siteType: siteType)
        case "title":
            updateCurrentPageTitle(title)
        case "dom":
            handleSPADOMChange(url: url, title: title, siteType: siteType)
        default:
            dbg("🌐 알 수 없는 SPA 네비게이션 타입: \(type)")
        }
    }
    
    private func handleSPAPushState(url: URL, title: String, siteType: String, navigationType: NavigationType) {
        // 같은 경로에서 쿼리만 변경 시 replace 처리
        if let currentRecord = currentPageRecord,
           currentRecord.url.host == url.host,
           currentRecord.url.path == url.path,
           currentRecord.url.query != url.query {
            handleSPAReplaceState(url: url, title: title, siteType: siteType)
            dbg("🔄 SPA Push → Replace: 같은 경로, 쿼리만 변경")
            return
        }
        
        // ✅ **수정**: SPA Push에서는 forward 스택을 더 보수적으로 제거
        // 정말 다른 섹션으로 이동할 때만 제거
        let shouldClearForwardStack = !areSimilarPages(url, currentPageRecord?.url)
        
        if shouldClearForwardStack && currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🗑️ SPA Push - 다른 섹션 이동, forward 스택 \(removedCount)개 제거")
        } else {
            dbg("💾 SPA Push - forward 스택 보존 (같은 섹션 내)")
        }
        
        let newRecord = PageRecord(url: url, title: title, siteType: siteType, navigationType: navigationType)
        pageHistory.append(newRecord)
        setCurrentPageIndex(pageHistory.count - 1, reason: "SPA Push")
        
        // 인접 중복 제거 실행
        removeAdjacentDuplicates()
        
        dbg("🌐 SPA 새 페이지: \(siteType) '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))]")
        
        stateModel?.syncCurrentURL(url)
    }
    
    private func handleSPAReplaceState(url: URL, title: String, siteType: String) {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else {
            handleSPAPushState(url: url, title: title, siteType: siteType, navigationType: .normal)
            return
        }
        
        var rec = pageHistory[currentPageIndex]
        rec.url = url
        rec.updateTitle(title)
        rec.siteType = siteType
        rec.navigationType = .spaNavigation
        pageHistory[currentPageIndex] = rec
        
        dbg("🌐 SPA 페이지 교체: \(siteType) '\(rec.title)' [ID: \(String(rec.id.uuidString.prefix(8)))]")
        
        stateModel?.syncCurrentURL(url)
    }
    
    private func handleSPAPopState(url: URL, title: String, siteType: String) {
        // 홈 클릭 처리 중이면 무시
        if isInHomeNavigationHandling() {
            dbg("🏠 홈 클릭 처리 중 - SPA Pop 무시: \(url.absoluteString)")
            return
        }
        
        // 옛날 기록 찾지 말고 무조건 새 페이지 추가
        dbg("🌐 SPA Pop - 무조건 새 페이지 추가: \(url.absoluteString)")
        handleSPAPushState(url: url, title: title, siteType: siteType, navigationType: .normal)
    }
    
    private func handleSPAIframePush(url: URL, title: String, siteType: String) {
        handleSPAPushState(url: url, title: title, siteType: "iframe_\(siteType)", navigationType: .normal)
    }
    
    private func handleSPADOMChange(url: URL, title: String, siteType: String) {
        handleSPAPopState(url: url, title: title, siteType: "dom_\(siteType)")
    }
    
    // MARK: - 새로고침 윈도 관리
    
    private func startReloadWindow() {
        isInReloadWindow = true
        reloadWindowStartTime = Date()
        dbg("🔄 새로고침 윈도 시작")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + reloadWindowDuration) { [weak self] in
            self?.endReloadWindow()
        }
    }
    
    private func endReloadWindow() {
        isInReloadWindow = false
        reloadWindowStartTime = nil
        dbg("🔄 새로고침 윈도 종료")
    }
    
    private func isInActiveReloadWindow() -> Bool {
        guard isInReloadWindow, let startTime = reloadWindowStartTime else { return false }
        let elapsed = Date().timeIntervalSince(startTime)
        
        if elapsed > reloadWindowDuration {
            endReloadWindow()
            return false
        }
        
        return true
    }
    
    // MARK: - 페이지 유사성 체크 (forward 스택 보존용)
    
    private func areSimilarPages(_ url1: URL?, _ url2: URL?) -> Bool {
        guard let url1 = url1, let url2 = url2 else { return false }
        
        // 같은 호스트인지 확인
        guard url1.host == url2.host else { return false }
        
        // 경로가 동일하면 유사
        if url1.path == url2.path { return true }
        
        // 루트 경로들 (홈페이지들)
        let isRoot1 = url1.path == "/" || url1.path.isEmpty
        let isRoot2 = url2.path == "/" || url2.path.isEmpty
        if isRoot1 && isRoot2 { return true }
        
        // 첫 번째 경로 컴포넌트만 비교 (같은 섹션)
        let components1 = url1.pathComponents.dropFirst() // '/' 제거
        let components2 = url2.pathComponents.dropFirst()
        
        return components1.prefix(1) == components2.prefix(1) && 
               components1.count <= 2 && components2.count <= 2
    }
    
    func addNewPage(url: URL, title: String = "") {
        // 히스토리 네비게이션 중 새 페이지 추가 금지
        if isHistoryNavigationActive() {
            dbg("🔄 히스토리 네비 중 - 새 페이지 추가 금지")
            return
        }
        
        // SPA 네비게이션 중인지 체크
        if isSPANavigationActive() {
            dbg("🌐 SPA 네비게이션 활성 중 - 일반 페이지 추가 건너뜀")
            return
        }
        
        // 로그인 관련 URL 감지 및 추적
        if PageRecord.isLoginRelatedURL(url) {
            if !isInLoginFlow {
                startLoginRedirectTracking(url: url)
            } else {
                addToLoginRedirectChain(url: url)
            }
            
            dbg("🔒 로그인 페이지 히스토리 제외: \(url.absoluteString)")
            return
        }
        
        // 로그인 플로우가 진행 중이면서 일반 페이지에 도착한 경우
        if isInLoginFlow && !PageRecord.isLoginRelatedURL(url) {
            finishLoginRedirectTracking(finalURL: url)
        }
        
        // 간단한 연속 중복 체크
        if !pageHistory.isEmpty,
           let lastRecord = pageHistory.last,
           normalizeURLForDuplicateCheck(lastRecord.url) == normalizeURLForDuplicateCheck(url) {
            updateCurrentPageTitle(title)
            dbg("🔄 연속 중복 감지 - 제목만 업데이트: '\(title)'")
            return
        }
        
        // ✅ **원래대로**: 새 페이지 추가 시 당연히 앞으로가기 스택 제거
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🗑️ 새 페이지 추가 - 앞으로가기 스택 \(removedCount)개 제거")
        }
        
        let newRecord = PageRecord(url: url, title: title)
        pageHistory.append(newRecord)
        setCurrentPageIndex(pageHistory.count - 1, reason: "새 페이지 추가")
        
        // 인접 중복 제거 실행
        removeAdjacentDuplicates()
        
        dbg("📄 새 페이지 추가: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] (총 \(pageHistory.count)개)")
        
        // 전역 히스토리에도 추가
        let normalizedURL = normalizeURLForDuplicateCheck(url)
        if !PageRecord.isLoginRelatedURL(url) && !Self.globalHistory.contains(where: { 
            normalizeURLForDuplicateCheck($0.url) == normalizedURL 
        }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }
    
    func updateCurrentPageTitle(_ title: String) {
        guard currentPageIndex >= 0, 
              currentPageIndex < pageHistory.count,
              !title.isEmpty else { 
            return 
        }
        
        var updatedRecord = pageHistory[currentPageIndex]
        updatedRecord.updateTitle(title)
        pageHistory[currentPageIndex] = updatedRecord
    }
    
    var currentPageRecord: PageRecord? {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return nil }
        return pageHistory[currentPageIndex]
    }
    
    // MARK: - 네비게이션 메서드
    
    func navigateBack() -> PageRecord? {
        guard canGoBack, currentPageIndex > 0 else { 
            dbg("❌ navigateBack 실패: canGoBack=\(canGoBack), currentIndex=\(currentPageIndex)")
            return nil
        }
        
        isHistoryNavigation = true
        setCurrentPageIndex(currentPageIndex - 1, reason: "뒤로가기")
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            dbg("⬅️ 뒤로가기: '\(record.title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
            return record
        }
        
        return nil
    }
    
    func navigateForward() -> PageRecord? {
        guard canGoForward, currentPageIndex < pageHistory.count - 1 else { 
            dbg("❌ navigateForward 실패: canGoForward=\(canGoForward), currentIndex=\(currentPageIndex), count=\(pageHistory.count)")
            return nil
        }
        
        isHistoryNavigation = true
        setCurrentPageIndex(currentPageIndex + 1, reason: "앞으로가기")
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            dbg("➡️ 앞으로가기: '\(record.title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
            return record
        }
        
        return nil
    }
    
    func navigateToIndex(_ index: Int) -> PageRecord? {
        guard index >= 0, index < pageHistory.count else { return nil }
        
        isHistoryNavigation = true
        setCurrentPageIndex(index, reason: "인덱스 네비게이션")
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            dbg("🎯 인덱스 네비게이션: '\(record.title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
            return record
        }
        
        return nil
    }
    
    // MARK: - 세션 저장/복원
    
    func saveSession() -> WebViewSession? {
        guard !pageHistory.isEmpty, currentPageIndex >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 없음")
            return nil
        }
        
        let filteredHistory = pageHistory.filter { !$0.isLoginRelated && !$0.isTemporary }
        
        if filteredHistory.isEmpty {
            dbg("💾 세션 저장 실패: 유효한 히스토리 없음")
            return nil
        }
        
        let adjustedIndex = min(max(0, currentPageIndex), filteredHistory.count - 1)
        
        let session = WebViewSession(pageRecords: filteredHistory, currentIndex: adjustedIndex)
        dbg("💾 세션 저장: \(filteredHistory.count)개 페이지, 현재 인덱스 \(adjustedIndex)")
        return session
    }

    func restoreSession(_ session: WebViewSession) {
        dbg("🔄 === 세션 복원 시작 ===")
        isRestoringSession = true
        
        pageHistory = session.pageRecords
        setCurrentPageIndex(max(0, min(session.currentIndex, pageHistory.count - 1)), reason: "세션 복원")
        
        if !pageHistory.isEmpty {
            dbg("🔄 세션 복원: \(pageHistory.count)개 페이지, 현재 인덱스 \(currentPageIndex)")
        } else {
            dbg("🔄 세션 복원 실패: 유효한 페이지 없음")
        }
    }
    
    func finishSessionRestore() {
        isRestoringSession = false
    }
    
    // MARK: - 페이지 검색 (최근 페이지만)
    
    func findPageIndex(for url: URL) -> Int? {
        let normalizedURL = normalizeURLForDuplicateCheck(url)
        
        // 마지막 5개 페이지에서만 찾기 (옛날 기록 무시)
        let recentRange = max(0, pageHistory.count - 5)..<pageHistory.count
        
        for index in recentRange.reversed() {
            let record = pageHistory[index]
            if normalizeURLForDuplicateCheck(record.url) == normalizedURL {
                dbg("🔍 최근 페이지 검색: \(url.absoluteString) → 인덱스 \(index)")
                return index
            }
        }
        
        dbg("🔍 최근 페이지 없음: \(url.absoluteString)")
        return nil
    }
    
    // MARK: - 스와이프 제스처 처리
    
    func handleSwipeGestureDetected(to url: URL) {
        guard !isHistoryNavigationActive() else {
            return
        }
        
        // 홈 클릭 처리 중이면 지연 처리
        if isInHomeNavigationHandling() {
            dbg("🏠 홈 클릭 처리 중 - 스와이프 감지 지연: \(url.absoluteString)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !self.isInHomeNavigationHandling() {
                    self.handleSwipeGestureDetected(to: url)
                }
            }
            return
        }
        
        // 최근 페이지만 찾기
        if let foundIndex = findPageIndex(for: url) {
            if foundIndex != currentPageIndex {
                swipeDetectedTargetIndex = foundIndex
                
                swipeConfirmationTimer?.invalidate()
                swipeConfirmationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    _ = self?.confirmSwipeGesture()
                }
                
                dbg("👆 스와이프 감지: 타겟 인덱스 \(foundIndex) (현재 \(currentPageIndex))")
            }
        } else {
            dbg("👆 스와이프 감지 - 최근 페이지 없음: \(url.absoluteString)")
        }
    }
    
    private func confirmSwipeGesture() -> PageRecord? {
        guard let targetIndex = swipeDetectedTargetIndex else { return nil }
        
        if let record = navigateToIndex(targetIndex) {
            swipeDetectedTargetIndex = nil
            dbg("👆 스와이프 제스처 확정: 인덱스=\(currentPageIndex)/\(pageHistory.count)")
            return record
        }
        
        return nil
    }
    
    // MARK: - 상태 관리 헬퍼
    
    func clearHistory() {
        Self.globalHistory.removeAll()
        Self.saveGlobalHistory()
        pageHistory.removeAll()
        setCurrentPageIndex(-1, reason: "히스토리 삭제")
        resetNavigationFlags()
        dbg("🧹 전체 히스토리 삭제")
    }
    
    func resetNavigationFlags() {
        isHistoryNavigation = false
        historyNavigationStartTime = nil
        swipeDetectedTargetIndex = nil
        swipeConfirmationTimer?.invalidate()
        swipeConfirmationTimer = nil
        redirectionChain.removeAll()
        redirectionStartTime = nil
        
        isSPANavigation = false
        lastSPANavigationTime = nil
        
        isInLoginFlow = false
        loginRedirectChain.removeAll()
        loginRedirectStartTime = nil
        
        endReloadWindow()
        
        isHandlingHomeNavigation = false
        homeNavigationEndTime = nil
    }
    
    func isHistoryNavigationActive() -> Bool {
        if isHistoryNavigation {
            if let startTime = historyNavigationStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 1.0 {
                    isHistoryNavigation = false
                    historyNavigationStartTime = nil
                    return false
                }
                return true
            }
        }
        return false
    }
    
    private func isSPANavigationActive() -> Bool {
        if isSPANavigation { return true }
        
        if let lastTime = lastSPANavigationTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            return elapsed < 1.0
        }
        
        return false
    }
    
    // MARK: - 로그인 리다이렉트 관리
    
    private func startLoginRedirectTracking(url: URL) {
        isInLoginFlow = true
        loginRedirectChain = [url]
        loginRedirectStartTime = Date()
        dbg("🔒 로그인 플로우 시작: \(url.absoluteString)")
    }
    
    private func addToLoginRedirectChain(url: URL) {
        if isInLoginFlow {
            loginRedirectChain.append(url)
            dbg("🔒 로그인 리다이렉트 체인 추가: \(url.absoluteString)")
        }
    }
    
    private func finishLoginRedirectTracking(finalURL: URL) {
        if isInLoginFlow {
            dbg("🔒 로그인 플로우 완료: \(loginRedirectChain.count)개 리다이렉트 → \(finalURL.absoluteString)")
            
            cleanupLoginRedirectPages()
            
            isInLoginFlow = false
            loginRedirectChain.removeAll()
            loginRedirectStartTime = nil
        }
    }
    
    private func cleanupLoginRedirectPages() {
        let originalCount = pageHistory.count
        
        pageHistory.removeAll { record in
            record.isLoginRelated || 
            record.isTemporary || 
            loginRedirectChain.contains(record.url)
        }
        
        if currentPageIndex >= pageHistory.count {
            setCurrentPageIndex(max(0, pageHistory.count - 1), reason: "로그인 페이지 정리")
        }
        
        let removedCount = originalCount - pageHistory.count
        if removedCount > 0 {
            dbg("🔒 로그인 관련 페이지 \(removedCount)개 제거")
        }
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stateModel?.handleLoadingStart()
        
        let startURL = webView.url
        
        // 자동 스와이프 감지
        if let startURL = startURL, 
           !isRestoringSession, 
           !isHistoryNavigationActive(),
           stateModel?.currentURL != startURL {
            
            if isInHomeNavigationHandling() {
                dbg("🏠 홈 클릭 처리 중 - 자동 스와이프 지연 처리")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if !self.isInHomeNavigationHandling() {
                        self.handleSwipeGestureDetected(to: startURL)
                    }
                }
            } else {
                handleSwipeGestureDetected(to: startURL)
                dbg("🔍 자동 스와이프 감지 실행: \(startURL.absoluteString)")
            }
        }
        
        // 리다이렉트 체인 관리
        if let url = startURL {
            let now = Date()
            
            if redirectionChain.isEmpty || redirectionStartTime == nil || 
               now.timeIntervalSince(redirectionStartTime!) > 3.0 {
                redirectionChain = [url]
                redirectionStartTime = now
            } else {
                redirectionChain.append(url)
            }
            
            if isInLoginFlow {
                addToLoginRedirectChain(url: url)
            }
        }
        
        dbg("🚀 네비게이션 시작: \(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        stateModel?.handleLoadingFinish()
        
        let title = webView.title ?? webView.url?.host ?? "제목 없음"
        
        let wasRestoringSession = isRestoringSession
        
        if let finalURL = webView.url {
            if isRestoringSession {
                updateCurrentPageTitle(title)
                finishSessionRestore()
                dbg("🔄 복원 완료: '\(title)'")
                
            } else if isHistoryNavigationActive() {
                updateCurrentPageTitle(title)
                
                if stateModel?.currentURL != finalURL {
                    stateModel?.syncCurrentURL(finalURL)
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.resetNavigationFlags()
                }
                
                dbg("🔄 히스토리 네비게이션 완료: '\(title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
                
            } else {
                addNewPage(url: finalURL, title: title)
                stateModel?.syncCurrentURL(finalURL)
                dbg("🆕 새 페이지 기록: '\(title)' (총 \(pageHistory.count)개)")
            }
            
            redirectionChain.removeAll()
            redirectionStartTime = nil
        }
        
        if !wasRestoringSession {
            stateModel?.triggerNavigationFinished()
        }
        
        dbg("✅ 네비게이션 완료")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        resetNavigationFlags()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? stateModel?.currentURL?.absoluteString ?? "")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        resetNavigationFlags()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? stateModel?.currentURL?.absoluteString ?? "")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            
            if statusCode >= 400 {
                stateModel?.notifyHTTPError(statusCode, url: navigationResponse.response.url?.absoluteString ?? "")
            }
        }
        
        stateModel?.handleDownloadDecision(navigationResponse, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        stateModel?.handleDidCommitNavigation(webView)
    }
    
    // MARK: - 전역 히스토리 관리
    
    private static func saveGlobalHistory() {
        let filteredHistory = globalHistory.filter { !PageRecord.isLoginRelatedURL($0.url) }
        
        if let data = try? JSONEncoder().encode(filteredHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
            TabPersistenceManager.debugMessages.append("[\(ts())] ☁️ 전역 방문 기록 저장: \(filteredHistory.count)개")
        }
    }

    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
            TabPersistenceManager.debugMessages.append("[\(ts())] ☁️ 전역 방문 기록 로드: \(loaded.count)개")
        }
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
    
    // MARK: - 디버그 메서드
    
    private func dbg(_ msg: String) {
        let id: String
        if let tabID = tabID {
            id = String(tabID.uuidString.prefix(6))
        } else {
            id = "noTab"
        }
        
        let navState = "B:\(canGoBack ? "✅" : "❌") F:\(canGoForward ? "✅" : "❌")"
        let homeState = isInHomeNavigationHandling() ? "🏠Home" : ""
        let historyCount = "[\(pageHistory.count)]"
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(historyCount)\(homeState) \(msg)")
    }

    // MARK: - 메모리 정리
    deinit {
        swipeConfirmationTimer?.invalidate()
    }
}

// MARK: - 방문기록 페이지 뷰
extension WebViewDataModel {
    public struct HistoryPage: View {
        @ObservedObject var dataModel: WebViewDataModel
        let onNavigateToPage: (PageRecord) -> Void
        let onNavigateToURL: (URL) -> Void
        
        @State private var searchQuery: String = ""
        @Environment(\.dismiss) private var dismiss
        
        private var dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df
        }()

        public init(
            dataModel: WebViewDataModel,
            onNavigateToPage: @escaping (PageRecord) -> Void,
            onNavigateToURL: @escaping (URL) -> Void
        ) {
            self.dataModel = dataModel
            self.onNavigateToPage = onNavigateToPage
            self.onNavigateToURL = onNavigateToURL
        }

        private var sessionHistory: [PageRecord] {
            return dataModel.pageHistory.reversed()
        }
        
        private var filteredGlobalHistory: [HistoryEntry] {
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return WebViewDataModel.globalHistory.sorted { $0.date > $1.date } }
            return WebViewDataModel.globalHistory
                .filter { $0.url.absoluteString.lowercased().contains(q) || $0.title.lowercased().contains(q) }
                .sorted { $0.date > $1.date }
        }

        public var body: some View {
            List {
                if !sessionHistory.isEmpty {
                    Section("현재 세션 (\(sessionHistory.count)개)") {
                        ForEach(sessionHistory) { record in
                            SessionHistoryRowView(
                                record: record, 
                                isCurrent: record.id == dataModel.currentPageRecord?.id
                            )
                            .onTapGesture {
                                onNavigateToPage(record)
                                dismiss()
                            }
                        }
                    }
                }
                
                Section("전체 기록 (\(filteredGlobalHistory.count)개)") {
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
                            onNavigateToURL(item.url)
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
                        dataModel.clearHistory()
                    }
                }
            }
        }

        func deleteGlobalHistory(at offsets: IndexSet) {
            let items = filteredGlobalHistory
            let targets = offsets.map { items[$0] }
            WebViewDataModel.globalHistory.removeAll { targets.contains($0) }
            WebViewDataModel.saveGlobalHistory()
            TabPersistenceManager.debugMessages.append("[\(ts())] 🧹 방문 기록 삭제: \(targets.count)개")
        }
    }
}

// MARK: - 세션 히스토리 행 뷰
struct SessionHistoryRowView: View {
    let record: PageRecord
    let isCurrent: Bool
    
    private var navigationTypeIcon: String {
        switch record.navigationType {
        case .navHome: return "house.fill"
        case .reloadSoft, .reloadHard: return "arrow.clockwise"
        case .navListFirst: return "list.bullet"
        case .spaNavigation: return "sparkles"
        default: return "circle"
        }
    }
    
    private var navigationTypeColor: Color {
        switch record.navigationType {
        case .navHome: return .green
        case .reloadSoft, .reloadHard: return .orange
        case .navListFirst: return .purple
        case .spaNavigation: return .blue
        default: return .gray
        }
    }
    
    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "arrow.right.circle.fill" : navigationTypeIcon)
                .foregroundColor(isCurrent ? .blue : navigationTypeColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(record.title)
                        .font(isCurrent ? .headline : .body)
                        .fontWeight(isCurrent ? .bold : .regular)
                        .lineLimit(1)
                    
                    if let siteType = record.siteType {
                        Text("[\(siteType)]")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    if record.navigationType != .normal {
                        Text(record.navigationType.rawValue)
                            .font(.caption2)
                            .foregroundColor(navigationTypeColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(navigationTypeColor.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    Spacer()
                }
                
                Text(record.url.absoluteString)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                
                HStack {
                    Text("ID: \(String(record.id.uuidString.prefix(8)))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if record.isLoginRelated {
                        Text("🔒로그인")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    
                    if record.isTemporary {
                        Text("⏳임시")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                    
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
