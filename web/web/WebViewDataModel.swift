//
//  WebViewDataModel.swift
//  🎯 단순화된 정상 히스토리 시스템 + 직렬화 큐 복원 시스템
//  ✅ 정상 기록, 정상 배열 - 예측 가능한 동작
//  🚫 네이티브 시스템 완전 차단 - 순수 커스텀만
//  🔧 연타 레이스 방지 - 1-in-flight 직렬화 큐 시스템
//  🔧 제목 덮어쓰기 문제 해결 - URL 검증 추가
//  📁 다운로드 델리게이트 코드 헬퍼로 이관 완료
//

import Foundation
import SwiftUI
import WebKit

// MARK: - 네비게이션 타입 정의
enum NavigationType: String, Codable, CaseIterable {
    case normal = "normal"
    case reload = "reload"
    case home = "home"
    case spaNavigation = "spa"
    case userClick = "userClick"
}

// MARK: - 페이지 기록
struct PageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    let timestamp: Date
    var lastAccessed: Date
    var siteType: String?
    var navigationType: NavigationType = .normal
    
    init(url: URL, title: String = "", siteType: String? = nil, navigationType: NavigationType = .normal) {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? (url.host ?? "제목 없음") : title
        self.timestamp = Date()
        self.lastAccessed = Date()
        self.siteType = siteType
        self.navigationType = navigationType
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
    
    // URL 정규화 (게시글 구분용 핵심 파라미터 유지)
    static func normalizeURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        if components?.scheme == "http" {
            components?.scheme = "https"
        }
        
        if let path = components?.path, path.hasSuffix("/") && path.count > 1 {
            components?.path = String(path.dropLast())
        }
        
        // 핵심 파라미터만 유지
        if let queryItems = components?.queryItems {
            let importantParams = ["document_srl", "wr_id", "no", "id", "mid", "page"]
            let filteredItems = queryItems.filter { importantParams.contains($0.name) }
            
            if !filteredItems.isEmpty {
                components?.queryItems = filteredItems.sorted { $0.name < $1.name }
            } else {
                components?.query = nil
            }
        }
        
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
    
    func normalizedURL() -> String {
        return Self.normalizeURL(self.url)
    }
    
    // 로그인 관련 URL 감지
    static func isLoginRelatedURL(_ url: URL) -> Bool {
        let urlString = url.absoluteString.lowercased()
        let loginPatterns = [
            "login", "signin", "auth", "oauth", "sso", "redirect", "callback",
            "nid.naver.com", "accounts.google.com", "facebook.com/login", "twitter.com/oauth",
            "returnurl=", "redirect_uri=", "continue=", "state=", "code="
        ]
        return loginPatterns.contains { urlString.contains($0) }
    }
}

// MARK: - 세션 저장/복원
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
}

// MARK: - 전역 히스토리
struct HistoryEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    let url: URL
    let title: String
    let date: Date
}

