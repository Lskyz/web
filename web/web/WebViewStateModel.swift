//
//  WebViewStateModel.swift
//  페이지 고유번호 기반 히스토리 시스템 (앱 재실행 후 forward 히스토리 복원 문제 해결)
//  + URL 변경 감지 강화 (Fragment, SPA 라우팅, Query Parameter 변경 모두 감지)
//  + Forward 히스토리 보존 로직 (기존 앞 페이지가 삭제되지 않도록 안전 장치)
//  + 🛡️ 즉시 위험 수정: Race Condition, 인덱스 안전성, 무한 재귀 방지
//

import Foundation
import Combine
import SwiftUI
import WebKit

// MARK: - 페이지 식별자 (제목, 주소, 시간 포함)
struct PageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL  // ✨ var로 변경 (URL 업데이트 가능하도록)
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
    
    mutating func updateURL(_ newURL: URL) {
        url = newURL
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

// MARK: - ✨ 페이지 변경 타입 정의 (Forward 히스토리 보존 로직)
enum PageChangeType {
    case newPage           // 완전히 새로운 페이지 (forward 기록 삭제)
    case pageUpdate        // 기존 페이지 업데이트 (forward 기록 보존)
    case inPageNavigation  // 같은 페이지 내 네비게이션 (forward 기록 보존)
    
    var description: String {
        switch self {
        case .newPage: return "새 페이지"
        case .pageUpdate: return "페이지 업데이트"
        case .inPageNavigation: return "페이지 내 네비게이션"
        }
    }
}

// MARK: - 🛡️ 에러 타입 정의 (안전성 강화)
enum HistoryError: LocalizedError {
    case tooManyPages
    case urlTooLong
    case invalidIndex
    case stateInconsistency
    case raceConditionDetected
    
    var errorDescription: String? {
        switch self {
        case .tooManyPages: return "히스토리 페이지 수 한계 초과"
        case .urlTooLong: return "URL 길이 한계 초과"
        case .invalidIndex: return "잘못된 히스토리 인덱스"
        case .stateInconsistency: return "히스토리 상태 불일치"
        case .raceConditionDetected: return "동시 접근 감지"
        }
    }
}

// MARK: - URL Fragment 비교를 위한 확장 (✨ 새로 추가)
extension URL {
    /// Fragment를 제외한 URL 문자열 반환 (Fragment 변경 감지용)
    var absoluteStringWithoutFragment: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }
        components.fragment = nil
        return components.url?.absoluteString ?? absoluteString
    }
    
    /// URL의 base path (query parameter와 fragment 제외)
    var basePath: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? absoluteString
    }
}

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - WebViewStateModel (✨ URL 변경 감지 강화 + Forward 히스토리 보존 + 🛡️ 안전성 강화)
final class WebViewStateModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {

    var tabID: UUID?
    
    // 페이지 기록 기반 히스토리 (기존 복잡한 시스템 교체)
    @Published private var pageHistory: [PageRecord] = []
    @Published private var currentPageIndex: Int = -1
    
    let navigationDidFinish = PassthroughSubject<Void, Never>()

    // 🛡️ 무한 재귀 방지를 위한 플래그
    private var isUpdatingCurrentURL = false
    
