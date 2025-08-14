//
//  WebViewDataModel.swift
//  🌐 통합된 SPA 네비게이션 관리 + 로그인 리다이렉트 필터링
//  🎯 네이버 특화 로직을 범용으로 사용 (중복 제거)
//  🔒 로그인 관련 임시 페이지 히스토리 제외
//  ✅ 히스토리 개수 제한 해제 (무제한)
//

import Foundation
import SwiftUI
import WebKit

// MARK: - 페이지 식별자 (제목, 주소, 시간 포함)
struct PageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let url: URL
    var title: String
    let timestamp: Date
    var lastAccessed: Date
    
    // 🌐 사이트 메타데이터 추가
    var siteType: String?
    var isLoginRelated: Bool = false
    var isTemporary: Bool = false
    
    init(url: URL, title: String = "", siteType: String? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? (url.host ?? "제목 없음") : title
        self.timestamp = Date()
        self.lastAccessed = Date()
        self.siteType = siteType
        
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

// MARK: - WebViewDataModel (히스토리/세션 + WKNavigationDelegate 담당)
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
    
    // ✅ 강화된 히스토리 네비게이션 플래그
    private var isHistoryNavigation: Bool = false {
        didSet {
            if isHistoryNavigation {
                historyNavigationStartTime = Date()
            } else {
                historyNavigationStartTime = nil
            }
        }
    }
    
    private var historyNavigationStartTime: Date?
    
    // ✅ 스와이프 제스처 관련
    private var swipeDetectedTargetIndex: Int? = nil
    private var swipeConfirmationTimer: Timer?
    
    // 리다이렉트 감지용
    private var redirectionChain: [URL] = []
    private var redirectionStartTime: Date?
    
    // 🌐 **통합된 SPA 네비게이션 상태 관리** (네이버 로직을 범용으로)
    private var isSPANavigation: Bool = false
    private var lastSPANavigationTime: Date?
    
    // 🔒 로그인 리다이렉트 체인 추적
    private var loginRedirectChain: [URL] = []
    private var loginRedirectStartTime: Date?
    private var isInLoginFlow: Bool = false
    
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
    
    // MARK: - 🌐 **통합된 SPA 네비게이션 처리** (네이버 로직을 범용으로 사용)
    
    func handleSPANavigation(type: String, url: URL, title: String, timestamp: Double, siteType: String = "unknown") {
        // SPA 네비게이션 플래그 설정
        isSPANavigation = true
        lastSPANavigationTime = Date()
        
        dbg("🌐 SPA \(type) 감지: \(siteType) | \(url.absoluteString) | '\(title)'")
        
        // 기존 네이버 카페 로직을 모든 사이트에 적용
        switch type {
        case "push":
            handleSPAPushState(url: url, title: title, siteType: siteType)
            
        case "replace":
            handleSPAReplaceState(url: url, title: title, siteType: siteType)
            
        case "pop", "hash":
            handleSPAPopState(url: url, title: title, siteType: siteType)
            
        case "iframe_push":
            handleSPAIframePush(url: url, title: title, siteType: siteType)
            
        case "title":
            updateCurrentPageTitle(title)
            
        case "dom": // ✅ 새로 추가된 DOM 변경 감지 타입
            handleSPADOMChange(url: url, title: title, siteType: siteType)
            
        default:
            dbg("🌐 알 수 없는 SPA 네비게이션 타입: \(type)")
        }
        
        // 전역 히스토리에도 추가 (중복 및 로그인 관련 제외)
        if type != "title" && !PageRecord.isLoginRelatedURL(url) && !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
        
        // 일정 시간 후 플래그 해제
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.isSPANavigation = false
        }
    }
    
    private func handleSPAPushState(url: URL, title: String, siteType: String) {
        // 🎯 네이버 카페 로직을 모든 사이트에 적용: 복잡한 구조에 대한 정교한 중복 제거
        
        // 현재 페이지와 거의 같은 URL인지 확인 (파라미터만 다른 경우)
        if let currentRecord = currentPageRecord,
           areSimilarURLs(currentRecord.url, url) {
            // 비슷한 URL이면 교체 처리
            handleSPAReplaceState(url: url, title: title, siteType: siteType)
            return
        }
        
        // 현재 위치 이후의 forward 기록 제거
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            pageHistory.removeSubrange((currentPageIndex + 1)...)
        }
        
        let newRecord = PageRecord(url: url, title: title, siteType: siteType)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // ✅ 히스토리 크기 제한 제거 (무제한)
        // 기존: if pageHistory.count > 50 { ... } 제거
        
        updateNavigationState()
        dbg("🌐 SPA 새 페이지: \(siteType) '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))]")
        
        // StateModel URL 동기화
        stateModel?.syncCurrentURL(url)
    }
    
    private func handleSPAReplaceState(url: URL, title: String, siteType: String) {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else {
            handleSPAPushState(url: url, title: title, siteType: siteType)
            return
        }
        
        // 현재 페이지 기록 교체
        var updatedRecord = pageHistory[currentPageIndex]
        updatedRecord = PageRecord(url: url, title: title, siteType: siteType)
        pageHistory[currentPageIndex] = updatedRecord
        
        dbg("🌐 SPA 페이지 교체: \(siteType) '\(updatedRecord.title)' [ID: \(String(updatedRecord.id.uuidString.prefix(8)))]")
        
        // StateModel URL 동기화
        stateModel?.syncCurrentURL(url)
    }
    
    private func handleSPAPopState(url: URL, title: String, siteType: String) {
        // 히스토리 내에서 해당 URL 찾기
        if let foundIndex = pageHistory.firstIndex(where: { areSimilarURLs($0.url, url) }) {
            // 히스토리 내 이동
            currentPageIndex = foundIndex
            
            // 제목 및 메타데이터 업데이트
            var updatedRecord = pageHistory[currentPageIndex]
            updatedRecord.updateTitle(title)
            updatedRecord.updateAccess()
            updatedRecord.siteType = siteType
            pageHistory[currentPageIndex] = updatedRecord
            
            updateNavigationState()
            dbg("🌐 SPA 히스토리 이동: \(siteType) '\(updatedRecord.title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)]")
            
            // StateModel URL 동기화
            stateModel?.syncCurrentURL(url)
        } else {
            // 히스토리에 없으면 새로 추가
            handleSPAPushState(url: url, title: title, siteType: siteType)
        }
    }
    
    private func handleSPAIframePush(url: URL, title: String, siteType: String) {
        // iframe 내부 네비게이션은 보통 게시글 읽기 등이므로 일반 push와 동일하게 처리
        handleSPAPushState(url: url, title: title, siteType: "iframe_\(siteType)")
    }
    
    // ✅ 새로 추가: DOM 변경 감지 처리
    private func handleSPADOMChange(url: URL, title: String, siteType: String) {
        // DOM 변경으로 인한 URL 변화는 보통 SPA 앱에서 발생
        // popstate나 hashchange와 유사하게 처리
        handleSPAPopState(url: url, title: title, siteType: "dom_\(siteType)")
    }
    
    // 🌐 네이버 카페 URL 유사성 로직을 범용으로 사용
    private func areSimilarURLs(_ url1: URL, _ url2: URL) -> Bool {
        // 같은 호스트인지 확인
        guard url1.host == url2.host else { return false }
        
        // 경로 비교 (쿼리 파라미터 제외)
        let path1 = url1.path
        let path2 = url2.path
        
        // 경로가 완전히 같으면 유사한 것으로 판단
        if path1 == path2 {
            return true
        }
        
        // 네이버 카페용 로직을 모든 사이트에 적용
        let components1 = path1.split(separator: "/")
        let components2 = path2.split(separator: "/")
        
        if components1.count != components2.count {
            return false
        }
        
        // 첫 번째 컴포넌트가 같고 길이가 짧으면 유사한 페이지로 판단 (네이버 카페 로직)
        return components1.first == components2.first && 
               components1.count <= 2 && components2.count <= 2
    }
    
    // SPA 네비게이션 활성 상태 확인
    private func isSPANavigationActive() -> Bool {
        if isSPANavigation {
            return true
        }
        
        if let lastTime = lastSPANavigationTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            return elapsed < 1.5
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
    
    // MARK: - 새로운 페이지 기록 시스템 (강화된 필터링 + 연속 중복 방지)
    
    func addNewPage(url: URL, title: String = "") {
        // ✅ 히스토리 네비게이션 중인지 체크
        if isHistoryNavigationActive() {
            return
        }
        
        // 🌐 SPA 네비게이션 중인지 체크
        if isSPANavigationActive() {
            dbg("🌐 SPA 네비게이션 활성 중 - 일반 페이지 추가 건너뜀")
            return
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
        
        // ✅ 연속 중복 URL 체크 (완전히 같은 URL인 경우 제목만 업데이트)
        if !pageHistory.isEmpty,
           let lastRecord = pageHistory.last,
           lastRecord.url.absoluteString == url.absoluteString {
            // 완전히 같은 URL이면 제목만 업데이트하고 새 기록 추가하지 않음
            updateCurrentPageTitle(title)
            dbg("🔄 중복 URL 감지 - 제목만 업데이트: '\(title)' | \(url.absoluteString)")
            return
        }
        
        // 현재 위치 이후의 forward 기록 제거
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            pageHistory.removeSubrange((currentPageIndex + 1)...)
        }
        
        let newRecord = PageRecord(url: url, title: title)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // ✅ 히스토리 크기 제한 제거 (무제한)
        // 기존 제한 코드 제거:
        // if pageHistory.count > 50 {
        //     pageHistory.removeFirst()
        //     currentPageIndex -= 1
        // }
        
        updateNavigationState()
        dbg("📄 새 페이지 추가: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] (총 \(pageHistory.count)개)")
        
        // 전역 히스토리에도 추가 (로그인 관련 제외 + 중복 체크)
        if !PageRecord.isLoginRelatedURL(url) && !Self.globalHistory.contains(where: { $0.url.absoluteString == url.absoluteString }) {
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

    // MARK: - 세션 저장/복원
    
    func saveSession() -> WebViewSession? {
        guard !pageHistory.isEmpty, currentPageIndex >= 0 else {
            dbg("💾 세션 저장 실패: 히스토리 없음")
            return nil
        }
        
        // 🔒 로그인 관련 페이지는 세션에서 제외
        let filteredHistory = pageHistory.filter { !$0.isLoginRelated && !$0.isTemporary }
        
        if filteredHistory.isEmpty {
            dbg("💾 세션 저장 실패: 유효한 히스토리 없음 (로그인 페이지만 있음)")
            return nil
        }
        
        // 현재 인덱스를 필터링된 히스토리에 맞게 조정
        let adjustedIndex = min(max(0, currentPageIndex), filteredHistory.count - 1)
        
        let session = WebViewSession(pageRecords: filteredHistory, currentIndex: adjustedIndex)
        dbg("💾 세션 저장: \(filteredHistory.count)개 페이지 (원본 \(pageHistory.count)개), 현재 인덱스 \(adjustedIndex)")
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
            let siteInfo = record.siteType != nil ? "[\(record.siteType!)]" : ""
            dbg("🔄\(marker) [\(index)] \(record.title) \(siteInfo)| \(record.url.absoluteString)")
        }
        
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

    // MARK: - ✅ 강화된 네비게이션 상태 관리
    
    func resetNavigationFlags() {
        isHistoryNavigation = false
        historyNavigationStartTime = nil
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
    }
    
    func isHistoryNavigationActive() -> Bool {
        if isHistoryNavigation {
            return true
        }
        
        if let startTime = historyNavigationStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 2.0 {
                return true
            } else {
                isHistoryNavigation = false
                historyNavigationStartTime = nil
                return false
            }
        }
        
        return false
    }
    
    // MARK: - 스와이프 제스처 처리
    
    func findPageIndex(for url: URL) -> Int? {
        return pageHistory.firstIndex { $0.url == url }
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
        guard let targetIndex = swipeDetectedTargetIndex else { return nil }
        
        if let record = navigateToIndex(targetIndex) {
            swipeDetectedTargetIndex = nil
            dbg("👆 스와이프 제스처 확정: 인덱스=\(currentPageIndex)/\(pageHistory.count)")
            return record
        }
        
        return nil
    }
    
    // MARK: - 페이지 추가 여부 결정 로직 (강화된 필터링)
    
    private func shouldAddPageToHistory(finalURL: URL) -> Bool {
        if isHistoryNavigationActive() {
            return false
        }
        
        // 🌐 SPA 네비게이션 중이면 추가하지 않음
        if isSPANavigationActive() {
            dbg("🌐 SPA 네비게이션 활성 중 - 히스토리 추가 건너뜀")
            return false
        }
        
        // 🔒 로그인 관련 URL은 히스토리에 추가하지 않음
        if PageRecord.isLoginRelatedURL(finalURL) {
            dbg("🔒 로그인 관련 URL 히스토리 제외: \(finalURL.absoluteString)")
            return false
        }
        
        if pageHistory.isEmpty {
            return true
        }
        
        guard let lastRecord = pageHistory.last else {
            return true
        }
        
        if lastRecord.url != finalURL {
            // 리다이렉트 분석
            if redirectionChain.count > 1 {
                let firstURL = redirectionChain.first!
                let lastURL = redirectionChain.last!
                
                if lastRecord.url == firstURL && lastURL == finalURL {
                    if firstURL.host == finalURL.host {
                        return false // 같은 도메인 리다이렉트 - 기존 페이지 업데이트
                    } else {
                        return true // 다른 도메인 리다이렉트 - 새 페이지 추가
                    }
                }
            }
            
            return true // 다른 URL이므로 새 페이지 추가
        } else {
            return false // 같은 URL - 제목만 업데이트
        }
    }

    // MARK: - WKNavigationDelegate (히스토리/세션 로직만)
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stateModel?.handleLoadingStart()
        
        let startURL = webView.url
        
        // ✅ 자동 스와이프 감지
        if let startURL = startURL, 
           !isRestoringSession, 
           !isHistoryNavigationActive(),
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
                let shouldAddNewPage = shouldAddPageToHistory(finalURL: finalURL)
                
                if shouldAddNewPage {
                    addNewPage(url: finalURL, title: title)
                    stateModel?.syncCurrentURL(finalURL)
                    dbg("🆕 새 페이지 기록: '\(title)' (총 \(pageHistory.count)개)")
                } else {
                    updateCurrentPageTitle(title)
                    stateModel?.syncCurrentURL(finalURL)
                }
            }
            
            // 리다이렉트 체인 정리
            redirectionChain.removeAll()
            redirectionStartTime = nil
        }
        
        if !wasRestoringSession {
            stateModel?.triggerNavigationFinished()
        }
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

    // MARK: - 전역 히스토리 관리 (✅ 무제한)
    
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
        let historyCount = "[\(pageHistory.count)]"
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(historyCount)\(loginState) \(msg)")
    }

    // MARK: - 메모리 정리
    deinit {
        swipeConfirmationTimer?.invalidate()
    }
}

// MARK: - 방문기록 페이지 뷰 (기존 유지)
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
                    Section("현재 세션 (\(sessionHistory.count)개)") { // ✅ 개수 표시 추가
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
                
                Section("전체 기록 (\(filteredGlobalHistory.count)개)") { // ✅ 개수 표시 추가
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

// MARK: - 세션 히스토리 행 뷰 (사이트 타입 정보 추가)
struct SessionHistoryRowView: View {
    let record: PageRecord
    let isCurrent: Bool
    
    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "arrow.right.circle.fill" : "circle")
                .foregroundColor(isCurrent ? .blue : .gray)
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