// MARK: - Collection 확장: 안전 인덱싱 (중복 제거됨 - tabview.swift에서 정의됨)

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 🎯 **WebViewDataModel - 직렬화 큐 복원 시스템**
final class WebViewDataModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID?
    
    // ✅ 순수 히스토리 배열 (정상 기록, 정상 배열)
    @Published private(set) var pageHistory: [PageRecord] = []
    @Published private(set) var currentPageIndex: Int = -1
    
    // ✅ 단순한 네비게이션 상태
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    
    // ✅ 복원 상태만 유지
    private(set) var isRestoringSession: Bool = false
    
    // 🎯 **직렬화 큐 시스템**: 1-in-flight 복원으로 연타 레이스 방지
    private(set) var isRestoring: Bool = false
    private var restoreQueue: [Int] = [] // 목표 인덱스 큐
    private(set) var expectedNormalizedURL: String? = nil
    
    // 🎯 큐 상태 조회용 (StateModel에서 로깅용)
    var queueCount: Int { restoreQueue.count }
    
    // ✅ 전역 히스토리
    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }
    
    // ✅ StateModel 참조
    weak var stateModel: WebViewStateModel?
    
    override init() {
        super.init()
        Self.loadGlobalHistory()
    }
    
    // MARK: - 🎯 **핵심: 단순한 네비게이션 상태 관리**
    
    private func updateNavigationState() {
        let newCanGoBack = currentPageIndex > 0
        let newCanGoForward = currentPageIndex < pageHistory.count - 1
        
        if canGoBack != newCanGoBack || canGoForward != newCanGoForward {
            canGoBack = newCanGoBack
            canGoForward = newCanGoForward
            objectWillChange.send()
            dbg("🎯 네비게이션 상태: back=\(canGoBack), forward=\(canGoForward), index=\(currentPageIndex)/\(pageHistory.count)")
        }
    }
    
    // MARK: - 🎯 **직렬화 큐 시스템 관리**
    
    func enqueueRestore(to targetIndex: Int) {
        restoreQueue.append(targetIndex)
        dbg("📥 복원 큐 추가: 인덱스 \(targetIndex) (큐 길이: \(restoreQueue.count))")
        
        if !isRestoring {
            startNextRestore()
        }
    }
    
    private func startNextRestore() {
        guard !restoreQueue.isEmpty, !isRestoring else { return }
        
        let targetIndex = restoreQueue.removeFirst()
        guard targetIndex >= 0, targetIndex < pageHistory.count else {
            dbg("❌ 잘못된 복원 인덱스: \(targetIndex), 다음 큐 처리")
            startNextRestore()
            return
        }
        
        isRestoring = true
        currentPageIndex = targetIndex
        updateNavigationState()
        
        let targetRecord = pageHistory[targetIndex]
        expectedNormalizedURL = targetRecord.normalizedURL()
        
        dbg("🔄 복원 시작: 인덱스 \(targetIndex) → '\(targetRecord.title)' (큐 남은 건수: \(restoreQueue.count))")
        
        // StateModel에 URL 동기화 및 부드러운 로딩 요청
        stateModel?.performQueuedRestore(to: targetRecord.url)
    }
    
    func finishCurrentRestore() {
        guard isRestoring else { return }
        
        isRestoring = false
        expectedNormalizedURL = nil
        dbg("✅ 복원 완료, 다음 큐 처리 시작")
        
        // 큐에 대기 중인 다음 복원 처리
        if !restoreQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.startNextRestore()
            }
        }
    }
    
    func isHistoryNavigationActive() -> Bool {
        return isRestoring
    }
    
    // MARK: - 🌐 **SPA 네비게이션 처리** (큐 기반 복원 적용)
    
    func handleSPANavigation(type: String, url: URL, title: String, timestamp: Double, siteType: String = "unknown") {
        dbg("🌐 SPA \(type): \(siteType) | \(url.absoluteString)")
        
        // 로그인 관련은 무시
        if PageRecord.isLoginRelatedURL(url) {
            dbg("🔒 로그인 페이지 무시: \(url.absoluteString)")
            return
        }
        
        switch type {
        case "push":
            // 🎯 **복원 중에는 새 페이지 추가 금지**
            if isRestoring {
                dbg("🤫 복원 중 SPA push 무시: \(url.absoluteString)")
                return
            }
            // 모든 push는 새 페이지 (홈페이지든 일반페이지든)
            addNewPage(url: url, title: title)
            
        case "replace":
            // replace는 현재 페이지 교체 (복원 중이어도 허용)
            replaceCurrentPage(url: url, title: title, siteType: siteType)
            
        case "pop":
            // 🎯 **pop에서 기존 엔트리 탐색 후 큐 기반 복원 시도**
            if let existingIndex = findPageIndex(for: url) {
                dbg("🔄 SPA pop - 기존 히스토리 항목 발견, 큐에 추가: \(existingIndex)")
                
                // 직렬화 큐에 추가 (새 항목 생성 안함)
                enqueueRestore(to: existingIndex)
                
            } else {
                // 기존 항목이 없으면 새 페이지 추가 (복원 중이 아닐 때만)
                if !isRestoring {
                    addNewPage(url: url, title: title)
                    dbg("🔄 SPA pop - 새 페이지 추가")
                } else {
                    dbg("🤫 복원 중 SPA pop 무시: \(url.absoluteString)")
                }
            }
            
        case "hash", "dom":
            // 홈페이지면 새 페이지, 아니면 현재 페이지 교체
            if isHomepageURL(url) && !isRestoring {
                addNewPage(url: url, title: title)
            } else {
                replaceCurrentPage(url: url, title: title, siteType: siteType)
            }
            
        case "title":
            // 🔧 **수정**: URL 기반 제목 업데이트 사용
            updatePageTitle(for: url, title: title)
            
        default:
            dbg("🌐 알 수 없는 SPA 타입: \(type)")
        }
        
        // 🎯 **복원 중에는 전역 히스토리 추가 금지**
        if type != "title" && !isRestoring && !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }
    
    private func isHomepageURL(_ url: URL) -> Bool {
        let path = url.path
        let query = url.query
        
        // 쿼리 파라미터가 있으면 홈페이지가 아님
        if let query = query, !query.isEmpty {
            return false
        }
        
        return path == "/" || path.isEmpty || path == "/main" || path == "/home"
    }
    
    // MARK: - 🌐 **SPA 훅 JavaScript 스크립트** (CustomWebView에서 사용)
    
    static func makeSPANavigationScript() -> WKUserScript {
        let scriptSource = """
        // 🌐 완전형 SPA 네비게이션 & DOM 변경 감지 훅
        (function() {
            'use strict';

            console.log('🌐 SPA 네비게이션 훅 초기화');

            const originalPushState = history.pushState;
            const originalReplaceState = history.replaceState;

            let currentSPAState = {
                url: window.location.href,
                title: document.title,
                timestamp: Date.now(),
                state: history.state
            };

            const EXCLUDE_PATTERNS = [
                /\\/login/i, /\\/signin/i, /\\/auth/i, /\\/oauth/i, /\\/sso/i,
                /\\/redirect/i, /\\/callback/i, /\\/nid\\.naver\\.com/i,
                /\\/accounts\\.google\\.com/i, /\\/facebook\\.com\\/login/i,
                /\\/twitter\\.com\\/oauth/i, /returnUrl=/i, /redirect_uri=/i, /continue=/i
            ];

            function shouldExcludeFromHistory(url) {
                return EXCLUDE_PATTERNS.some(pattern => pattern.test(url));
            }

            // ===== 범용 커뮤니티 패턴 매칭 =====
            function detectSiteType(url) {
                const urlObj = new URL(url, window.location.origin);
                const host = urlObj.hostname.toLowerCase();
                const path = (urlObj.pathname + urlObj.search + urlObj.hash).toLowerCase();

                let pattern = 'unknown';

                // 숫자형 단일 경로
                if (path.match(/^\\/\\d+$/)) {
                    pattern = '1level_numeric';
                } else if (path.match(/^\\/[^/]+\\/\\d+$/)) {
                    pattern = '2level_numeric';
                } else if (path.match(/^\\/[^/]+\\/[^/]+\\/\\d+$/)) {
                    pattern = '3level_numeric';
                }

                // 파라미터 기반
                else if (path.match(/[?&]no=\\d+/)) {
                    pattern = 'param_no_numeric';
                } else if (path.match(/[?&]id=[^&]+&no=\\d+/)) {
                    pattern = 'param_id_no_numeric';
                } else if (path.match(/[?&]wr_id=\\d+/)) {
                    pattern = 'param_wrid_numeric';
                } else if (path.match(/[?&]id=[^&]+&page=\\d+/)) {
                    pattern = 'param_id_page_numeric';
                } else if (path.match(/[?&]bo_table=[^&]+&wr_id=\\d+/)) {
                    pattern = 'param_botable_wrid';
                }

                // php/html 파일명
                else if (path.match(/\\/[^/]+\\.php[?#]?/)) {
                    pattern = 'file_php';
                } else if (path.match(/\\/[^/]+\\.html[?#]?/)) {
                    pattern = 'file_html';
                }

                // 해시 라우팅
                else if (path.match(/#\\/[^/]+$/)) {
                    pattern = 'hash_1level';
                } else if (path.match(/#\\/[^/]+\\/\\d+$/)) {
                    pattern = 'hash_2level_numeric';
                } else if (path.match(/#\\/[^/]+\\?[^=]+=/)) {
                    pattern = 'hash_query';
                }

                // 쿼리스트링 범용
                else if (path.match(/\\?[^=]+=[^&]+$/)) {
                    pattern = 'query_single';
                } else if (path.match(/\\?[^=]+=[^&]+&[^=]+=[^&]+/)) {
                    pattern = 'query_multi';
                }

                // 혼합 숫자+문자
                else if (path.match(/\\/\\d+\\/[^/]+\\/[^/]+/)) {
                    pattern = 'numeric_first_mixed';
                }

                // 루트
                else if (path === '/' || path === '') {
                    pattern = 'root';
                }

                return `${host}_${pattern}`;
            }

            function notifyNavigation(type, url, title, state) {
                if (shouldExcludeFromHistory(url)) {
                    console.log(`🔒 히스토리 제외: ${url} (${type})`);
                    return;
                }

                const siteType = detectSiteType(url);

                const message = {
                    type: type,
                    url: url,
                    title: title || document.title,
                    state: state,
                    timestamp: Date.now(),
                    userAgent: navigator.userAgent,
                    referrer: document.referrer,
                    siteType: siteType,
                    shouldExclude: false
                };

                if (window.webkit?.messageHandlers?.spaNavigation) {
                    window.webkit.messageHandlers.spaNavigation.postMessage(message);
                    console.log(`🌐 SPA ${type}: ${siteType} | ${url}`);
                }
            }

            // ===== History API 후킹 =====
            history.pushState = function(state, title, url) {
                const result = originalPushState.apply(this, arguments);
                handleUrlChange('push', url, title, state);
                return result;
            };

            history.replaceState = function(state, title, url) {
                const result = originalReplaceState.apply(this, arguments);
                handleUrlChange('replace', url, title, state);
                return result;
            };

            // ===== URL 변경 처리 =====
            function handleUrlChange(type, url, title, state) {
                const newURL = new URL(url || window.location.href, window.location.origin).href;
                if (newURL !== currentSPAState.url) {
                    currentSPAState = {
                        url: newURL,
                        title: title || document.title,
                        timestamp: Date.now(),
                        state: state
                    };
                    setTimeout(() => {
                        notifyNavigation(type, newURL, document.title, state);
                    }, 150);
                }
            }

            // ===== popstate / hashchange 감지 =====
            window.addEventListener('popstate', () => handleUrlChange('pop', window.location.href, document.title, history.state));
            window.addEventListener('hashchange', () => handleUrlChange('hash', window.location.href, document.title, history.state));

            // ===== DOM 변경 감지 =====
            const observer = new MutationObserver(() => {
                const currentURL = window.location.href;
                if (currentURL !== currentSPAState.url) {
                    handleUrlChange('dom', currentURL, document.title, history.state);
                }
            });

            observer.observe(document.body, { childList: true, subtree: true });

            console.log('✅ SPA 네비게이션 훅 설정 완료');
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    private func replaceCurrentPage(url: URL, title: String, siteType: String) {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else {
            if !isRestoring {
                addNewPage(url: url, title: title)
            }
            return
        }
        
        var record = pageHistory[currentPageIndex]
        record.url = url
        record.updateTitle(title)
        record.siteType = siteType
        record.navigationType = .reload
        pageHistory[currentPageIndex] = record
        
        dbg("🔄 SPA Replace - 현재 페이지 교체: '\(title)'")
        stateModel?.syncCurrentURL(url)
    }
    
    // MARK: - 🎯 **핵심: 단순한 새 페이지 추가 로직 (큐 기반 복원 적용)**
    
    func addNewPage(url: URL, title: String = "") {
        // 🔒 로그인 관련은 완전 무시
        if PageRecord.isLoginRelatedURL(url) {
            dbg("🔒 로그인 페이지 히스토리 제외: \(url.absoluteString)")
            return
        }
        
        // 🎯 **복원 중에는 새 페이지 추가 금지**
        if isRestoring {
            dbg("🤫 복원 중 새 페이지 추가 차단: \(url.absoluteString)")
            return
        }
        
        // ✅ **핵심 로직**: 현재 페이지와 같으면 제목만 업데이트
        if let currentRecord = currentPageRecord,
           currentRecord.normalizedURL() == PageRecord.normalizeURL(url) {
            updatePageTitle(for: url, title: title)
            dbg("🔄 같은 페이지 - 제목만 업데이트: '\(title)'")
            return
        }
        
        // ✅ **새 페이지 추가**: forward 스택 제거 후 추가 (복원 중에는 금지)
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🗑️ forward 스택 \(removedCount)개 제거")
        }
        
        let newRecord = PageRecord(url: url, title: title, navigationType: .normal)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1
        
        updateNavigationState()
        dbg("📄 새 페이지 추가: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] (총 \(pageHistory.count)개)")
        
        // 전역 히스토리 추가 (복원 중에는 금지)
        if !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }
    
    // MARK: - 🔧 **제목 덮어쓰기 문제 해결**: URL 검증 추가된 제목 업데이트
    
    func updateCurrentPageTitle(_ title: String) {
        guard currentPageIndex >= 0, 
              currentPageIndex < pageHistory.count,
              !title.isEmpty else { 
            return 
        }
        
        // 🔧 **핵심 수정**: StateModel의 현재 URL과 매칭되는 레코드만 업데이트
        if let stateModelURL = stateModel?.currentURL {
            let currentRecord = pageHistory[currentPageIndex]
            let currentNormalizedURL = currentRecord.normalizedURL()
            let stateNormalizedURL = PageRecord.normalizeURL(stateModelURL)
            
            // URL이 일치하지 않으면 제목 업데이트 거부
            if currentNormalizedURL != stateNormalizedURL {
                dbg("⚠️ 제목 업데이트 거부: 인덱스[\(currentPageIndex)] URL 불일치")
                dbg("   현재레코드: \(currentNormalizedURL)")
                dbg("   StateModel: \(stateNormalizedURL)")
                return
            }
        }
        
        var updatedRecord = pageHistory[currentPageIndex]
        updatedRecord.updateTitle(title)
        pageHistory[currentPageIndex] = updatedRecord
        dbg("📝 제목 업데이트: '\(title)' [인덱스: \(currentPageIndex)]")
    }
    
    // 🔧 **새로 추가**: URL 기반 제목 업데이트 메서드
    func updatePageTitle(for url: URL, title: String) {
        guard !title.isEmpty else { return }
        
        let normalizedURL = PageRecord.normalizeURL(url)
        
        // 해당 URL을 가진 가장 최근 레코드 찾기
        for i in stride(from: pageHistory.count - 1, through: 0, by: -1) {
            let record = pageHistory[i]
            if record.normalizedURL() == normalizedURL {
                var updatedRecord = record
                updatedRecord.updateTitle(title)
                pageHistory[i] = updatedRecord
                dbg("📝 URL 기반 제목 업데이트: '\(title)' [인덱스: \(i)] URL: \(url.absoluteString)")
                return
            }
        }
        
        dbg("⚠️ URL 기반 제목 업데이트 실패: 해당 URL 없음 - \(url.absoluteString)")
    }
    
    var currentPageRecord: PageRecord? {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return nil }
        return pageHistory[currentPageIndex]
    }
    
    // MARK: - 🎯 **큐 기반 네비게이션** (연타 레이스 방지)
    
    func navigateBack() -> PageRecord? {
        guard canGoBack, currentPageIndex > 0 else { 
            dbg("❌ navigateBack 실패: canGoBack=\(canGoBack), currentIndex=\(currentPageIndex)")
            return nil
        }
        
        let targetIndex = currentPageIndex - 1
        
        // 🎯 **큐 시스템에 추가**
        enqueueRestore(to: targetIndex)
        
        // 미리 레코드 반환 (UI 즉시 업데이트용)
        if let targetRecord = pageHistory[safe: targetIndex] {
            dbg("⬅️ 뒤로가기 큐 추가: '\(targetRecord.title)' [목표 인덱스: \(targetIndex)/\(pageHistory.count)]")
            return targetRecord
        }
        
        return nil
    }
    
    func navigateForward() -> PageRecord? {
        guard canGoForward, currentPageIndex < pageHistory.count - 1 else { 
            dbg("❌ navigateForward 실패: canGoForward=\(canGoForward), currentIndex=\(currentPageIndex)")
            return nil
        }
        
        let targetIndex = currentPageIndex + 1
        
        // 🎯 **큐 시스템에 추가**
        enqueueRestore(to: targetIndex)
        
        // 미리 레코드 반환 (UI 즉시 업데이트용)
        if let targetRecord = pageHistory[safe: targetIndex] {
            dbg("➡️ 앞으로가기 큐 추가: '\(targetRecord.title)' [목표 인덱스: \(targetIndex)/\(pageHistory.count)]")
            return targetRecord
        }
        
        return nil
    }
    
    func navigateToIndex(_ index: Int) -> PageRecord? {
        guard index >= 0, index < pageHistory.count else { 
            dbg("❌ navigateToIndex 실패: 잘못된 인덱스 \(index), 범위: 0..<\(pageHistory.count)")
            return nil 
        }
        
        // 🎯 **큐 시스템에 추가 (SPA pop 등에서 호출)**
        enqueueRestore(to: index)
        
        // 미리 레코드 반환
        if let targetRecord = pageHistory[safe: index] {
            dbg("🎯 인덱스 네비게이션 큐 추가: '\(targetRecord.title)' [목표 인덱스: \(index)/\(pageHistory.count)]")
            return targetRecord
        }
        
        return nil
    }
    
    // MARK: - 🏄‍♂️ **스와이프 제스처 처리** (과거 점프 완전 방지)
    
    func handleSwipeGestureDetected(to url: URL) {
        // ✅ **절대 원칙**: 히스토리에서 찾더라도 무조건 새 페이지로 추가
        // 세션 점프 완전 방지
        if !isRestoring {
            addNewPage(url: url, title: "")
            stateModel?.syncCurrentURL(url)
            dbg("👆 스와이프 - 새 페이지로 추가 (과거 점프 방지): \(url.absoluteString)")
        } else {
            dbg("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
        }
    }
    
    func findPageIndex(for url: URL) -> Int? {
        // ⚠️ **주의**: 이 함수는 미리보기/캐시용만 사용
        // 절대로 이 결과로 navigateToIndex 하지 말 것!
        let normalizedURL = PageRecord.normalizeURL(url)
        let matchingIndices = pageHistory.enumerated().compactMap { index, record in
            record.normalizedURL() == normalizedURL ? index : nil
        }
        return matchingIndices.last // 참고용만 - 점프 금지!
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
        
        updateNavigationState()
        dbg("🔄 세션 복원: \(pageHistory.count)개 페이지, 현재 인덱스 \(currentPageIndex)")
    }
    
    func finishSessionRestore() {
        isRestoringSession = false
    }
    
    // MARK: - 유틸리티
    
    func clearHistory() {
        Self.globalHistory.removeAll()
        Self.saveGlobalHistory()
        pageHistory.removeAll()
        currentPageIndex = -1
        updateNavigationState()
        dbg("🧹 전체 히스토리 삭제")
    }
    
    func resetNavigationFlags() {
        // 큐 초기화 및 복원 상태 리셋
        isRestoring = false
        expectedNormalizedURL = nil
        restoreQueue.removeAll()
        dbg("🔄 네비게이션 플래그 및 큐 전체 리셋")
    }
    
    // MARK: - 🚫 **네이티브 시스템 감지 및 차단**
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 사용자 클릭 감지만 하고, 네이티브 뒤로가기는 완전 차단
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted:
            dbg("👆 사용자 클릭 감지: \(navigationAction.request.url?.absoluteString ?? "nil")")
        case .backForward:
            dbg("🚫 네이티브 뒤로/앞으로 차단")
            // 🎯 **네이티브 히스토리 네비게이션을 차단 (큐 시스템 사용)**
            if let url = navigationAction.request.url {
                if let existingIndex = findPageIndex(for: url) {
                    dbg("🚫 네이티브 백포워드 차단 - 큐에 추가: \(existingIndex)")
                    enqueueRestore(to: existingIndex)
                } else {
                    dbg("🚫 네이티브 백포워드 차단 - 해당 URL 없음: \(url.absoluteString)")
                }
            }
            decisionHandler(.cancel)
            return
        default:
            break
        }
        
        decisionHandler(.allow)
    }
    
    // MARK: - WKNavigationDelegate (큐 기반 복원 분기 적용)
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stateModel?.handleLoadingStart()
        
        dbg("🚀 네비게이션 시작: \(webView.url?.absoluteString ?? "nil")")
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        stateModel?.handleLoadingFinish()
        let title = webView.title ?? webView.url?.host ?? "제목 없음"
        
        if let finalURL = webView.url {
            // 🎯 **핵심: didFinish 3가지 분기 처리 (직렬화 큐 적용)**
            if isRestoringSession {
                // ✅ **세션 복원 중**: URL 기반으로 안전하게 업데이트
                updatePageTitle(for: finalURL, title: title)
                finishSessionRestore()
                dbg("🔄 복원 완료: '\(title)'")
                
            } else if isRestoring {
                // ✅ **큐 기반 복원 중**: 절대 addNewPage 호출 안함
                
                if let expectedNormalized = expectedNormalizedURL {
                    let actualNormalized = PageRecord.normalizeURL(finalURL)
                    
                    if expectedNormalized == actualNormalized {
                        // URL이 예상과 일치 - 제목만 업데이트
                        updatePageTitle(for: finalURL, title: title)
                        dbg("🤫 큐 복원 완료 - 제목만 업데이트: '\(title)'")
                    } else {
                        // URL이 예상과 다름 - 현재 항목 치환
                        replaceCurrentPage(url: finalURL, title: title, siteType: "redirected")
                        dbg("🤫 큐 복원 중 URL변경 - 현재 항목 치환: '\(title)'")
                    }
                } else {
                    // 예상 URL이 없으면 제목만 업데이트
                    updatePageTitle(for: finalURL, title: title)
                    dbg("🤫 큐 복원 완료 - 예상 URL 없음, 제목만 업데이트: '\(title)'")
                }
                
                // 📸 현재 레코드 업데이트
                if let currentRecord = currentPageRecord {
                    var mutableRecord = currentRecord
                    mutableRecord.updateAccess()
                    pageHistory[currentPageIndex] = mutableRecord
                }
                
                // 큐 기반 복원 완료
                finishCurrentRestore()
                
            } else {
                // ✅ **일반적인 새 탐색**: 기존 로직대로 새 페이지 추가
                addNewPage(url: finalURL, title: title)
                stateModel?.syncCurrentURL(finalURL)
                dbg("🆕 페이지 기록: '\(title)' (총 \(pageHistory.count)개)")
            }
        }
        
        stateModel?.triggerNavigationFinished()
        dbg("✅ 네비게이션 완료")
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")
        
        // 복원 중이면 해당 복원 완료 처리
        if isRestoring {
            finishCurrentRestore()
            dbg("🤫 복원 실패 - 다음 큐 처리")
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")
        
        // 복원 중이면 해당 복원 완료 처리
        if isRestoring {
            finishCurrentRestore()
            dbg("🤫 복원 실패 - 다음 큐 처리")
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            stateModel?.notifyHTTPError(httpResponse.statusCode, url: navigationResponse.response.url?.absoluteString ?? "")
        }
        
        // 📁 **다운로드 처리 헬퍼 호출**
        shouldDownloadResponse(navigationResponse, decisionHandler: decisionHandler)
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        stateModel?.handleDidCommitNavigation(webView)
    }
    
    // 📁 **다운로드 델리게이트 연결 (헬퍼 호출)**
    @available(iOS 14.0, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        // 헬퍼 함수로 다운로드 델리게이트 연결
        handleDownloadStart(download: download, stateModel: stateModel)
    }
    
    @available(iOS 14.0, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        // 헬퍼 함수로 다운로드 델리게이트 연결
        handleDownloadStart(download: download, stateModel: stateModel)
    }
    
    // MARK: - 전역 히스토리 관리
    
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
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        let id = tabID?.uuidString.prefix(6) ?? "noTab"
        let navState = "B:\(canGoBack ? "✅" : "❌") F:\(canGoForward ? "✅" : "❌")"
        let historyCount = "[\(pageHistory.count)]"
        let flagState = isRestoring ? "[🔄RESTORE]" : ""
        let queueState = restoreQueue.isEmpty ? "" : "[Q:\(restoreQueue.count)]"
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(historyCount)\(flagState)\(queueState) \(msg)")
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
        case .home: return "house.fill"
        case .reload: return "arrow.clockwise"
        case .spaNavigation: return "sparkles"
        case .userClick: return "hand.tap.fill"
        default: return "circle"
        }
    }
    
    private var navigationTypeColor: Color {
        switch record.navigationType {
        case .home: return .green
        case .reload: return .orange
        case .spaNavigation: return .blue
        case .userClick: return .red
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