    @Published var currentURL: URL? {
        didSet {
            // 🛡️ 1. 무한 재귀 방지
            guard !isUpdatingCurrentURL else {
                dbg("🔄 currentURL 재귀 방지: 업데이트 중단")
                return
            }
            
            guard let url = currentURL else { return }

            isUpdatingCurrentURL = true
            defer { isUpdatingCurrentURL = false }

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
                           !isHistoryNavigationActive() &&  // ✅ 강화된 히스토리 네비게이션 체크
                           !isJavaScriptNavigation          // ✨ 새로 추가: JavaScript 네비게이션 체크
            
            dbg("🤔 webView.load 여부 판단:")
            dbg("🤔   url != oldValue: \(url != oldValue)")
            dbg("🤔   !isRestoringSession: \(!isRestoringSession)")
            dbg("🤔   !isNavigatingFromWebView: \(!isNavigatingFromWebView)")
            dbg("🤔   !isHistoryNavigationActive(): \(!isHistoryNavigationActive())")
            dbg("🤔   !isJavaScriptNavigation: \(!isJavaScriptNavigation)")
            dbg("🤔   shouldLoad: \(shouldLoad)")
            
            if shouldLoad {
                if let webView = webView {
                    webView.load(URLRequest(url: url))
                    dbg("🌐 주소창에서 웹뷰 로드: \(url.absoluteString)")
                } else {
                    dbg("⚠️ 웹뷰가 없어서 로드 불가")
                }
            } else {
                var skipReason = ""
                if url == oldValue { skipReason += "[중복URL] " }
                if isRestoringSession { skipReason += "[복원중] " }
                if isNavigatingFromWebView { skipReason += "[웹뷰네비] " }
                if isHistoryNavigationActive() { skipReason += "[히스토리네비] " }
                if isJavaScriptNavigation { skipReason += "[JavaScript네비] " }
                
                dbg("⛔️ webView.load 생략됨 - \(skipReason)")
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
    
    // ✨ 새로 추가: JavaScript에서 발생한 네비게이션인지 구분
    private var isJavaScriptNavigation: Bool = false {
        didSet {
            if oldValue != isJavaScriptNavigation {
                dbg("🏁 isJavaScriptNavigation: \(oldValue) → \(isJavaScriptNavigation)")
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
    
    // ✨ URL 변경 감지 관련 속성
    private var urlDetectionSetup: Bool = false
    private var lastDetectedURL: URL?
    
    // 🛡️ 2. Race Condition 방지를 위한 직렬 큐
    private let historyQueue = DispatchQueue(label: "com.webview.history", qos: .userInitiated)
    
    // 🛡️ 히스토리 수정 작업 중인지 추적
    private var isHistoryModificationInProgress = false
    
    // 🔧 WebView 연결 시 네이티브 히스토리 상태 무시 + URL 변경 감지 설정
    weak var webView: WKWebView? {
        didSet {
            // 🛡️ 이전 webView 정리 (메모리 누수 방지)
            if let oldWebView = oldValue {
                oldWebView.configuration.userContentController.removeScriptMessageHandler(forName: "urlChanged")
                dbg("🧹 이전 WebView ScriptMessageHandler 정리")
            }
            
            if let webView = webView {
                dbg("🔗 webView 연결됨")
                setupURLChangeDetection(webView: webView)  // ✨ 새로 추가: URL 변경 감지 설정
                
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

    // 🛡️ 메모리 누수 방지
    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "urlChanged")
        dbg("🧹 WebViewStateModel 정리 완료")
    }

    func clearHistory() {
        safeHistoryModification { [self] in
            WebViewStateModel.globalHistory = []
            WebViewStateModel.saveGlobalHistory()
            pageHistory.removeAll()
            currentPageIndex = -1
            updateNavigationState()
            dbg("🧹 전체 히스토리 삭제")
        }
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

    // MARK: - 🛡️ Race Condition 방지 메서드들 (새로 추가)
    
    /// 모든 히스토리 수정 작업을 안전하게 직렬화하는 메서드
    private func safeHistoryModification(_ block: @escaping () -> Void) {
        historyQueue.async {
            // 🛡️ 동시 수정 방지
            if self.isHistoryModificationInProgress {
                self.dbg("🚨 Race Condition 감지: 이미 수정 중인 작업 있음")
                return
            }
            
            self.isHistoryModificationInProgress = true
            
            DispatchQueue.main.async {
                defer { self.isHistoryModificationInProgress = false }
                
                // 🛡️ 현재 상태를 다시 한번 검증
                guard self.currentPageIndex >= -1 && 
                      (self.pageHistory.isEmpty || self.pageHistory.indices.contains(self.currentPageIndex)) else {
                    self.dbg("🚨 히스토리 수정 중단: 잘못된 상태 - 인덱스=\(self.currentPageIndex), 총개수=\(self.pageHistory.count)")
                    return
                }
                
                block()
            }
        }
    }
    
    /// 🛡️ 3. 인덱스 안전성 검증
    private func isValidIndex(_ index: Int) -> Bool {
        return index >= 0 && index < pageHistory.count
    }
    
    /// 🛡️ 안전한 인덱스 범위로 조정
    private func safeIndex(_ index: Int) -> Int {
        return max(0, min(index, pageHistory.count - 1))
    }
    
    /// 🛡️ 안전한 페이지 삽입
    private func safeInsertPage(_ record: PageRecord, at index: Int) -> Bool {
        guard index >= 0 && index <= pageHistory.count else {
            dbg("🚨 안전하지 않은 삽입 시도: 인덱스=\(index), 범위=0...\(pageHistory.count)")
            return false
        }
        
        pageHistory.insert(record, at: index)
        
        // 🛡️ 인덱스 무결성 유지
        if currentPageIndex >= index {
            currentPageIndex += 1
        }
        
        // 🛡️ 다시 한번 검증
        guard currentPageIndex >= 0 && currentPageIndex < pageHistory.count else {
            dbg("🚨 삽입 후 인덱스 무결성 실패")
            currentPageIndex = safeIndex(currentPageIndex)
            return false
        }
        
        return true
    }

    // MARK: - ✨ URL 변경 감지 JavaScript 설정 (새로 추가)
    
    private func setupURLChangeDetection(webView: WKWebView) {
        guard !urlDetectionSetup else {
            dbg("🔧 URL 변경 감지 이미 설정됨")
            return
        }
        
        let script = """
        (function() {
            let lastURL = location.href;
            let lastTitle = document.title;
            
            function notifyURLChange() {
                const currentURL = location.href;
                const currentTitle = document.title;
                
                if (currentURL !== lastURL || currentTitle !== lastTitle) {
                    console.log('🔍 JavaScript URL 변경 감지:', currentURL);
                    
                    window.webkit.messageHandlers.urlChanged.postMessage({
                        url: currentURL,
                        title: currentTitle,
                        previousURL: lastURL,
                        changeType: currentURL !== lastURL ? 'url' : 'title'
                    });
                    
                    lastURL = currentURL;
                    lastTitle = currentTitle;
                }
            }
            
            // pushState/replaceState 감지 (SPA 라우팅)
            const originalPushState = history.pushState;
            const originalReplaceState = history.replaceState;
            
            history.pushState = function() {
                originalPushState.apply(history, arguments);
                setTimeout(notifyURLChange, 100);  // 약간의 지연으로 DOM 업데이트 기다림
            };
            
            history.replaceState = function() {
                originalReplaceState.apply(history, arguments);
                setTimeout(notifyURLChange, 100);
            };
            
            // popstate 이벤트 감지 (브라우저 뒤로/앞으로 버튼)
            window.addEventListener('popstate', function(event) {
                console.log('📍 popstate 이벤트 감지');
                setTimeout(notifyURLChange, 100);
            });
            
            // hashchange 이벤트 감지 (Fragment 변경)
            window.addEventListener('hashchange', function(event) {
                console.log('🔗 hashchange 이벤트 감지:', location.hash);
                setTimeout(notifyURLChange, 50);
            });
            
            // 제목 변경 감지 (MutationObserver)
            const titleObserver = new MutationObserver(function(mutations) {
                mutations.forEach(function(mutation) {
                    if (mutation.type === 'childList' && mutation.target.nodeName === 'TITLE') {
                        setTimeout(notifyURLChange, 50);
                    }
                });
            });
            
            // <title> 태그 변경 감지
            const titleElement = document.querySelector('title');
            if (titleElement) {
                titleObserver.observe(titleElement, { childList: true });
            }
            
            // DOM 변경으로 인한 제목 변경도 감지
            const headObserver = new MutationObserver(function(mutations) {
                mutations.forEach(function(mutation) {
                    if (mutation.addedNodes) {
                        mutation.addedNodes.forEach(function(node) {
                            if (node.nodeName === 'TITLE') {
                                titleObserver.observe(node, { childList: true });
                                setTimeout(notifyURLChange, 50);
                            }
                        });
                    }
                });
            });
            
            const head = document.head;
            if (head) {
                headObserver.observe(head, { childList: true });
            }
            
            // 주기적 체크 (fallback) - 조금 더 자주 체크
            setInterval(notifyURLChange, 2000);
            
            console.log('🚀 URL 변경 감지 스크립트 초기화 완료');
        })();
        """
        
        let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(userScript)
        webView.configuration.userContentController.add(self, name: "urlChanged")
        
        urlDetectionSetup = true
        dbg("🔧 URL 변경 감지 JavaScript 설정 완료")
    }
    
    // MARK: - ✨ WKScriptMessageHandler 구현 (새로 추가)
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "urlChanged",
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else {
            dbg("❌ JavaScript 메시지 파싱 실패")
            return
        }
        
        let title = body["title"] as? String ?? ""
        let previousURLString = body["previousURL"] as? String
        let changeType = body["changeType"] as? String ?? "unknown"
        
        dbg("📱 JavaScript URL 변경 감지:")
        dbg("📱   URL: \(url.absoluteString)")
        dbg("📱   제목: '\(title)'")
        dbg("📱   이전URL: \(previousURLString ?? "nil")")
        dbg("📱   변경타입: \(changeType)")
        
        // 중복 감지 방지
        if let lastURL = lastDetectedURL, lastURL == url {
            dbg("📱 중복 URL 변경 감지 - 무시")
            return
        }
        
        lastDetectedURL = url
        
        // 🛡️ 메인 스레드에서 안전하게 처리
        DispatchQueue.main.async {
            self.handleJavaScriptURLChange(url: url, title: title, changeType: changeType)
        }
    }
    
    private func handleJavaScriptURLChange(url: URL, title: String, changeType: String) {
        dbg("🔄 === JavaScript URL 변경 처리 시작 ===")
        dbg("🔄 처리할 URL: \(url.absoluteString)")
        dbg("🔄 변경 타입: \(changeType)")
        
        // 현재 URL과 같으면 제목만 업데이트
        if currentURL == url {
            if changeType == "title" && !title.isEmpty {
                safeHistoryModification { [self] in
                    updateCurrentPageTitle(title)
                    dbg("📝 제목만 업데이트: '\(title)'")
                }
            }
            dbg("🔄 === JavaScript URL 변경 처리 끝 (제목만) ===")
            return
        }
        
        // JavaScript 네비게이션 플래그 설정
        isJavaScriptNavigation = true
        
        // 🛡️ 안전한 변경 타입 분석 및 처리
        safeHistoryModification { [self] in
            let pageChangeType = analyzePageChange(finalURL: url)
            let finalTitle = title.isEmpty ? (url.host ?? "제목 없음") : title
            
            handlePageChange(url: url, title: finalTitle, changeType: pageChangeType)
            
            // currentURL 동기화
            currentURL = url
            
            // 전역 히스토리 추가 (새 페이지인 경우만)
            if pageChangeType == .newPage || pageChangeType == .inPageNavigation {
                WebViewStateModel.globalHistory.append(.init(url: url, title: finalTitle, date: Date()))
                WebViewStateModel.saveGlobalHistory()
            }
        }
        
        // 플래그 지연 해제
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.isJavaScriptNavigation = false
            self.dbg("🏁 JavaScript 네비게이션 플래그 해제")
        }
        
        dbg("🔄 === JavaScript URL 변경 처리 끝 ===")
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

    // MARK: - ✨ Forward 히스토리 보존 로직 (새로 추가)
    
    // ✨ 페이지 변경 타입 분석
    private func analyzePageChange(finalURL: URL) -> PageChangeType {
        dbg("🔍 === 페이지 변경 타입 분석 시작 ===")
        dbg("🔍 분석할 URL: \(finalURL.absoluteString)")
        
        // 강화된 히스토리 네비게이션 체크
        if isHistoryNavigationActive() {
            dbg("🔍 히스토리 네비게이션 활성 중 → pageUpdate")
            return .pageUpdate
        }
        
        // JavaScript 네비게이션 중이면 이미 처리됨
        if isJavaScriptNavigation {
            dbg("🔍 JavaScript 네비게이션 중 → pageUpdate")
            return .pageUpdate
        }
        
        // 히스토리가 비어있으면 새 페이지
        if pageHistory.isEmpty {
            dbg("🔍 첫 페이지 → newPage")
            return .newPage
        }
        
        // 🛡️ 안전한 배열 접근
        guard let lastRecord = pageHistory.last else {
            dbg("🔍 마지막 기록 없음 → newPage")
            return .newPage
        }
        
        dbg("🔍 이전 URL: \(lastRecord.url.absoluteString)")
        dbg("🔍 현재 URL: \(finalURL.absoluteString)")
        
        // 같은 URL이면 업데이트만
        if lastRecord.url == finalURL {
            dbg("🔍 동일 URL → pageUpdate")
            return .pageUpdate
        }
        
        // ✨ 상세한 URL 변경 분석
        let previousURL = lastRecord.url
        
        // 1. Fragment만 변경 (예: #section1 → #section2)
        if previousURL.absoluteStringWithoutFragment == finalURL.absoluteStringWithoutFragment {
            if previousURL.fragment != finalURL.fragment {
                dbg("🔍 Fragment만 변경: \(previousURL.fragment ?? "nil") → \(finalURL.fragment ?? "nil") → inPageNavigation")
                return .inPageNavigation  // ✨ forward 기록 보존
            }
        }
        
        // 2. 같은 호스트 + 같은 base path인 경우 (Query parameter만 변경)
        if previousURL.host == finalURL.host && previousURL.basePath == finalURL.basePath {
            if previousURL.query != finalURL.query {
                dbg("🔍 Query parameter만 변경: '\(previousURL.query ?? "nil")' → '\(finalURL.query ?? "nil")' → inPageNavigation")
                return .inPageNavigation  // ✨ forward 기록 보존
            }
        }
        
        // 3. 같은 호스트 내에서 경로 변경 (예: /page1 → /page2)
        if previousURL.host == finalURL.host {
            if previousURL.path != finalURL.path {
                dbg("🔍 같은 호스트 내 경로 변경: '\(previousURL.path)' → '\(finalURL.path)'")
                
                // ✨ 세부 판단: 상위/하위 디렉토리인지 확인
                if isRelatedPath(from: previousURL.path, to: finalURL.path) {
                    dbg("🔍 관련된 경로 변경 → inPageNavigation (forward 보존)")
                    return .inPageNavigation
                } else {
                    dbg("🔍 완전히 다른 경로 → newPage")
                    return .newPage
                }
            }
        }
        
        // 4. 완전히 다른 도메인
        if previousURL.host != finalURL.host {
            dbg("🔍 다른 도메인: '\(previousURL.host ?? "nil")' → '\(finalURL.host ?? "nil")' → newPage")
            return .newPage
        }
        
        // 기본적으로 새 페이지
        dbg("🔍 기본 판단 → newPage")
        return .newPage
    }
    
    // ✨ 경로 관련성 판단 (상위/하위 디렉토리 등)
    private func isRelatedPath(from oldPath: String, to newPath: String) -> Bool {
        // 예: /product/123 → /product/123/reviews (하위 페이지)
        if newPath.hasPrefix(oldPath + "/") {
            return true
        }
        
        // 예: /product/123/reviews → /product/123 (상위 페이지)
        if oldPath.hasPrefix(newPath + "/") {
            return true
        }
        
        // 같은 디렉토리 내 파일 (예: /docs/page1.html → /docs/page2.html)
        let oldComponents = oldPath.components(separatedBy: "/")
        let newComponents = newPath.components(separatedBy: "/")
        
        if oldComponents.count == newComponents.count && oldComponents.count > 1 {
            // 마지막 컴포넌트만 다른 경우
            let oldDir = oldComponents.dropLast().joined(separator: "/")
            let newDir = newComponents.dropLast().joined(separator: "/")
            return oldDir == newDir
        }
        
        return false
    }
    
    // ✨ 페이지 변경 처리 메인 로직 (🛡️ 안전성 강화)
    private func handlePageChange(url: URL, title: String, changeType: PageChangeType) {
        dbg("📋 === handlePageChange 시작 (안전 모드) ===")
        dbg("📋 URL: \(url.absoluteString)")
        dbg("📋 제목: '\(title)'")
        dbg("📋 변경 타입: \(changeType.description)")
        
        do {
            // 🛡️ 상태 검증
            guard pageHistory.count < 100 else {
                throw HistoryError.tooManyPages
            }
            
            guard url.absoluteString.count < 2048 else {
                throw HistoryError.urlTooLong
            }
            
            switch changeType {
            case .newPage:
                // ✅ 완전히 새로운 페이지 → forward 기록 삭제 후 추가
                try safeAddNewPageWithForwardClear(url: url, title: title)
                
            case .pageUpdate:
                // ✅ 기존 페이지 업데이트 → forward 기록 보존
                try safeUpdateCurrentPageOnly(url: url, title: title)
                
            case .inPageNavigation:
                // ✅ 페이지 내 네비게이션 → forward 기록 보존하며 새 기록 추가
                try safeAddNewPageWithForwardPreserve(url: url, title: title)
            }
            
            dbg("📋 === handlePageChange 완료 (안전 모드) ===")
            
        } catch {
            dbg("❌ handlePageChange 실패: \(error.localizedDescription)")
            // 🛡️ 실패 시 안전한 기본 동작
            fallbackToBasicPageAdd(url: url, title: title)
        }
    }
    
    // 🛡️ Forward 기록을 삭제하고 새 페이지 추가 (안전성 강화)
    private func safeAddNewPageWithForwardClear(url: URL, title: String) throws {
        dbg("🆕 === Forward 삭제 후 새 페이지 추가 (안전 모드) ===")
        
        // 🛡️ 현재 위치 검증
        guard currentPageIndex >= -1 && currentPageIndex < pageHistory.count else {
            throw HistoryError.invalidIndex
        }
        
        // Forward 기록 제거 (안전하게)
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removeRange = (currentPageIndex + 1)..<pageHistory.count
            guard removeRange.lowerBound <= removeRange.upperBound else {
                throw HistoryError.stateInconsistency
            }
            
            let removedCount = removeRange.count
            let removedPages = Array(pageHistory[removeRange])
            pageHistory.removeSubrange(removeRange)
            
            dbg("🧹 Forward 히스토리 정리: \(removedCount)개 제거")
            removedPages.forEach { page in
                dbg("🧹   제거된 페이지: '\(page.title)' | \(page.url.absoluteString)")
            }
        }
        
        // 새 페이지 추가
        let newRecord = PageRecord(url: url, title: title)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // 🛡️ 최종 상태 검증
        guard isValidIndex(currentPageIndex) else {
            throw HistoryError.stateInconsistency
        }
        
        // 최대 50개 유지
        if pageHistory.count > 50 {
            let removedPage = pageHistory.removeFirst()
            currentPageIndex = safeIndex(currentPageIndex - 1)
            dbg("🧹 히스토리 크기 제한: 첫 페이지 제거 - '\(removedPage.title)'")
        }
        
        updateNavigationState()
        dbg("🆕 새 페이지 추가 (Forward 삭제): '\(title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))]")
    }
    
    // 🛡️ 기존 페이지만 업데이트 (Forward 기록 보존, 안전성 강화)
    private func safeUpdateCurrentPageOnly(url: URL, title: String) throws {
        dbg("📝 === 기존 페이지만 업데이트 (안전 모드) ===")
        
        guard isValidIndex(currentPageIndex) else {
            throw HistoryError.invalidIndex
        }
        
        let oldTitle = pageHistory[currentPageIndex].title
        let oldURL = pageHistory[currentPageIndex].url
        
        // URL과 제목 업데이트
        pageHistory[currentPageIndex].updateURL(url)
        pageHistory[currentPageIndex].updateTitle(title)
        
        dbg("📝 페이지 업데이트 완료:")
        dbg("📝   제목: '\(oldTitle)' → '\(title)'")
        dbg("📝   URL: \(oldURL.absoluteString) → \(url.absoluteString)")
        dbg("📝   [ID: \(String(pageHistory[currentPageIndex].id.uuidString.prefix(8)))]")
        
        updateNavigationState()
    }
    
    // 🛡️ Forward 기록 보존하며 새 기록 추가 (안전성 강화)
    private func safeAddNewPageWithForwardPreserve(url: URL, title: String) throws {
        dbg("🔗 === Forward 보존하며 새 기록 추가 (안전 모드) ===")
        
        let newRecord = PageRecord(url: url, title: title)
        
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            // 🛡️ 중간에 삽입 (안전한 인덱스 검증)
            let insertIndex = currentPageIndex + 1
            guard insertIndex <= pageHistory.count else {
                throw HistoryError.invalidIndex
            }
            
            if !safeInsertPage(newRecord, at: insertIndex) {
                throw HistoryError.stateInconsistency
            }
            
            currentPageIndex = insertIndex
            dbg("🔗 중간 삽입: 인덱스 \(currentPageIndex)에 새 기록 추가")
            dbg("🔗 Forward 히스토리 보존: \(pageHistory.count - currentPageIndex - 1)개 페이지")
        } else {
            // 끝에 추가 (기존 로직과 동일)
            pageHistory.append(newRecord)
            currentPageIndex = pageHistory.count - 1
            dbg("🔗 끝에 추가: 새 기록 추가")
        }
        
        // 🛡️ 최종 상태 검증
        guard isValidIndex(currentPageIndex) else {
            throw HistoryError.stateInconsistency
        }
        
        // 최대 50개 유지
        if pageHistory.count > 50 {
            let removedPage = pageHistory.removeFirst()
            currentPageIndex = safeIndex(currentPageIndex - 1)
            dbg("🧹 히스토리 크기 제한: 첫 페이지 제거 - '\(removedPage.title)'")
        }
        
        updateNavigationState()
        dbg("🔗 Forward 보존 추가 완료: '\(title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))]")
        dbg("🔗 현재 상태: 인덱스 \(currentPageIndex)/\(pageHistory.count), back=\(canGoBack), forward=\(canGoForward)")
    }
    
    // 🛡️ 실패 시 안전한 대안
    private func fallbackToBasicPageAdd(url: URL, title: String) {
        dbg("🚨 안전 모드: 기본 페이지 추가 실행")
        
        let newRecord = PageRecord(url: url, title: title)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        // 크기 제한
        if pageHistory.count > 50 {
            pageHistory.removeFirst()
            currentPageIndex = safeIndex(currentPageIndex - 1)
        }
        
        updateNavigationState()
        dbg("🚨 안전 모드 완료: 인덱스=\(currentPageIndex), 총개수=\(pageHistory.count)")
    }

    // MARK: - 새로운 페이지 기록 시스템 (✨ 개선된 로직 적용)
    
    private func addNewPage(url: URL, title: String = "") {
        dbg("📋 === addNewPage 호출 (개선된 안전 로직) ===")
        
        // 히스토리 네비게이션 활성 중이면 추가 안함
        if isHistoryNavigationActive() {
            dbg("🚫 히스토리 네비게이션 활성 중 - 새 페이지 추가 방지")
            return
        }
        
        // 🛡️ 안전한 히스토리 수정
        safeHistoryModification { [self] in
            // 변경 타입 분석
            let changeType = analyzePageChange(finalURL: url)
            
            // 변경 타입에 따라 처리
            handlePageChange(url: url, title: title, changeType: changeType)
        }
        
        dbg("📋 === addNewPage 호출 끝 ===")
    }
    
    // 🔧 완전히 커스텀 히스토리 기반으로 상태 업데이트
    private func updateNavigationState() {
        let oldBack = canGoBack
        let oldForward = canGoForward
        
        // 🛡️ 안전한 인덱스 검증 후 상태 계산
        canGoBack = currentPageIndex > 0 && !pageHistory.isEmpty
        canGoForward = currentPageIndex < pageHistory.count - 1 && !pageHistory.isEmpty
        
        if oldBack != canGoBack || oldForward != canGoForward {
            dbg("🔄 네비게이션 상태 업데이트 (커스텀): back=\(canGoBack), forward=\(canGoForward), 인덱스=\(currentPageIndex)/\(pageHistory.count)")
        }
    }
    
    func updateCurrentPageTitle(_ title: String) {
        guard isValidIndex(currentPageIndex), !title.isEmpty else { 
            dbg("📝 제목 업데이트 실패: 인덱스=\(currentPageIndex), 총개수=\(pageHistory.count), 제목='\(title)'")
            return 
        }
        
        let oldTitle = pageHistory[currentPageIndex].title
        pageHistory[currentPageIndex].updateTitle(title)
        
        dbg("📝 페이지 제목 업데이트: '\(oldTitle)' → '\(title)' [ID: \(String(pageHistory[currentPageIndex].id.uuidString.prefix(8)))]")
    }
    
    var currentPageRecord: PageRecord? {
        guard isValidIndex(currentPageIndex) else { return nil }
        return pageHistory[currentPageIndex]
    }

    // MARK: - 세션 저장/복원 (단순화)
    
    func saveSession() -> WebViewSession? {
        guard !pageHistory.isEmpty, isValidIndex(currentPageIndex) else {
            dbg("💾 세션 저장 실패: 히스토리 없음")
            return nil
        }
        
        let session = WebViewSession(pageRecords: pageHistory, currentIndex: currentPageIndex)
        dbg("💾 세션 저장: \(pageHistory.count)개 페이지, 현재 인덱스 \(currentPageIndex)")
        return session
    }

    // ✅ 🔧 복원 과정 개선 (🛡️ 이중 로딩 방지 + 강화된 디버깅)
    func restoreSession(_ session: WebViewSession) {
        dbg("🔄 === 세션 복원 시작 ===")
        dbg("🔄 복원할 데이터: \(session.pageRecords.count)개 페이지, 인덱스 \(session.currentIndex)")
        
        // 🛡️ 안전한 세션 복원
        safeHistoryModification { [self] in
            isRestoringSession = true
            
            pageHistory = session.pageRecords
            currentPageIndex = safeIndex(session.currentIndex)
            
            dbg("🔄 복원된 히스토리:")
            for (index, record) in pageHistory.enumerated() {
                let marker = index == currentPageIndex ? "👉" : "  "
                dbg("🔄\(marker) [\(index)] \(record.title) | \(record.url.absoluteString)")
            }
            
            // 🛡️ 복원 상태 상세 검증
            if let currentRecord = currentPageRecord {
                dbg("🔄 ✅ 현재 페이지 기록 발견: '\(currentRecord.title)' | \(currentRecord.url.absoluteString)")
                
                // 🛡️ 이중 로딩 방지: isUpdatingCurrentURL 플래그 사용
                isUpdatingCurrentURL = true
                currentURL = currentRecord.url  // didSet 로딩 방지
                isUpdatingCurrentURL = false
                
                dbg("🔄 ✅ currentURL 설정 완료: \(currentRecord.url.absoluteString)")
                
                dbg("🔄 세션 복원: \(pageHistory.count)개 페이지, 현재 '\(currentRecord.title)'")
                
                // 🛡️ 웹뷰 상태 검증 및 로딩
                if let webView = webView {
                    dbg("🔄 ✅ 웹뷰 연결됨: 로딩 시작")
                    webView.load(URLRequest(url: currentRecord.url))
                    dbg("🌐 복원 시 웹뷰 로드: \(currentRecord.url.absoluteString)")
                    
                    // 🛡️ 복원 상태 검증을 위한 타이머 (5초 후 실패 시 대안 실행)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        if self.isRestoringSession {
                            self.dbg("⚠️ 복원 타임아웃: 강제 완료 처리")
                            self.isRestoringSession = false
                            self.updateNavigationState()
                            
                            // 🛡️ 상태 재검증
                            self.verifyRestorationState()
                        }
                    }
                } else {
                    dbg("❌ 웹뷰가 없어서 복원 로드 불가")
                    // 🛡️ 웹뷰 없을 때 대안: 다음 틱에서 재시도
                    DispatchQueue.main.async {
                        self.dbg("🔄 웹뷰 재연결 시도")
                        self.retryRestorationWithWebView(currentRecord.url)
                    }
                }
            } else {
                dbg("❌ 현재 페이지 기록 없음: currentPageIndex=\(currentPageIndex), total=\(pageHistory.count)")
                
                // 🛡️ 페이지 기록이 없을 때 대안
                if !pageHistory.isEmpty {
                    // 첫 번째 페이지로 강제 설정
                    currentPageIndex = 0
                    if let firstRecord = pageHistory.first {
                        dbg("🔄 첫 번째 페이지로 대체: \(firstRecord.url.absoluteString)")
                        isUpdatingCurrentURL = true
                        currentURL = firstRecord.url
                        isUpdatingCurrentURL = false
                        
                        if let webView = webView {
                            webView.load(URLRequest(url: firstRecord.url))
                        }
                    }
                } else {
                    currentURL = nil
                    dbg("🔄 세션 복원 실패: 유효한 페이지 없음")
                }
                
                // 🛡️ 완전 실패 시 대안: 빈 히스토리로 시작
                if pageHistory.isEmpty {
                    dbg("🚨 히스토리가 완전히 비어있음 - 정상 상태로 초기화")
                    isRestoringSession = false
                }
            }
            
            // 복원 즉시 상태 업데이트
            updateNavigationState()
            dbg("🔧 복원 후 즉시 상태: back=\(canGoBack), forward=\(canGoForward), 인덱스=\(currentPageIndex)/\(pageHistory.count)")
            
            // 🛡️ 최종 상태 검증
            verifyRestorationState()
        }
        
        dbg("🔄 복원 타이머 없이 didFinish 대기")
    }
    
    // 🛡️ 복원 상태 검증 메서드 (새로 추가)
    private func verifyRestorationState() {
        dbg("🔍 === 복원 상태 검증 ===")
        dbg("🔍 currentURL: \(currentURL?.absoluteString ?? "❌ nil")")
        dbg("🔍 pageHistory.count: \(pageHistory.count)")
        dbg("🔍 currentPageIndex: \(currentPageIndex)")
        dbg("🔍 isRestoringSession: \(isRestoringSession)")
        dbg("🔍 웹뷰 연결: \(webView != nil ? "✅ 연결됨" : "❌ 없음")")
        
        if let currentRecord = currentPageRecord {
            dbg("🔍 현재 페이지: '\(currentRecord.title)' | \(currentRecord.url.absoluteString)")
        } else {
            dbg("🔍 ❌ 현재 페이지 기록 없음")
        }
        
        // 🛡️ 복원이 완료되었는데 currentURL이 없으면 문제
        if !isRestoringSession && currentURL == nil && !pageHistory.isEmpty {
            dbg("🚨 복원 완료 후 currentURL 없음 - 강제 복구 시도")
            if let firstRecord = pageHistory.first {
                isUpdatingCurrentURL = true
                currentURL = firstRecord.url
                isUpdatingCurrentURL = false
                
                if let webView = webView {
                    webView.load(URLRequest(url: firstRecord.url))
                    dbg("🚨 강제 복구: \(firstRecord.url.absoluteString)")
                }
            }
        }
        
        dbg("🔍 === 복원 상태 검증 끝 ===")
    }
    
    // 🛡️ 웹뷰 재연결 시도 메서드 (새로 추가)
    private func retryRestorationWithWebView(_ url: URL) {
        dbg("🔄 === 웹뷰 재연결 시도 ===")
        
        // 웹뷰가 연결되기까지 최대 3초 대기
        var retryCount = 0
        let maxRetries = 6  // 0.5초 간격으로 6번 = 3초
        
        func attemptReconnection() {
            retryCount += 1
            dbg("🔄 재연결 시도 \(retryCount)/\(maxRetries)")
            
            if let webView = webView {
                dbg("🔄 ✅ 웹뷰 재연결 성공")
                webView.load(URLRequest(url: url))
                isRestoringSession = false
                updateNavigationState()
            } else if retryCount < maxRetries {
                dbg("🔄 웹뷰 아직 없음, 0.5초 후 재시도")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    attemptReconnection()
                }
            } else {
                dbg("🔄 ❌ 웹뷰 재연결 실패: 최대 시도 횟수 초과")
                isRestoringSession = false
                fallbackRestoreFromURL(url)
            }
        }
        
        attemptReconnection()
    }
    
    // 🛡️ 복원 실패 시 대안 메서드
    private func fallbackRestoreFromURL(_ url: URL) {
        dbg("🚨 === 복원 실패 대안 실행 ===")
        
        safeHistoryModification { [self] in
            // 최소한의 히스토리 생성
            pageHistory.removeAll()
            let fallbackRecord = PageRecord(url: url, title: url.host ?? "복원된 페이지")
            pageHistory.append(fallbackRecord)
            currentPageIndex = 0
            
            // 강제 로딩
            isUpdatingCurrentURL = true
            currentURL = url
            isUpdatingCurrentURL = false
            
            if let webView = webView {
                webView.load(URLRequest(url: url))
                dbg("🚨 대안 로딩: \(url.absoluteString)")
            }
            
            updateNavigationState()
            isRestoringSession = false
            
            dbg("🚨 대안 복원 완료: 1개 페이지로 시작")
        }
    }

    // MARK: - 네비게이션 메서드 (WebView 네이티브 메서드 사용 안함, 🛡️ 안전성 강화)
    
    func goBack() {
        guard canGoBack, currentPageIndex > 0, isValidIndex(currentPageIndex - 1) else { 
            dbg("⬅️ 뒤로가기 불가: canGoBack=\(canGoBack), index=\(currentPageIndex)")
            return 
        }
        
        dbg("⬅️ === 뒤로가기 시작 ===")
        dbg("⬅️ 현재 인덱스: \(currentPageIndex) → \(currentPageIndex - 1)")
        
        // 🛡️ 안전한 히스토리 수정
        safeHistoryModification { [self] in
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
        }
        
        dbg("⬅️ === 뒤로가기 끝 ===")
    }
    
    func goForward() {
        guard canGoForward, currentPageIndex < pageHistory.count - 1, 
              isValidIndex(currentPageIndex + 1) else { 
            dbg("➡️ 앞으로가기 불가: canGoForward=\(canGoForward), index=\(currentPageIndex), total=\(pageHistory.count)")
            return 
        }
        
        dbg("➡️ === 앞으로가기 시작 ===")
        dbg("➡️ 현재 인덱스: \(currentPageIndex) → \(currentPageIndex + 1)")
        
        // 🛡️ 안전한 히스토리 수정
        safeHistoryModification { [self] in
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
        return safeIndex(currentPageIndex)
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
           !isJavaScriptNavigation,  // ✨ JavaScript 네비게이션 체크 추가
           currentURL != startURL {
            
            dbg("👆 === 스와이프 제스처 감지 분석 ===")
            dbg("👆 시작 URL: \(startURL.absoluteString)")
            dbg("👆 현재 URL: \(currentURL?.absoluteString ?? "nil")")
            
            // 현재 커스텀 히스토리에서 URL 찾기
            if let foundIndex = pageHistory.firstIndex(where: { $0.url == startURL }) {
                let currentIndex = currentPageIndex
                
                dbg("👆 히스토리에서 발견: 인덱스 \(foundIndex), 현재 인덱스: \(currentIndex)")
                
                // 🛡️ 안전한 인덱스 검증
                guard isValidIndex(foundIndex) else {
                    dbg("👆 잘못된 인덱스 발견: \(foundIndex)")
                    return
                }
                
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
        if let startURL = startURL, currentURL != startURL && !isRestoringSession && !isJavaScriptNavigation {
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
            dbg("🏷️   - JavaScript네비: \(isJavaScriptNavigation)")
            
            if let startTime = historyNavigationStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                dbg("🏷️   - 히스토리 네비게이션 경과시간: \(elapsed)초")
            }
            
            // ✅ 복원 상태 우선 처리 (절대 새 페이지 추가하지 않음)
            if isRestoringSession {
                dbg("🔄 === 복원 중 처리 ===")
                
                // 🛡️ 안전한 제목 업데이트
                safeHistoryModification { [self] in
                    updateCurrentPageTitle(title)
                    
                    // ✅ 복원 완료 처리를 didFinish에서 수행
                    isRestoringSession = false
                    updateNavigationState()
                    
                    // 🛡️ 복원 완료 후 상태 검증
                    if currentURL != finalURL {
                        dbg("🔄 복원 후 URL 불일치 감지: \(currentURL?.absoluteString ?? "nil") → \(finalURL.absoluteString)")
                        isUpdatingCurrentURL = true
                        currentURL = finalURL
                        isUpdatingCurrentURL = false
                    }
                }
                
                dbg("🔄 복원 완료: '\(title)' - isRestoringSession = false")
                dbg("🔄 최종 상태: back=\(canGoBack), forward=\(canGoForward), 인덱스=\(currentPageIndex)/\(pageHistory.count)")
                dbg("🔄 === 복원 중 처리 끝 ===")
                dbg("🔄 === 세션 복원 끝 ===")
                
            } else if isHistoryNavigationActive() {
                dbg("🔄 === 히스토리 네비게이션 처리 (버튼 또는 스와이프) ===")
                
                // 🛡️ 안전한 제목 업데이트
                safeHistoryModification { [self] in
                    updateCurrentPageTitle(title)
                }
                
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
                
            } else if isJavaScriptNavigation {
                // ✨ JavaScript 네비게이션은 이미 handleJavaScriptURLChange에서 처리됨
                dbg("🔄 === JavaScript 네비게이션 처리 ===")
                dbg("🔄 JavaScript에서 이미 처리됨 - 중복 처리 방지")
                
                // 플래그만 해제
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.isJavaScriptNavigation = false
                    self.dbg("🏁 JavaScript 네비게이션 플래그 지연 해제 (didFinish)")
                }
                
                dbg("🔄 === JavaScript 네비게이션 처리 끝 ===")
                dbg("🌐 === didFinish 분석 끝 (JavaScript) ===")
                return
                
            } else {
                dbg("🆕 === 일반 네비게이션 처리 ===")
                
                // 🛡️ 안전한 페이지 변경 분석 및 처리
                safeHistoryModification { [self] in
                    let changeType = analyzePageChange(finalURL: finalURL)
                    
                    dbg("🤔 페이지 변경 타입: \(changeType.description)")
                    
                    // 변경 타입에 따라 처리
                    handlePageChange(url: finalURL, title: title, changeType: changeType)
                    
                    // 전역 방문 기록 추가 (새 페이지 또는 페이지 내 네비게이션인 경우)
                    if changeType == .newPage || changeType == .inPageNavigation {
                        WebViewStateModel.globalHistory.append(.init(url: finalURL, title: title, date: Date()))
                        WebViewStateModel.saveGlobalHistory()
                    }
                    
                    // currentURL 동기화
                    isNavigatingFromWebView = true
                    currentURL = finalURL
                    isNavigatingFromWebView = false
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
        
        // ✅ 복원이 아니고 JavaScript 네비게이션이 아닐 때만 navigationDidFinish 호출
        if !wasRestoringSession && !isJavaScriptNavigation {
            navigationDidFinish.send(())
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
        isJavaScriptNavigation = false
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
        isJavaScriptNavigation = false
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
                                // 🛡️ 안전한 페이지 이동
                                if let index = state.pageHistory.firstIndex(where: { $0.id == record.id }),
                                   state.isValidIndex(index) {
                                    state.safeHistoryModification { [state] in
                                        state.currentPageIndex = index
                                        state.currentURL = record.url
                                        if let webView = state.webView {
                                            webView.load(URLRequest(url: record.url))
                                        }
                                        state.updateNavigationState()
                                    }
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
