//
//  WebViewStateModel.swift
//  페이지 고유번호 기반 히스토리 시스템 (앱 재실행 후 forward 히스토리 복원 문제 해결)
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
    private var isNavigatingFromWebView: Bool = false {
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

    // MARK: - 새로운 페이지 기록 시스템
    
    private func addNewPage(url: URL, title: String = "") {
        dbg("📋 === addNewPage 호출 상세 분석 ===")
        dbg("📋 추가하려는 URL: \(url.absoluteString)")
        dbg("📋 추가하려는 제목: \(title)")
        dbg("📋 현재 히스토리 상태:")
        dbg("📋   - 총 페이지 수: \(pageHistory.count)")
        dbg("📋   - 현재 인덱스: \(currentPageIndex)")
        
        if !pageHistory.isEmpty {
            for (index, record) in pageHistory.enumerated() {
                let marker = index == currentPageIndex ? "👉" : "  "
                dbg("📋\(marker) [\(index)] \(record.title) | \(record.url.absoluteString)")
            }
        }
        
        dbg("📋 현재 플래그 상태:")
        dbg("📋   - isHistoryNavigation: \(isHistoryNavigation)")
        dbg("📋   - isHistoryNavigationActive(): \(isHistoryNavigationActive())")
        dbg("📋   - isRestoringSession: \(isRestoringSession)")
        dbg("📋   - isNavigatingFromWebView: \(isNavigatingFromWebView)")
        
        if let startTime = historyNavigationStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            dbg("📋   - 히스토리 네비게이션 시작 후 경과 시간: \(elapsed)초")
        }
        
        // ✅ 강화된 조건 체크
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
    
    // 🔧 완전히 커스텀 히스토리 기반으로 상태 업데이트
    private func updateNavigationState() {
        let oldBack = canGoBack
        let oldForward = canGoForward
        
        // WebView 네이티브 히스토리 무시하고 커스텀 히스토리만 사용
        canGoBack = currentPageIndex > 0
        canGoForward = currentPageIndex < pageHistory.count - 1
        
        if oldBack != canGoBack || oldForward != canGoForward {
            dbg("🔄 네비게이션 상태 업데이트 (커스텀): back=\(canGoBack), forward=\(canGoForward), 인덱스=\(currentPageIndex)/\(pageHistory.count)")
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

    // ✅ 🔧 복원 과정 개선 (didFinish에서 복원 완료 처리)
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
        
        // 복원 즉시 상태 업데이트
        updateNavigationState()
        dbg("🔧 복원 후 즉시 상태: back=\(canGoBack), forward=\(canGoForward), 인덱스=\(currentPageIndex)/\(pageHistory.count)")
        
        if let webView = webView, let url = currentURL {
            webView.load(URLRequest(url: url))
            dbg("🌐 복원 시 웹뷰 로드: \(url.absoluteString)")
        }
        
        // ✅ 타이머 제거 - didFinish에서 복원 완료 처리
        dbg("🔄 복원 타이머 없이 didFinish 대기")
    }

    // MARK: - 네비게이션 메서드 (WebView 네이티브 메서드 사용 안함)
    
    func goBack() {
        guard canGoBack, currentPageIndex > 0 else { 
            dbg("⬅️ 뒤로가기 불가: canGoBack=\(canGoBack), index=\(currentPageIndex)")
            return 
        }
        
        dbg("⬅️ === 뒤로가기 시작 ===")
        dbg("⬅️ 현재 인덱스: \(currentPageIndex) → \(currentPageIndex - 1)")
        
        currentPageIndex -= 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            // ✅ 🔧 히스토리 네비게이션 플래그 설정 강화
            dbg("⬅️ 히스토리 네비게이션 플래그 설정")
            isHistoryNavigation = true
            isNavigatingFromWebView = true
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
        
        currentPageIndex += 1
        
        if let record = currentPageRecord {
            var mutableRecord = record
            mutableRecord.updateAccess()
            pageHistory[currentPageIndex] = mutableRecord
            
            // ✅ 🔧 히스토리 네비게이션 플래그 설정 강화
            dbg("➡️ 히스토리 네비게이션 플래그 설정")
            isHistoryNavigation = true
            isNavigatingFromWebView = true
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
    
    // MARK: - 기존 호환성 메서드
    
    func loadURLIfReady() {
        if let url = currentURL, let webView = webView {
            webView.load(URLRequest(url: url))
            dbg("URL 로드 시도: \(url.absoluteString)")
        } else {
            dbg("URL 로드 실패: WebView 또는 URL 없음")
        }
    }

    // MARK: - WKNavigationDelegate (복원 중 상태 업데이트 방지)
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let startURL = webView.url
        dbg("🌐 로드 시작 → \(startURL?.absoluteString ?? "(pending)")")
        
        // ✅ 스와이프 제스처 뒤로가기/앞으로가기 감지 개선
        if let startURL = startURL, 
           !isRestoringSession, 
           !isHistoryNavigationActive(),
           currentURL != startURL {
            
            dbg("👆 === 스와이프 제스처 감지 분석 ===")
            dbg("👆 시작 URL: \(startURL.absoluteString)")
            dbg("👆 현재 URL: \(currentURL?.absoluteString ?? "nil")")
            
            // 현재 커스텀 히스토리에서 URL 찾기
            if let foundIndex = pageHistory.firstIndex(where: { $0.url == startURL }) {
                let currentIndex = currentPageIndex
                
                dbg("👆 히스토리에서 발견: 인덱스 \(foundIndex), 현재 인덱스: \(currentIndex)")
                
                if foundIndex < currentIndex {
                    // 스와이프 뒤로가기 감지
                    dbg("👆 ⬅️ 스와이프 뒤로가기 감지: 인덱스 \(currentIndex) → \(foundIndex)")
                    currentPageIndex = foundIndex
                    isHistoryNavigation = true
                    
                } else if foundIndex > currentIndex {
                    // 스와이프 앞으로가기 감지
                    dbg("👆 ➡️ 스와이프 앞으로가기 감지: 인덱스 \(currentIndex) → \(foundIndex)")
                    currentPageIndex = foundIndex
                    isHistoryNavigation = true
                    
                } else {
                    dbg("👆 같은 인덱스 - 일반 네비게이션으로 처리")
                }
                
                if isHistoryNavigation {
                    // 히스토리 기록 접근 시간 업데이트
                    var mutableRecord = pageHistory[foundIndex]
                    mutableRecord.updateAccess()
                    pageHistory[foundIndex] = mutableRecord
                    
                    updateNavigationState()
                    dbg("👆 스와이프 제스처로 히스토리 인덱스 동기화: \(foundIndex)")
                }
            } else {
                dbg("👆 히스토리에 없는 URL - 일반 네비게이션으로 처리")
            }
            
            dbg("👆 === 스와이프 제스처 감지 분석 끝 ===")
        }
        
        // 🔧 리다이렉트 체인 감지 시작
        if let url = startURL {
            let now = Date()
            
            // 리다이렉트 체인 초기화 또는 연장
            if redirectionChain.isEmpty || redirectionStartTime == nil || 
               now.timeIntervalSince(redirectionStartTime!) > 3.0 {
                // 새로운 네비게이션 시작
                redirectionChain = [url]
                redirectionStartTime = now
                dbg("🔗 새 네비게이션 체인 시작: \(url.absoluteString)")
            } else {
                // 기존 리다이렉트 체인에 추가
                redirectionChain.append(url)
                dbg("🔗 리다이렉트 체인 연장: \(url.absoluteString) (총 \(redirectionChain.count)개)")
            }
        }
        
        // 웹뷰 내부 네비게이션 감지
        if let startURL = startURL, currentURL != startURL && !isRestoringSession {
            dbg("🔄 웹뷰 내부 네비게이션 감지: \(startURL.absoluteString)")
        }
    }

    // 🔧 복원 중일 때 상태 업데이트 방지
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView
        
        let title = webView.title ?? webView.url?.host ?? "제목 없음"
        
        // ✅ didFinish 시작 시점의 복원 상태 기억
        let wasRestoringSession = isRestoringSession
        
        if let finalURL = webView.url {
            dbg("🌐 === didFinish 상세 분석 ===")
            dbg("🌐 didFinish URL: \(finalURL.absoluteString)")
            dbg("🌐 didFinish 제목: '\(title)'")
            dbg("📊 현재 상태 - currentURL: \(currentURL?.absoluteString ?? "nil"), 히스토리: \(pageHistory.count)개, 인덱스: \(currentPageIndex)")
            dbg("🏷️ 플래그 상태:")
            dbg("🏷️   - 복원중: \(isRestoringSession)")
            dbg("🏷️   - 히스토리네비: \(isHistoryNavigation)")
            dbg("🏷️   - 히스토리네비활성: \(isHistoryNavigationActive())")
            dbg("🏷️   - 웹뷰네비: \(isNavigatingFromWebView)")
            
            if let startTime = historyNavigationStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                dbg("🏷️   - 히스토리 네비게이션 경과시간: \(elapsed)초")
            }
            
            // ✅ 복원 상태 우선 처리 (절대 새 페이지 추가하지 않음)
            if isRestoringSession {
                dbg("🔄 === 복원 중 처리 ===")
                updateCurrentPageTitle(title)
                
                // ✅ 복원 완료 처리를 didFinish에서 수행
                isRestoringSession = false
                updateNavigationState()
                dbg("🔄 복원 완료: '\(title)' - isRestoringSession = false")
                dbg("🔄 최종 상태: back=\(canGoBack), forward=\(canGoForward), 인덱스=\(currentPageIndex)/\(pageHistory.count)")
                dbg("🔄 === 복원 중 처리 끝 ===")
                dbg("🔄 === 세션 복원 끝 ===")
                
            } else if isHistoryNavigationActive() {
                dbg("🔄 === 히스토리 네비게이션 처리 (버튼 또는 스와이프) ===")
                updateCurrentPageTitle(title)
                
                // ✅ 스와이프 제스처든 버튼이든 currentURL 동기화
                if currentURL != finalURL {
                    dbg("🔄 스와이프 제스처로 인한 주소창 동기화: \(currentURL?.absoluteString ?? "nil") → \(finalURL.absoluteString)")
                    isNavigatingFromWebView = true
                    currentURL = finalURL
                    isNavigatingFromWebView = false
                } else {
                    dbg("🔄 주소창 이미 동기화됨")
                }
                
                dbg("🔄 히스토리 네비게이션 완료: '\(title)' [인덱스: \(currentPageIndex)/\(pageHistory.count)] - 새 페이지 추가 안함")
                
                // ✅ 히스토리 네비게이션 플래그 지연 해제 (시간 기반으로 더 안전하게)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.isHistoryNavigation = false
                    self.isNavigatingFromWebView = false
                    self.dbg("🏁 히스토리 네비게이션 플래그 지연 해제 완료 (스와이프/버튼)")
                }
                
                dbg("🔄 === 히스토리 네비게이션 처리 끝 ===")
                dbg("🌐 === didFinish 분석 끝 (히스토리) ===")
                return // ❗️이거 반드시 필요 (else 블록 실행 방지)
                
            } else {
                dbg("🆕 === 일반 네비게이션 처리 ===")
                // 일반 네비게이션: 페이지 추가 여부 판단
                let shouldAddNewPage = shouldAddPageToHistory(finalURL: finalURL)
                
                dbg("🤔 새 페이지 추가 여부: \(shouldAddNewPage)")
                
                if shouldAddNewPage {
                    isNavigatingFromWebView = true
                    
                    addNewPage(url: finalURL, title: title)
                    dbg("🆕 새 페이지 기록: '\(title)' (\(finalURL.absoluteString))")
                    
                    // 전역 방문 기록 추가
                    WebViewStateModel.globalHistory.append(.init(url: finalURL, title: title, date: Date()))
                    WebViewStateModel.saveGlobalHistory()
                    
                    // currentURL 동기화 (didSet 호출 방지)
                    currentURL = finalURL
                    isNavigatingFromWebView = false
                } else {
                    // 새 페이지 추가는 하지 않지만 제목과 currentURL은 업데이트
                    updateCurrentPageTitle(title)
                    currentURL = finalURL
                    dbg("📝 기존 페이지 업데이트: '\(title)' (\(finalURL.absoluteString))")
                }
                dbg("🆕 === 일반 네비게이션 처리 끝 ===")
            }
            
            // 리다이렉트 체인 정리
            redirectionChain.removeAll()
            redirectionStartTime = nil
            
            dbg("🌐 === didFinish 분석 끝 ===")
        }
        
        // ✅ 복원 완료 후에만 상태 업데이트 (처음에 복원 중이었다면 위에서 이미 처리됨)
        if !wasRestoringSession {
            updateNavigationState()
        } else {
            dbg("🔧 원래 복원 중이었으므로 상태 업데이트 생략 (위에서 처리됨)")
        }
        
        dbg("🌐 로드 완료 → '\(title)' | back=\(canGoBack) forward=\(canGoForward) | 히스토리: \(pageHistory.count)개")
        
        // ✅ 복원이 아닐 때만 navigationDidFinish 호출
        if !wasRestoringSession {  // 원래 복원 상태를 기억해야 함
            navigationDidFinish.send(())
        }
    }
    
    // ✅ 🔧 리다이렉트를 고려한 페이지 추가 판단 로직 (히스토리 네비게이션 체크 강화)
    private func shouldAddPageToHistory(finalURL: URL) -> Bool {
        dbg("🤔 === shouldAddPageToHistory 분석 ===")
        dbg("🤔 검사할 URL: \(finalURL.absoluteString)")
        
        // ✅ 강화된 히스토리 네비게이션 체크
        if isHistoryNavigationActive() {
            dbg("🚫 히스토리 네비게이션 활성 중 - 새 페이지 추가 방지")
            dbg("🤔 === shouldAddPageToHistory 분석 끝 (false) ===")
            return false
        }
        
        // 히스토리가 비어있으면 무조건 추가
        if pageHistory.isEmpty {
            dbg("✅ 첫 페이지이므로 추가")
            dbg("🤔 === shouldAddPageToHistory 분석 끝 (true) ===")
            return true
        }
        
        // 마지막 페이지와 URL이 완전히 다르면 추가
        guard let lastRecord = pageHistory.last else {
            dbg("✅ 마지막 기록이 없으므로 추가")
            dbg("🤔 === shouldAddPageToHistory 분석 끝 (true) ===")
            return true
        }
        
        dbg("🤔 마지막 기록: \(lastRecord.url.absoluteString)")
        dbg("🤔 URL 비교: \(lastRecord.url == finalURL)")
        
        if lastRecord.url != finalURL {
            // 리다이렉트 체인 분석
            if redirectionChain.count > 1 {
                dbg("🤔 리다이렉트 체인 감지: \(redirectionChain.count)개")
                // 리다이렉트가 발생한 경우
                let firstURL = redirectionChain.first!
                let lastURL = redirectionChain.last!
                
                dbg("🤔 리다이렉트 체인: \(firstURL.absoluteString) → \(lastURL.absoluteString)")
                
                // 시작 URL과 마지막 기록이 같고, 최종 URL이 다르면 리다이렉트로 판단
                if lastRecord.url == firstURL && lastURL == finalURL {
                    dbg("🔄 리다이렉트 감지: \(firstURL.absoluteString) → \(finalURL.absoluteString)")
                    
                    // 도메인이 같은 리다이렉트면 기존 페이지 업데이트만
                    if firstURL.host == finalURL.host {
                        dbg("🏠 같은 도메인 리다이렉트 - 기존 페이지 업데이트")
                        dbg("🤔 === shouldAddPageToHistory 분석 끝 (false) ===")
                        return false
                    } else {
                        dbg("🌍 다른 도메인 리다이렉트 - 새 페이지 추가")
                        dbg("🤔 === shouldAddPageToHistory 분석 끝 (true) ===")
                        return true
                    }
                }
            }
            
            dbg("✅ 다른 URL이므로 새 페이지 추가: \(lastRecord.url.absoluteString) → \(finalURL.absoluteString)")
            dbg("🤔 === shouldAddPageToHistory 분석 끝 (true) ===")
            return true
        } else {
            dbg("📝 같은 URL - 제목만 업데이트")
            dbg("🤔 === shouldAddPageToHistory 분석 끝 (false) ===")
            return false
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dbg("❌ 로드 실패(Provisional): \(error.localizedDescription)")
        
        // 리다이렉트 체인 정리
        redirectionChain.removeAll()
        redirectionStartTime = nil
        
        // ✅ 플래그 정리
        isRestoringSession = false
        isHistoryNavigation = false
        historyNavigationStartTime = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dbg("❌ 로드 실패(Navigation): \(error.localizedDescription)")
        
        // 리다이렉트 체인 정리
        redirectionChain.removeAll()
        redirectionStartTime = nil
        
        // ✅ 플래그 정리
        isRestoringSession = false
        isHistoryNavigation = false
        historyNavigationStartTime = nil
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

    // ✅ 디버그를 위한 히스토리 상태 출력 메서드
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

        // 현재 세션 히스토리
        private var sessionHistory: [PageRecord] {
            return state.pageHistory.reversed()
        }
        
        // 전역 히스토리 (검색 필터링)
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
                // 현재 세션 히스토리
                if !sessionHistory.isEmpty {
                    Section("현재 세션") {
                        ForEach(sessionHistory) { record in
                            SessionHistoryRowView(
                                record: record, 
                                isCurrent: record.id == state.currentPageRecord?.id
                            )
                            .onTapGesture {
                                // 특정 페이지로 직접 이동
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
                
                // 전역 히스토리
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
                            // 전역 히스토리에서 페이지 로드
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
            // 현재 페이지 표시
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
