//
//  WebViewDataModel.swift
//  🌐 통합된 SPA 네비게이션 관리 (쿨다운/포스트머지 제거)
//  🎯 핵심 방어 로직만 유지
//  ✅ 홈클릭 마지막세션 문제 + 인접 중복제거 강화
//  🔧 홈 클릭 히스토리 문제 수정: 항상 새 페이지로 추가
//

import Foundation
import SwiftUI
import WebKit

// MARK: - 네비게이션 타입 정의 (Codable enum으로 타입 안정성 보장)
enum NavigationType: String, Codable, CaseIterable {
    case normal = "normal"
    case reloadSoft = "reloadSoft"
    case reloadHard = "reloadHard"
    case navHome = "navHome"
    case navListFirst = "navListFirst"
    case spaNavigation = "spaNavigation"
    case loginRedirect = "loginRedirect"
}

// MARK: - 페이지 식별자 (제목, 주소, 시간 포함)
struct PageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL // ✅ var로 변경 (새로고침/교체 시 갱신 가능)
    var title: String
    let timestamp: Date
    var lastAccessed: Date
    
    // 🌐 사이트 메타데이터 추가
    var siteType: String?
    var isLoginRelated: Bool = false
    var isTemporary: Bool = false
    var navigationType: NavigationType = .normal // ✅ Codable enum 사용
    
    init(url: URL, title: String = "", siteType: String? = nil, navigationType: NavigationType = .normal) {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? (url.host ?? "제목 없음") : title
        self.timestamp = Date()
        self.lastAccessed = Date()
        self.siteType = siteType
        self.navigationType = navigationType // ✅ enum 직접 할당
        
        // 🔒 로그인 관련 URL 자동 감지
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
    
    // 🔒 로그인 관련 URL 감지
    static func isLoginRelatedURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()
        let loginPatterns = [
            "login", "signin", "auth", "oauth", "sso", "redirect", "callback",
            "nid.naver.com", "accounts.google.com", "facebook.com/login", "twitter.com/oauth",
            "returnurl=", "redirect_uri=", "continue=", "state=", "code="
        ]
        
        return loginPatterns.contains { urlString.contains($0) }
    }
    
    // 🔒 임시 페이지 감지
    static func isTemporaryURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()
        let tempPatterns = [
            "loading", "wait", "processing", "intermediate", "bridge", "proxy",
            "temp", "tmp", "cache", "blank", "about:blank", "javascript:"
        ]
        
        return tempPatterns.contains { urlString.contains($0) }
    }
    
    // 🆕 URL 정규화 비교 (새로고침 감지용)
    static func normalizeURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        // HTTPS 우선 정규화
        if components?.scheme == "http" {
            components?.scheme = "https"
        }
        
        // 트레일링 슬래시 제거
        if let path = components?.path, path.hasSuffix("/") && path.count > 1 {
            components?.path = String(path.dropLast())
        }
        
        // 쿼리 파라미터 정렬
        if let queryItems = components?.queryItems {
            components?.queryItems = queryItems.sorted { $0.name < $1.name }
        }
        
        // 해시는 무시 (같은 페이지로 취급)
        components?.fragment = nil
        
        return components?.url?.absoluteString ?? url.absoluteString
    }
    
    func normalizedURL() -> String {
        return Self.normalizeURL(self.url)
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

// MARK: - WebViewDataModel (정리된 버전)
final class WebViewDataModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID?
    
    // 페이지 기록 기반 히스토리 (✅ 무제한)
    @Published private(set) var pageHistory: [PageRecord] = []
    @Published private(set) var currentPageIndex: Int = -1
    
    // 🎯 **완전 독립형 네비게이션 상태** (웹뷰와 무관)
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    
    // 복원 상태 관리
    private(set) var isRestoringSession: Bool = false
    
    // ✅ 강화된 히스토리 네비게이션 플래그 (시간 단축)
    private var isHistoryNavigation: Bool = false {
        didSet {
            if isHistoryNavigation {
                historyNavigationStartTime = Date()
            } else {
                historyNavigationStartTime = nil
                // 🔧 **수정**: 히스토리 네비게이션 완료 후 차단 시간을 2초로 연장
                historyNavigationEndTime = Date().addingTimeInterval(2.0) // 1초 → 2초로 연장
            }
        }
    }
    
    private var historyNavigationStartTime: Date?
    private var historyNavigationEndTime: Date? // 🔧 히스토리 네비게이션 완료 후 차단 시간
    
    // 🆕 새로고침 윈도 관리 (단축)
    private var isInReloadWindow: Bool = false
    private var reloadWindowStartTime: Date?
    private let reloadWindowDuration: TimeInterval = 0.5 // ✅ 1초 → 0.5초로 단축
    
    // ✅ 홈 클릭 처리 상태 (SPA 로직 차단용)
    private var isHandlingHomeNavigation: Bool = false
    private var homeNavigationEndTime: Date?
    
    // ✅ 스와이프 제스처 관련
    private var swipeDetectedTargetIndex: Int? = nil
    private var swipeConfirmationTimer: Timer?
    
    // 리다이렉트 감지용
    private var redirectionChain: [URL] = []
    private var redirectionStartTime: Date?
    
    // 🌐 **통합된 SPA 네비게이션 상태 관리**
    private var isSPANavigation: Bool = false
    private var lastSPANavigationTime: Date?
    
    // 🔒 로그인 리다이렉트 체인 추적
    private var loginRedirectChain: [URL] = []
    private var loginRedirectStartTime: Date?
    private var isInLoginFlow: Bool = false
    
    // 🛡️ 간소화된 중복 필터 (버킷 방식 유지)
    private func bucket(for url: URL) -> String { url.host ?? "_" }
    private var perBucketLastByNorm: [String: [String: Date]] = [:]
    private let dupWindow: TimeInterval = 0.8 // ✅ 1.2초 → 0.8초로 단축
    
    private func recentlyVisitedInBucket(_ url: URL) -> Bool {
        let b = bucket(for: url)
        let key = PageRecord.normalizeURL(url)
        let now = Date()
        var map = perBucketLastByNorm[b] ?? [:]
        defer { map[key] = now; perBucketLastByNorm[b] = map }
        if let t = map[key], now.timeIntervalSince(t) < dupWindow { 
            dbg("🛡️ 버킷[\(b)] 최근 동일 정규화 URL: \(key)")
            return true 
        }
        return false
    }
    
    // 전역 방문기록 (✅ 무제한)
    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }
    
    // WebViewStateModel 참조
    weak var stateModel: WebViewStateModel?
    
    override init() {
        super.init()
        Self.loadGlobalHistory()
    }
    
    // 🎯 **완전 독립형 네비게이션 상태 관리**
    
    private func updateNavigationState() {
        let newCanGoBack = currentPageIndex > 0
        let newCanGoForward = currentPageIndex < pageHistory.count - 1
        
        if canGoBack != newCanGoBack || canGoForward != newCanGoForward {
            canGoBack = newCanGoBack
            canGoForward = newCanGoForward
            
            objectWillChange.send()
            
            dbg("🎯 독립형 네비게이션 상태: back=\(canGoBack), forward=\(canGoForward), index=\(currentPageIndex)/\(pageHistory.count)")
        }
    }
    
    // 🆕 새로고침 윈도 관리 (단축)
    private func startReloadWindow() {
        isInReloadWindow = true
        reloadWindowStartTime = Date()
        dbg("🔄 새로고침 윈도 시작 (0.5초)")
        
        // 자동 해제
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
    
   // ✅ 홈 클릭 처리 상태 관리 (SPA 로직 차단)
private func startHomeNavigationHandling() {
    // 🔧 사후 점프(race) 방지: 스와이프 타이머/히스토리 플래그 즉시 무효화
    isHistoryNavigation = false
    historyNavigationStartTime = nil
    swipeDetectedTargetIndex = nil
    swipeConfirmationTimer?.invalidate()
    swipeConfirmationTimer = nil

    isHandlingHomeNavigation = true
    homeNavigationEndTime = Date().addingTimeInterval(1.0) // 1초간 차단
    dbg("🏠 홈 클릭 처리 시작 - SPA 로직 1초간 차단 (스와이프/히스토리 플래그 해제)")
}

    
    private func isInHomeNavigationHandling() -> Bool {
        guard isHandlingHomeNavigation, let endTime = homeNavigationEndTime else { return false }
        
        if Date() > endTime {
            isHandlingHomeNavigation = false
            homeNavigationEndTime = nil
            dbg("🏠 홈 클릭 처리 완료 - SPA 로직 차단 해제")
            return false
        }
        
        return true
    }
    
    // MARK: - ✅ 인접 중복 제거 (현재 페이지 ± 1 위치만 체크)
    
    private func removeAdjacentDuplicates() {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return }
        
        let currentRecord = pageHistory[currentPageIndex]
        let currentNormalizedURL = normalizeURLForDuplicateCheck(currentRecord.url)
        var removedCount = 0
        
        // 1️⃣ 바로 앞 페이지 체크 (currentPageIndex - 1)
        if currentPageIndex > 0 {
            let prevIndex = currentPageIndex - 1
            let prevRecord = pageHistory[prevIndex]
            let prevNormalizedURL = normalizeURLForDuplicateCheck(prevRecord.url)
            
            if currentNormalizedURL == prevNormalizedURL {
                dbg("🔄 인접 중복 제거 (앞): '\(prevRecord.title)' [인덱스: \(prevIndex)]")
                pageHistory.remove(at: prevIndex)
                currentPageIndex -= 1  // 인덱스 조정
                removedCount += 1
            }
        }
        
        // 2️⃣ 바로 뒤 페이지 체크 (currentPageIndex + 1) - 앞 페이지 제거로 인덱스 변경 반영
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
            updateNavigationState()
            dbg("🔄 인접 중복 제거 완료: \(removedCount)개 제거, 남은 히스토리: \(pageHistory.count)개")
        }
    }
    
    // MARK: - 🌐 **통합된 SPA 네비게이션 처리** (간소화)
    
    func handleSPANavigation(type: String, url: URL, title: String, timestamp: Double, siteType: String = "unknown") {
        // ✅ 홈 클릭 처리 중이면 SPA 로직 차단
        if isInHomeNavigationHandling() {
            dbg("🏠 홈 클릭 처리 중 - SPA \(type) 무시: \(url.absoluteString)")
            return
        }
        
        // 🆕 새로고침 윈도에서 replace만 차단 (push는 허용)
        if isInActiveReloadWindow() && type == "replace" {
            dbg("🔄 새로고침 윈도 중 SPA replace 무시: \(url.absoluteString)")
            return
        }
        
        // SPA 네비게이션 플래그 설정
        isSPANavigation = true
        lastSPANavigationTime = Date()
        
        dbg("🌐 SPA \(type) 감지: \(siteType) | \(url.absoluteString) | '\(title)'")
        
        // 🆕 새로고침 감지 로직
        if type == "push" || type == "replace" {
            if let currentRecord = currentPageRecord,
               PageRecord.normalizeURL(currentRecord.url) == PageRecord.normalizeURL(url) {
                // 동일한 정규화 URL → 새로고침으로 처리
                handleRefreshNavigation(url: url, title: title, type: type, siteType: siteType)
                return
            }
        }
        
        // 🆕 홈 클릭 감지 (사이트 루트로의 이동)
        let navigationType = detectNavigationType(url: url, type: type, siteType: siteType)
        
        switch navigationType {
        case .navHome:
            handleHomeNavigation(url: url, title: title, siteType: siteType)
            
        case .reloadSoft, .reloadHard:
            handleRefreshNavigation(url: url, title: title, type: type, siteType: siteType)
            
        default:
            // 기존 SPA 네비게이션 로직
            handleRegularSPANavigation(type: type, url: url, title: title, siteType: siteType, navigationType: navigationType)
        }
        
        // 전역 히스토리에도 추가 (중복 및 로그인 관련 제외)
        if type != "title" && !PageRecord.isLoginRelatedURL(url) && !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
        
        // 1초 후 플래그 해제 (단축)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isSPANavigation = false
        }
    }
    
    // 🆕 네비게이션 타입 감지 (🔧 홈 클릭 감지 강화)
    private func detectNavigationType(url: URL, type: String, siteType: String) -> NavigationType {
        // 🔧 **핵심 수정**: 홈 클릭 감지 강화 - 루트 경로로의 이동을 더 명확히 감지
        if isHomepageURL(url) {
            if let currentRecord = currentPageRecord,
               url.host == currentRecord.url.host &&
               !isHomepageURL(currentRecord.url) {
                dbg("🏠 홈 클릭 감지 강화: \(currentRecord.url.path) → \(url.path)")
                return .navHome
            }
        }
        
        // 리로드 감지 (동일 정규화 URL)
        if let currentRecord = currentPageRecord,
           PageRecord.normalizeURL(currentRecord.url) == PageRecord.normalizeURL(url) {
            return type == "replace" ? .reloadSoft : .reloadHard
        }
        
        // 보드 내 첫 페이지 이동 감지 (같은 호스트, 다른 경로지만 리스트형)
        if siteType.contains("list") || siteType.contains("page_1") {
            return .navListFirst
        }
        
        return .normal
    }
    
    // 🔧 **새로 추가**: 홈페이지 URL 감지 로직
    private func isHomepageURL(_ url: URL) -> Bool {
        let path = url.path
        // 루트 경로거나, 슬래시만 있거나, 빈 경로이거나, index 관련 파일
        return path == "/" || 
               path.isEmpty || 
               path == "/index" ||
               path == "/index.html" ||
               path == "/index.php" ||
               path == "/main" ||
               path == "/home"
    }
    
    // 🆕 새로고침 처리 (무조건 replace, ID 유지)
    private func handleRefreshNavigation(url: URL, title: String, type: String, siteType: String) {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else {
            dbg("❌ 새로고침 실패: 유효하지 않은 현재 인덱스")
            return
        }
        
        // ✅ 기존 레코드의 ID 유지하며 현재 위치의 페이지 기록을 교체
        var rec = pageHistory[currentPageIndex]
        rec.url = url
        rec.updateTitle(title)
        rec.siteType = siteType
        rec.navigationType = (type == "replace") ? .reloadSoft : .reloadHard // ✅ enum 사용
        pageHistory[currentPageIndex] = rec
        
        // 새로고침 윈도 시작
        startReloadWindow()
        
        dbg("🔄 새로고침 감지 - 현재 페이지 교체: '\(title)' [ID: \(String(rec.id.uuidString.prefix(8)))]")
        
        // StateModel URL 동기화
        stateModel?.syncCurrentURL(url)
    }
    
    // ✅ **수정**: 홈 클릭 처리 - 정상적인 새 페이지 추가 후 SPA 차단
    private func handleHomeNavigation(url: URL, title: String, siteType: String) {
        dbg("🏠 홈 클릭 감지: \(url.absoluteString)")
        
        // SPA 로직 차단 시작
        startHomeNavigationHandling()
        
        // Forward 스택 제거 (명시적 push이므로)
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🗑️ 홈 클릭 - forward 스택 \(removedCount)개 제거")
        }
        
        // 새 홈 페이지 추가
        let newRecord = PageRecord(url: url, title: title, siteType: siteType, navigationType: .navHome)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // ✅ 인접 중복 제거 실행
        removeAdjacentDuplicates()
        
        updateNavigationState()
        
        dbg("🏠 홈 클릭 - 새 페이지 추가: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
        
        // StateModel URL 동기화
        stateModel?.syncCurrentURL(url)
    }
    
    // 기존 SPA 네비게이션 로직
    private func handleRegularSPANavigation(type: String, url: URL, title: String, siteType: String, navigationType: NavigationType) {
        switch type {
        case "push":
            handleSPAPushState(url: url, title: title, siteType: siteType, navigationType: navigationType)
            
        case "replace":
            handleSPAReplaceState(url: url, title: title, siteType: siteType)
            
        case "pop", "hash":
            // 🔧 **핵심 수정**: 홈페이지 URL의 경우 항상 새 페이지로 추가
            if isHomepageURL(url) {
                dbg("🏠 SPA Pop에서 홈페이지 감지 - 새 페이지로 처리: \(url.absoluteString)")
                handleSPAPushState(url: url, title: title, siteType: siteType, navigationType: .navHome)
            } else {
                handleSPAPopState(url: url, title: title, siteType: siteType)
            }
            
        case "iframe_push":
            handleSPAIframePush(url: url, title: title, siteType: siteType)
            
        case "title":
            updateCurrentPageTitle(title)
            
        case "dom":
            // 🔧 **핵심 수정**: DOM 변경도 홈페이지 URL이면 새 페이지로 처리
            if isHomepageURL(url) {
                dbg("🏠 SPA DOM에서 홈페이지 감지 - 새 페이지로 처리: \(url.absoluteString)")
                handleSPAPushState(url: url, title: title, siteType: siteType, navigationType: .navHome)
            } else {
                handleSPADOMChange(url: url, title: title, siteType: siteType)
            }
            
        default:
            dbg("🌐 알 수 없는 SPA 네비게이션 타입: \(type)")
        }
    }
    
    private func handleSPAPushState(url: URL, title: String, siteType: String, navigationType: NavigationType) {
        // ✅ 명확한 replace 기준: 경로는 같고 쿼리만 다른 경우
        if let currentRecord = currentPageRecord,
           currentRecord.url.host == url.host,
           currentRecord.url.path == url.path,
           currentRecord.url.query != url.query {
            // 같은 경로에서 쿼리만 변경 → replace 처리
            handleSPAReplaceState(url: url, title: title, siteType: siteType)
            dbg("🔄 SPA Push → Replace: 같은 경로, 쿼리만 변경")
            return
        }
        
        // Forward 스택 제거: 오직 명시적 "push"에서만
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🗑️ SPA Push - forward 스택 \(removedCount)개 제거")
        }
        
        let newRecord = PageRecord(url: url, title: title, siteType: siteType, navigationType: navigationType)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // ✅ 인접 중복 제거 실행
        removeAdjacentDuplicates()
        
        updateNavigationState()
        dbg("🌐 SPA 새 페이지: \(siteType) '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))]")
        
        // StateModel URL 동기화
        stateModel?.syncCurrentURL(url)
    }
    
    private func handleSPAReplaceState(url: URL, title: String, siteType: String) {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else {
            handleSPAPushState(url: url, title: title, siteType: siteType, navigationType: .normal)
            return
        }
        
        // ✅ 기존 레코드의 ID 유지하며 필드만 업데이트
        var rec = pageHistory[currentPageIndex]
        rec.url = url
        rec.updateTitle(title)
        rec.siteType = siteType
        rec.navigationType = .spaNavigation // ✅ enum 사용
        pageHistory[currentPageIndex] = rec
        
        dbg("🌐 SPA 페이지 교체: \(siteType) '\(rec.title)' [ID: \(String(rec.id.uuidString.prefix(8)))]")
        
        // StateModel URL 동기화
        stateModel?.syncCurrentURL(url)
    }
    
    private func handleSPAPopState(url: URL, title: String, siteType: String) {
        // ✅ **수정**: 히스토리 내에서 해당 URL 찾기 (강화된 정규화 + 가장 최근 것 우선)
        let normalizedURL = normalizeURLForDuplicateCheck(url)
        let matchingIndices = pageHistory.enumerated().compactMap { index, record in
            normalizeURLForDuplicateCheck(record.url) == normalizedURL ? index : nil
        }
        
        if let foundIndex = matchingIndices.last { // ✅ 가장 최근에 추가된 페이지 선택
            // 히스토리 내 이동
            currentPageIndex = foundIndex
            
            // 제목 및 메타데이터 업데이트
            var updatedRecord = pageHistory[currentPageIndex]
            updatedRecord.updateTitle(title)
            updatedRecord.updateAccess()
            updatedRecord.siteType = siteType
            pageHistory[currentPageIndex] = updatedRecord
            
            updateNavigationState()
            dbg("🌐 SPA 히스토리 이동 (최신 우선): \(siteType) '\(updatedRecord.title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
            
            // StateModel URL 동기화
            stateModel?.syncCurrentURL(url)
        } else {
            // 히스토리에 없으면 새로 추가
            handleSPAPushState(url: url, title: title, siteType: siteType, navigationType: .normal)
        }
    }
    
    private func handleSPAIframePush(url: URL, title: String, siteType: String) {
        // iframe 내부 네비게이션은 보통 게시글 읽기 등이므로 일반 push와 동일하게 처리
        handleSPAPushState(url: url, title: title, siteType: "iframe_\(siteType)", navigationType: .normal)
    }
    
    private func handleSPADOMChange(url: URL, title: String, siteType: String) {
        // DOM 변경으로 인한 URL 변화는 보통 SPA 앱에서 발생
        // popstate나 hashchange와 유사하게 처리
        handleSPAPopState(url: url, title: title, siteType: "dom_\(siteType)")
    }
    
    // ✅ 개선된 URL 유사성 로직 - 더 명확한 기준
    private func areSimilarURLs(_ a: URL, _ b: URL) -> Bool {
        guard a.host == b.host else { return false }
        
        // 경로가 동일하면 유사
        if a.path == b.path { return true }
        
        // ✅ 리스트/상세 같은 얕은 경로만 유사로 판단 (더 보수적)
        let componentsA = a.pathComponents.dropFirst() // '/' 제거
        let componentsB = b.pathComponents.dropFirst()
        
        // 첫 번째 경로 컴포넌트만 비교 (예: /board/123 vs /board/456)
        return componentsA.prefix(1) == componentsB.prefix(1) && 
               componentsA.count <= 2 && componentsB.count <= 2 // 깊은 경로는 제외
    }
    
    // SPA 네비게이션 활성 상태 확인 (단축)
    private func isSPANavigationActive() -> Bool {
        if isSPANavigation { return true }
        
        if let lastTime = lastSPANavigationTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            return elapsed < 1.0 // ✅ 1.5초 → 1.0초로 단축
        }
        
        return false
    }
    
    // MARK: - 🔒 로그인 리다이렉트 체인 관리
    
    private func startLoginRedirectTracking(url: URL) {
        isInLoginFlow = true
        loginRedirectChain = [url]
        loginRedirectStartTime = Date()
        dbg("🔒 로그인 플로우 시작: \(url.absoluteString)")
    }
    
    private func addToLoginRedirectChain(url: URL) {
        if isInLoginFlow {
            loginRedirectChain.append(url)
            dbg("🔒 로그인 리다이렉트 체인 추가: \(url.absoluteString) (총 \(loginRedirectChain.count)개)")
        }
    }
    
    private func finishLoginRedirectTracking(finalURL: URL) {
        if isInLoginFlow {
            dbg("🔒 로그인 플로우 완료: \(loginRedirectChain.count)개 리다이렉트 → \(finalURL.absoluteString)")
            
            // 로그인 체인의 중간 페이지들을 히스토리에서 제거
            cleanupLoginRedirectPages()
            
            isInLoginFlow = false
            loginRedirectChain.removeAll()
            loginRedirectStartTime = nil
        }
    }
    
    private func cleanupLoginRedirectPages() {
        let originalCount = pageHistory.count
        
        // 로그인 관련 페이지들을 히스토리에서 제거
        pageHistory.removeAll { record in
            record.isLoginRelated || 
            record.isTemporary || 
            loginRedirectChain.contains(record.url)
        }
        
        // 현재 인덱스 조정
        if currentPageIndex >= pageHistory.count {
            currentPageIndex = max(0, pageHistory.count - 1)
        }
        
        let removedCount = originalCount - pageHistory.count
        if removedCount > 0 {
            updateNavigationState()
            dbg("🔒 로그인 관련 페이지 \(removedCount)개 제거, 남은 히스토리: \(pageHistory.count)개")
        }
    }
    
    // MARK: - 새로운 페이지 기록 시스템 (강화된 중복 제거)
    
    func addNewPage(url: URL, title: String = "") {
        // 🛡️ 핵심 차단: 히스토리 네비게이션 중 새 페이지 추가 금지
        if isHistoryNavigationActive() {
            if isHistoryNavigation {
                dbg("🔄 히스토리 네비게이션 진행 중 - 새 페이지 추가 차단: \(url.absoluteString)")
            } else {
                dbg("🔄 히스토리 네비게이션 완료 후 대기 중 - 새 페이지 추가 차단: \(url.absoluteString)")
            }
            return
        }
        
        // 🔧 **새로 추가**: 추가 히스토리 상태 체크 (더 엄격하게)
        if isHistoryNavigation || historyNavigationEndTime != nil {
            dbg("🔄 히스토리 관련 상태 - 새 페이지 추가 차단: \(url.absoluteString)")
            return
        }
        
        // 🌐 SPA 네비게이션 중인지 체크
        if isSPANavigationActive() {
            dbg("🌐 SPA 네비게이션 활성 중 - 일반 페이지 추가 건너뜀")
            return
        }
        
        // 🔧 홈페이지 URL 감지 시 스와이프 상태 즉시 정리
        if isHomepageURL(url) {
            swipeDetectedTargetIndex = nil
            swipeConfirmationTimer?.invalidate()
            swipeConfirmationTimer = nil
            dbg("🏠 홈페이지 감지 - 스와이프 상태 정리")
        }
        
        // 🔒 로그인 관련 URL 감지 및 추적
        if PageRecord.isLoginRelatedURL(url) {
            if !isInLoginFlow {
                startLoginRedirectTracking(url: url)
            } else {
                addToLoginRedirectChain(url: url)
            }
            
            // 로그인 페이지는 히스토리에 추가하지 않음
            dbg("🔒 로그인 페이지 히스토리 제외: \(url.absoluteString)")
            return
        }
        
        // 🔒 로그인 플로우가 진행 중이면서 일반 페이지에 도착한 경우
        if isInLoginFlow && !PageRecord.isLoginRelatedURL(url) {
            finishLoginRedirectTracking(finalURL: url)
        }
        
        // ✅ **연속 중복 체크**: 바로 앞 페이지와 같은 정규화 URL인지 확인
        if !pageHistory.isEmpty,
           let lastRecord = pageHistory.last,
           normalizeURLForDuplicateCheck(lastRecord.url) == normalizeURLForDuplicateCheck(url) {
            // 제목만 업데이트하고 새 기록 추가하지 않음
            updateCurrentPageTitle(title)
            dbg("🔄 연속 중복 감지 - 제목만 업데이트: '\(title)' | \(normalizeURLForDuplicateCheck(url))")
            return
        }
        
        // 현재 위치 이후의 forward 기록 제거
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            pageHistory.removeSubrange((currentPageIndex + 1)...)
        }
        
        let newRecord = PageRecord(url: url, title: title)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // ✅ 인접 중복 제거 실행
        removeAdjacentDuplicates()
        
        updateNavigationState()
        dbg("📄 새 페이지 추가: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] (총 \(pageHistory.count)개)")
        
        // 전역 히스토리에도 추가 (로그인 관련 제외 + 중복 체크)
        let normalizedURL = normalizeURLForDuplicateCheck(url)
        if !PageRecord.isLoginRelatedURL(url) && !Self.globalHistory.contains(where: { 
            normalizeURLForDuplicateCheck($0.url) == normalizedURL 
        }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }
    
    // ✅ **중복 체크용 강화된 URL 정규화** (쿼리/해시 제거)
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
        
        // ✅ **핵심**: 쿼리 파라미터와 해시 완전 제거 (중복 체크용)
        components?.query = nil
        components?.fragment = nil
        
        return components?.url?.absoluteString ?? url.absoluteString
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

    // MARK: - 세션 저장/복원

func saveSession() -> WebViewSession? {
    guard !pageHistory.isEmpty, currentPageIndex >= 0 else {
        dbg("💾 세션 저장 실패: 히스토리 없음")
        return nil
    }
    
    // 🔒 로그인/임시 페이지는 세션에서 제외
    let filteredHistory = pageHistory.filter { !$0.isLoginRelated && !$0.isTemporary }
    
    if filteredHistory.isEmpty {
        dbg("💾 세션 저장 실패: 유효한 히스토리 없음 (로그인/임시 페이지만 있음)")
        return nil
    }
    
    // ✅ 핵심 수정:
    // 필터링 전의 currentPageRecord가 필터링 후 배열에서 어디에 있는지 'id' 기준으로 찾는다.
    // id 매칭이 실패하면 정규화 URL로 재탐색하고, 그래도 없으면 맨 마지막을 가리킨다.
    let adjustedIndex: Int = {
        guard let curr = currentPageRecord else {
            return max(0, filteredHistory.count - 1)
        }
        if let idxByID = filteredHistory.firstIndex(where: { $0.id == curr.id }) {
            return idxByID
        }
        let norm = normalizeURLForDuplicateCheck(curr.url)
        if let idxByURL = filteredHistory.lastIndex(where: { normalizeURLForDuplicateCheck($0.url) == norm }) {
            return idxByURL
        }
        return max(0, filteredHistory.count - 1)
    }()
    
    let session = WebViewSession(pageRecords: filteredHistory, currentIndex: adjustedIndex)
    dbg("💾 세션 저장: \(filteredHistory.count)개 페이지 (원본 \(pageHistory.count)개), 현재 인덱스 \(adjustedIndex)")
    return session
}


    func restoreSession(_ session: WebViewSession) {
        dbg("🔄 === 세션 복원 시작 ===")
        isRestoringSession = true
        
        pageHistory = session.pageRecords
        currentPageIndex = max(0, min(session.currentIndex, pageHistory.count - 1))
        
        updateNavigationState()
        
        if !pageHistory.isEmpty {
            dbg("🔄 세션 복원: \(pageHistory.count)개 페이지, 현재 인덱스 \(currentPageIndex)")
        } else {
            dbg("🔄 세션 복원 실패: 유효한 페이지 없음")
        }
    }
    
    func finishSessionRestore() {
        isRestoringSession = false
    }

    // MARK: - 🎯 **완전 독립형 네비게이션 메서드**
    
    func navigateBack() -> PageRecord? {
        guard canGoBack, currentPageIndex > 0 else { 
            dbg("❌ navigateBack 실패: canGoBack=\(canGoBack), currentIndex=\(currentPageIndex)")
            return nil
        }
        
        isHistoryNavigation = true
        currentPageIndex -= 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            updateNavigationState()
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
        currentPageIndex += 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            updateNavigationState()
            dbg("➡️ 앞으로가기: '\(record.title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
            return record
        }
        
        return nil
    }
    
    func navigateToIndex(_ index: Int) -> PageRecord? {
        guard index >= 0, index < pageHistory.count else { return nil }
        
        isHistoryNavigation = true
        currentPageIndex = index
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            updateNavigationState()
            dbg("🎯 인덱스 네비게이션: '\(record.title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
            return record
        }
        
        return nil
    }

    func clearHistory() {
        Self.globalHistory.removeAll()
        Self.saveGlobalHistory()
        pageHistory.removeAll()
        currentPageIndex = -1
        resetNavigationFlags()
        updateNavigationState()
        dbg("🧹 전체 히스토리 삭제")
    }

    // MARK: - ✅ 간소화된 네비게이션 상태 관리
    
    func resetNavigationFlags() {
        isHistoryNavigation = false
        historyNavigationStartTime = nil
        // 🔧 **중요 수정**: historyNavigationEndTime은 리셋하지 않음 (자연 만료되도록)
        // historyNavigationEndTime = nil  // ← 이 줄을 제거
        swipeDetectedTargetIndex = nil
        swipeConfirmationTimer?.invalidate()
        swipeConfirmationTimer = nil
        redirectionChain.removeAll()
        redirectionStartTime = nil
        
        // 🌐 SPA 상태 리셋
        isSPANavigation = false
        lastSPANavigationTime = nil
        
        // 🔒 로그인 플로우 리셋
        isInLoginFlow = false
        loginRedirectChain.removeAll()
        loginRedirectStartTime = nil
        
        // 🆕 새로고침 윈도 리셋
        endReloadWindow()
        
        // ✅ 홈 클릭 상태 리셋
        isHandlingHomeNavigation = false
        homeNavigationEndTime = nil
    }
    
    func isHistoryNavigationActive() -> Bool {
        // 히스토리 네비게이션 중인지 체크
        if isHistoryNavigation {
            if let startTime = historyNavigationStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 1.0 { // ✅ 2.0초 → 1.0초로 단축
                    isHistoryNavigation = false
                    historyNavigationStartTime = nil
                    return false
                }
                return true
            }
        }
        
        // 🔧 **새로 추가**: 히스토리 네비게이션 완료 후 차단 시간 체크
        if let endTime = historyNavigationEndTime {
            if Date() <= endTime {
                return true // 아직 차단 시간 내
            } else {
                historyNavigationEndTime = nil // 차단 시간 만료
            }
        }
        
        return false
    }
    
    // MARK: - 스와이프 제스처 처리
    
    func findPageIndex(for url: URL) -> Int? {
        // ✅ **수정**: 강화된 정규화로 페이지 찾기 (가장 최근 것 우선)
        let normalizedURL = normalizeURLForDuplicateCheck(url)
        let matchingIndices = pageHistory.enumerated().compactMap { index, record in
            normalizeURLForDuplicateCheck(record.url) == normalizedURL ? index : nil
        }
        return matchingIndices.last // 가장 최근에 추가된 페이지 반환
    }
    
    func handleSwipeGestureDetected(to url: URL) {
        guard !isHistoryNavigationActive() else {
            return
        }
        
        if let foundIndex = findPageIndex(for: url) {
            if foundIndex != currentPageIndex {
                swipeDetectedTargetIndex = foundIndex
                
                swipeConfirmationTimer?.invalidate()
                swipeConfirmationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    _ = self?.confirmSwipeGesture()
                }
            }
        }
    }
    
    private func confirmSwipeGesture() -> PageRecord? {
    // 🔧 홈 처리 구간에서는 사후 점프 방지 위해 확정을 무시
    guard !isInHomeNavigationHandling() else {
        swipeDetectedTargetIndex = nil
        dbg("👆 스와이프 확정 무시 (홈 처리 중)")
        return nil
    }

    guard let targetIndex = swipeDetectedTargetIndex else { return nil }
    
    if let record = navigateToIndex(targetIndex) {
        swipeDetectedTargetIndex = nil
        dbg("👆 스와이프 제스처 확정: 인덱스=\(currentPageIndex)/\(pageHistory.count)")
        return record
    }
    
    return nil
}


    // MARK: - WKNavigationDelegate (간소화)
    
   func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    stateModel?.handleLoadingStart()
    
    let startURL = webView.url
    
    // ✅ 자동 스와이프 감지 (홈 처리 중에는 금지 + 홈페이지 URL도 제외)
    if let startURL = startURL, 
       !isRestoringSession, 
       !isHistoryNavigationActive(),
       !isInHomeNavigationHandling(),            // 홈 처리 중에는 금지
       !isHomepageURL(startURL),                 // 🔧 홈페이지 URL은 스와이프 감지 제외
       stateModel?.currentURL != startURL {
        
        handleSwipeGestureDetected(to: startURL)
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
        
        // 🔒 로그인 리다이렉트 체인에도 추가
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
                // ✅ 정상적인 새 페이지 추가 (간소화된 체크)
                // 🔧 **핵심 수정**: 모든 히스토리 관련 상태를 체크
                let isHistoryRelated = isHistoryNavigation || 
                                      historyNavigationEndTime != nil ||
                                      (historyNavigationStartTime != nil)
                
                if !isHistoryRelated {
                    addNewPage(url: finalURL, title: title)
                    stateModel?.syncCurrentURL(finalURL)
                    dbg("🆕 새 페이지 기록: '\(title)' (총 \(pageHistory.count)개)")
                } else {
                    // 히스토리 네비게이션 관련 상태에서는 제목만 업데이트
                    updateCurrentPageTitle(title)
                    if stateModel?.currentURL != finalURL {
                        stateModel?.syncCurrentURL(finalURL)
                    }
                    dbg("🔄 히스토리 관련 상태 - 제목만 업데이트: '\(title)' [history:\(isHistoryNavigation), endTime:\(historyNavigationEndTime != nil), startTime:\(historyNavigationStartTime != nil)]")
                }
            }
            
            // 리다이렉트 체인 정리
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
        // 🔒 로그인 관련 항목은 전역 히스토리에서도 제외
        let filteredHistory = globalHistory.filter { !PageRecord.isLoginRelatedURL($0.url) }
        
        if let data = try? JSONEncoder().encode(filteredHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
            TabPersistenceManager.debugMessages.append("[\(ts())] ☁️ 전역 방문 기록 저장: \(filteredHistory.count)개 (원본 \(globalHistory.count)개)")
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
        let loginState = isInLoginFlow ? "🔒Login" : ""
        let reloadState = isInActiveReloadWindow() ? "🔄Reload" : ""
        let homeState = isInHomeNavigationHandling() ? "🏠Home" : ""
        
        // 🔧 **수정**: 히스토리 상태를 더 명확하게 표시
        let historyState: String = {
            if isHistoryNavigation {
                return "📖History"
            } else if let endTime = historyNavigationEndTime, Date() <= endTime {
                return "⏳Wait"
            } else {
                return ""
            }
        }()
        
        let historyCount = "[\(pageHistory.count)]"
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(historyCount)\(loginState)\(reloadState)\(homeState)\(historyState) \(msg)")
    }

    // MARK: - 메모리 정리
    deinit {
        swipeConfirmationTimer?.invalidate()
    }
}

// MARK: - 방문기록 페이지 뷰 (네비게이션 타입 표시 추가)
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

// MARK: - 세션 히스토리 행 뷰 (네비게이션 타입 표시 추가)
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
                    
                    // 🌐 사이트 타입 표시
                    if let siteType = record.siteType {
                        Text("[\(siteType)]")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    // 🆕 네비게이션 타입 표시
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
                    
                    // 🔒 로그인 관련 표시
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
