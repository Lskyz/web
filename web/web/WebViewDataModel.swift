//  WebViewDataModel.swift
//  🎯 단순화된 정상 히스토리 시스템 + 직렬화 큐 복원 시스템
//  ✅ 리다이렉트 처리 단순화 - 체인 제거, 플래그만 사용
//  ✅ 검색 URL 특별 처리 제거 - 모든 URL 동일하게 처리
//  🔧 연타 레이스 방지 - enum 기반 직렬화 큐 시스템
//  🏠 루트 Replace 오염 방지 - JS 디바운싱 + Swift 홈클릭 구분

import Foundation
import SwiftUI
import WebKit

// MARK: - 복원 상태 enum
enum NavigationRestoreState {
    case idle                    // 유휴 상태
    case sessionRestoring       // 세션 복원 중
    case queueRestoring(Int)    // 큐 복원 중 (목표 인덱스)
    case preparing(Int)         // 복원 준비 중
    case completed              // 복원 완료
    case failed                 // 복원 실패

    var isActive: Bool {
        switch self {
        case .idle, .completed, .failed:
            return false
        default:
            return true
        }
    }

    var targetIndex: Int? {
        switch self {
        case .queueRestoring(let index), .preparing(let index):
            return index
        default:
            return nil
        }
    }
}

// MARK: - 네비게이션 타입 정의
enum NavigationType: String, Codable, CaseIterable {
    case normal = "normal"
    case reload = "reload"
    case home = "home"
    case spaNavigation = "spa"
    case userClick = "userClick"
}

// MARK: - 복원 큐 아이템
struct RestoreQueueItem {
    let targetIndex: Int
    let requestedAt: Date
    let id: UUID = UUID()
}

// MARK: - 페이지 기록 (단순화)
struct PageRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    let timestamp: Date
    var lastAccessed: Date
    var siteType: String?
    var navigationType: NavigationType = .normal
    // 🎯 리다이렉트 체인 제거 - 불필요한 복잡성 제거

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

    // 🔧 트래킹/광고 파라미터(무시 대상)
    private static let ignoredTrackingKeys: Set<String> = [
        "utm_source","utm_medium","utm_campaign","utm_term","utm_content","utm_id",
        "gclid","fbclid","igshid","msclkid","yclid","ref","ref_src","ref_url",
        "ved","ei","sclient","source","sourceid","gbv","lr","hl","biw","bih","dpr",
        "sca_esv","sca_upv","sxsrf","iflsig","uact","oq","aq","aqs","ie","oe"
    ]

    // 값 부재(nil)와 빈값("")을 구분 보존
    private static func normalizedQueryMapPreservingEmpty(_ comps: URLComponents?) -> [String: [String?]] {
        let items = comps?.queryItems ?? []
        var dict: [String: [String?]] = [:]
        for it in items {
            let name = it.name.lowercased()
            if ignoredTrackingKeys.contains(name) { continue }
            dict[name, default: []].append(it.value)
        }
        for (k, arr) in dict {
            dict[k] = arr.sorted { (a, b) in
                switch (a, b) {
                case let (la?, lb?): return la < lb
                case (nil, _?):      return true
                case (_?, nil):      return false
                default:             return false
                }
            }
        }
        return dict
    }

    // 경로 정규화
    private static func normalizedComponents(for url: URL) -> URLComponents? {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if comps?.scheme == "http" { comps?.scheme = "https" }
        if var path = comps?.path {
            while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
            if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            comps?.path = path
        }
        return comps
    }

    // ✅ 단일 정규화 함수 - 모든 URL 동일하게 처리
    static func normalizeURL(_ url: URL) -> String {
        guard var comps = normalizedComponents(for: url) else { return url.absoluteString }

        // 쿼리: 트래킹 키 제외하고 모든 키/값 보존
        let kept = normalizedQueryMapPreservingEmpty(comps)
        if kept.isEmpty {
            comps.queryItems = nil
        } else {
            var items: [URLQueryItem] = []
            for (k, arr) in kept.sorted(by: { $0.key < $1.key }) {
                for v in arr {
                    items.append(URLQueryItem(name: k, value: v))
                }
            }
            comps.queryItems = items
        }

        // 프래그먼트 제거
        comps.fragment = nil

        return comps.url?.absoluteString ?? url.absoluteString
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

    // 🎯 도메인 패밀리 확인 (www, m 등 서브도메인 무시)
    static func isSameDomainFamily(_ url1: URL, _ url2: URL) -> Bool {
        let host1 = normalizeDomainForComparison(url1.host)
        let host2 = normalizeDomainForComparison(url2.host)
        return host1 == host2 && !host1.isEmpty
    }
    
    private static func normalizeDomainForComparison(_ host: String?) -> String {
        guard let host = host?.lowercased() else { return "" }
        
        // www., m., mobile. 제거
        var normalized = host
        for prefix in ["www.", "m.", "mobile."] {
            if normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count))
                break
            }
        }
        return normalized
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

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 🎯 WebViewDataModel - 단순화된 버전
final class WebViewDataModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID?

    // ✅ 순수 히스토리 배열
    @Published private(set) var pageHistory: [PageRecord] = []
    @Published private(set) var currentPageIndex: Int = -1

    // ✅ 단순한 네비게이션 상태
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false

    // 🎯 enum 기반 복원 상태 관리
    @Published private(set) var restoreState: NavigationRestoreState = .idle
    private var restoreQueue: [RestoreQueueItem] = []
    private var expectedNormalizedURL: String? = nil

    // 🎯 단순화된 리다이렉트 감지
    private var lastNavigationURL: URL? = nil
    private var lastNavigationTime: Date = Date(timeIntervalSince1970: 0)
    private var isProcessingRedirect: Bool = false

    // 🎯 비루트 네비 직후 루트 pop 무시용
    private var lastProvisionalNavAt: Date?
    private var lastProvisionalURL: URL?
    private static let rootPopNavWindow: TimeInterval = 0.6

    // 큐 상태 조회용
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

    // MARK: - 네비게이션 상태 관리

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

    // MARK: - 🎯 단순화된 리다이렉트 처리

    private func shouldTreatAsRedirect(from previousURL: URL?, to newURL: URL) -> Bool {
        guard let prevURL = previousURL else { return false }
        
        let timeSinceLast = Date().timeIntervalSince(lastNavigationTime)
        
        // 1초 이내 + 같은 도메인 패밀리 = 리다이렉트
        let isQuickNavigation = timeSinceLast < 1.0
        let isSameDomainFamily = PageRecord.isSameDomainFamily(prevURL, newURL)
        
        return isQuickNavigation && isSameDomainFamily
    }

    // MARK: - enum 기반 복원 시스템

    func enqueueRestore(to targetIndex: Int) -> PageRecord? {
        guard targetIndex >= 0, targetIndex < pageHistory.count else {
            dbg("❌ 잘못된 복원 인덱스: \(targetIndex)")
            return nil
        }

        let item = RestoreQueueItem(targetIndex: targetIndex, requestedAt: Date())
        restoreQueue.append(item)
        dbg("📥 복원 큐 추가: 인덱스 \(targetIndex) (큐 길이: \(restoreQueue.count))")

        let targetRecord = pageHistory[targetIndex]

        if !restoreState.isActive {
            processNextRestore()
        }

        return targetRecord
    }

    private func processNextRestore() {
        guard !restoreQueue.isEmpty, !restoreState.isActive else { return }

        let item = restoreQueue.removeFirst()
        let targetIndex = item.targetIndex

        guard targetIndex >= 0, targetIndex < pageHistory.count else {
            dbg("❌ 잘못된 복원 인덱스: \(targetIndex), 다음 큐 처리")
            processNextRestore()
            return
        }

        restoreState = .preparing(targetIndex)
        currentPageIndex = targetIndex
        updateNavigationState()

        let targetRecord = pageHistory[targetIndex]
        expectedNormalizedURL = targetRecord.normalizedURL()

        dbg("🔄 복원 시작: 인덱스 \(targetIndex) → '\(targetRecord.title)' (큐 남은 건수: \(restoreQueue.count))")

        stateModel?.performQueuedRestore(to: targetRecord.url)
        restoreState = .queueRestoring(targetIndex)
    }

    func finishCurrentRestore() {
        guard restoreState.isActive else { return }

        restoreState = .completed
        expectedNormalizedURL = nil
        dbg("✅ 복원 완료, 다음 큐 처리 시작")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.restoreState = .idle
            self.processNextRestore()
        }
    }

    func failCurrentRestore() {
        guard restoreState.isActive else { return }

        restoreState = .failed
        expectedNormalizedURL = nil
        dbg("❌ 복원 실패, 다음 큐 처리")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.restoreState = .idle
            self.processNextRestore()
        }
    }

    func isHistoryNavigationActive() -> Bool {
        return restoreState.isActive
    }

    // MARK: - 네비게이션 메서드

    func navigateBack() -> PageRecord? {
        guard canGoBack, currentPageIndex > 0 else { 
            dbg("❌ navigateBack 실패: canGoBack=\(canGoBack), currentIndex=\(currentPageIndex)")
            return nil
        }

        let targetIndex = currentPageIndex - 1
        return enqueueRestore(to: targetIndex)
    }

    func navigateForward() -> PageRecord? {
        guard canGoForward, currentPageIndex < pageHistory.count - 1 else { 
            dbg("❌ navigateForward 실패: canGoForward=\(canGoForward), currentIndex=\(currentPageIndex)")
            return nil
        }

        let targetIndex = currentPageIndex + 1
        return enqueueRestore(to: targetIndex)
    }

    func navigateToIndex(_ index: Int) -> PageRecord? {
        guard index >= 0, index < pageHistory.count else { 
            dbg("❌ navigateToIndex 실패: 잘못된 인덱스 \(index), 범위: 0..<\(pageHistory.count)")
            return nil 
        }

        return enqueueRestore(to: index)
    }

    // MARK: - 🌐 SPA 네비게이션 처리

    func handleSPANavigation(type: String, url: URL, title: String, timestamp: Double, siteType: String = "unknown") {
        dbg("🌐 SPA \(type): \(siteType) | \(url.absoluteString)")

        // 로그인 관련은 무시
        if PageRecord.isLoginRelatedURL(url) {
            dbg("🔒 로그인 페이지 무시: \(url.absoluteString)")
            return
        }

        switch type {
        case "push":
            if isHistoryNavigationActive() {
                dbg("🤫 복원(활성) 중 SPA push 무시: \(url.absoluteString)")
                return
            }
            addNewPage(url: url, title: title)

        case "replace":
            let isRoot = (url.path == "/" || url.path.isEmpty)

            // 비루트 네비 직후 루트 replace 무시
            if isRoot, let t = lastProvisionalNavAt,
               Date().timeIntervalSince(t) < Self.rootPopNavWindow {
                dbg("🔕 replace 무시 - 비루트 네비 직후 전이성 루트 replace")
                return
            }

            if isRoot {
                if let cur = currentPageRecord, !(cur.url.path == "/" || cur.url.path.isEmpty) {
                    dbg("🏠 홈 이동으로 판단 → 새 페이지 추가")
                    if !isHistoryNavigationActive() {
                        addNewPage(url: url, title: title)
                    }
                } else {
                    dbg("🔕 루트 replace 무시(중복/전이성)")
                }
                return
            }

            replaceCurrentPage(url: url, title: title, siteType: siteType)

        case "pop":
            let isRoot = (url.path == "/" || url.path.isEmpty)

            // 비루트 네비 직후 루트 pop 무시
            if isRoot, let t = lastProvisionalNavAt,
               Date().timeIntervalSince(t) < Self.rootPopNavWindow,
               let u = lastProvisionalURL, !(u.path == "/" || u.path.isEmpty) {
                dbg("🔕 pop 무시 - 비루트 네비 직후의 전이성 루트 pop")
                return
            }

            // 루트 pop의 실제 복원
            if isRoot {
                if currentPageIndex > 0,
                   let idx = pageHistory[0..<currentPageIndex].lastIndex(where: { $0.url.path == "/" || $0.url.path.isEmpty }) {
                    dbg("🔄 pop - 과거 루트 기록 복원: index \(idx)")
                    _ = enqueueRestore(to: idx)
                } else {
                    dbg("🔕 pop 무시 - 과거 루트 기록 없음")
                }
                return
            }

            // 일반 URL pop 처리
            if let existingIndex = findPageIndex(for: url) {
                dbg("🔄 SPA pop - 기존 히스토리 항목 복원: \(existingIndex)")
                _ = enqueueRestore(to: existingIndex)
            } else {
                if !isHistoryNavigationActive() {
                    addNewPage(url: url, title: title)
                    dbg("🆕 SPA pop - 새 페이지 추가")
                } else {
                    dbg("🤫 복원 중 SPA pop 무시: \(url.absoluteString)")
                }
            }

        case "hash", "dom":
            if isHomepageURL(url) && !isHistoryNavigationActive() {
                addNewPage(url: url, title: title)
            } else {
                replaceCurrentPage(url: url, title: title, siteType: siteType)
            }

        case "title":
            updatePageTitle(for: url, title: title)

        default:
            dbg("🌐 알 수 없는 SPA 타입: \(type)")
        }

        // 복원 중에는 전역 히스토리 추가 금지
        if type != "title" && !isHistoryNavigationActive() && !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }

    // MARK: - SPA 훅 JavaScript 스크립트

    static func makeSPANavigationScript() -> WKUserScript {
        let scriptSource = """
        // 🌐 SPA 네비게이션 & DOM 변경 감지 훅 + 루트 Replace 디바운싱
        (function() {
            'use strict';

            console.log('🌐 SPA 네비게이션 훅 초기화');

            const originalPushState = history.pushState;
            const originalReplaceState = history.replaceState;

            // 루트 Replace 디바운싱 설정
            const SPA_BOOT_SUPPRESS_MS = 500;
            const ROOT_REPLACE_DELAY_MS = 250;
            const bootAt = Date.now();

            let rootReplaceTimer = null;
            let pendingRootPayload = null;
            let lastNonRootNavAt = 0;
            let lastHomeClickAt = 0;

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

            // 홈(로고) 클릭 식별 리스너
            document.addEventListener('click', (e) => {
                const a = e.target.closest && e.target.closest('a[href="/"], a[data-home], a[role="home"]');
                if (a) {
                    lastHomeClickAt = Date.now();
                    console.log('🏠 홈 클릭 감지:', a);
                }
            }, true);

            function detectSiteType(url) {
                const urlObj = new URL(url, window.location.origin);
                const host = urlObj.hostname.toLowerCase();
                const path = (urlObj.pathname + urlObj.search + urlObj.hash).toLowerCase();

                let pattern = 'unknown';

                // 패턴 감지 로직...
                if (path === '/' || path === '') {
                    pattern = 'root';
                }

                return `${host}_${pattern}`;
            }

            function postSPANav(message) {
                if (window.webkit?.messageHandlers?.spaNavigation) {
                    window.webkit.messageHandlers.spaNavigation.postMessage(message);
                    console.log(`🌐 SPA ${message.type}: ${message.siteType} | ${message.url}`);
                }
            }

            function sendOrDelay(type, url, title, state) {
                const now = Date.now();
                const u = new URL(url, window.location.origin);
                let siteType = detectSiteType(u.href);

                const isRoot = (u.pathname === '/' || u.pathname === '');

                const recentlyHomeClicked = (now - lastHomeClickAt) <= 600;
                if (recentlyHomeClicked) {
                    siteType = `${siteType}_homeclick`;
                }

                // 부트 중 루트 replace 무시
                if (type === 'replace' && isRoot && (now - bootAt) < SPA_BOOT_SUPPRESS_MS) {
                    console.log('⚠️ suppress root replace during boot:', u.href);
                    return;
                }

                if (!isRoot) {
                    lastNonRootNavAt = now;
                }

                // 루트 replace는 지연 전송(디바운스)
                if (type === 'replace' && isRoot && !recentlyHomeClicked) {
                    if (rootReplaceTimer) {
                        clearTimeout(rootReplaceTimer);
                        rootReplaceTimer = null;
                        pendingRootPayload = null;
                    }
                    pendingRootPayload = {
                        type, url: u.href, title: title || document.title, state, siteType
                    };
                    rootReplaceTimer = setTimeout(() => {
                        const dt = Date.now() - lastNonRootNavAt;
                        if (dt < ROOT_REPLACE_DELAY_MS) {
                            console.log('⚠️ drop transient root replace:', u.href);
                        } else {
                            postSPANav(pendingRootPayload);
                        }
                        rootReplaceTimer = null;
                        pendingRootPayload = null;
                    }, ROOT_REPLACE_DELAY_MS);
                    return;
                }

                // 그 외는 즉시 전송
                postSPANav({
                    type, url: u.href, title: title || document.title, state, siteType
                });
            }

            function notifyNavigation(type, url, title, state) {
                if (shouldExcludeFromHistory(url)) {
                    console.log(`🔒 히스토리 제외: ${url} (${type})`);
                    return;
                }
                sendOrDelay(type, url, title, state);
            }

            // History API 후킹
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

            // URL 변경 처리
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

            // popstate / hashchange 감지
            window.addEventListener('popstate', () => handleUrlChange('pop', window.location.href, document.title, history.state));
            window.addEventListener('hashchange', () => handleUrlChange('hash', window.location.href, document.title, history.state));

            // DOM 변경 감지
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

    private func isHomepageURL(_ url: URL) -> Bool {
        let path = url.path
        let query = url.query
        if let query = query, !query.isEmpty { return false }
        return path == "/" || path.isEmpty || path == "/main" || path == "/home"
    }

    private func replaceCurrentPage(url: URL, title: String, siteType: String) {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else {
            if !isHistoryNavigationActive() {
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

    // MARK: - 🎯 단순화된 새 페이지 추가

    func addNewPage(url: URL, title: String = "") {
        if PageRecord.isLoginRelatedURL(url) {
            dbg("🔒 로그인 페이지 히스토리 제외: \(url.absoluteString)")
            return
        }

        // 복원 중에는 차단
        if isHistoryNavigationActive() {
            dbg("🤫 복원 중 새 페이지 추가 차단: \(url.absoluteString)")
            return
        }

        // 🎯 단순화된 리다이렉트 체크
        if let currentRecord = currentPageRecord {
            // 리다이렉트인 경우 현재 페이지 URL만 업데이트
            if shouldTreatAsRedirect(from: currentRecord.url, to: url) {
                var updatedRecord = currentRecord
                updatedRecord.url = url
                updatedRecord.updateAccess()
                pageHistory[currentPageIndex] = updatedRecord
                
                dbg("🔄 리다이렉트 처리: \(currentRecord.url.host ?? "") → \(url.host ?? "")")
                stateModel?.syncCurrentURL(url)
                
                // 리다이렉트 처리 완료
                isProcessingRedirect = false
                lastNavigationURL = url
                lastNavigationTime = Date()
                return
            }
        }

        // 같은 페이지면 제목만 업데이트
        if let currentRecord = currentPageRecord {
            let currentNormalized = currentRecord.normalizedURL()
            let newNormalized = PageRecord.normalizeURL(url)

            if currentNormalized == newNormalized {
                updatePageTitle(for: url, title: title)
                dbg("🔄 같은 페이지 - 제목만 업데이트: '\(title)'")
                lastNavigationURL = url
                lastNavigationTime = Date()
                return
            }
        }

        // forward 스택 제거 후 새 페이지 추가
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🗑️ forward 스택 \(removedCount)개 제거")
        }

        let newRecord = PageRecord(url: url, title: title)
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1

        // 네비게이션 정보 업데이트
        lastNavigationURL = url
        lastNavigationTime = Date()

        updateNavigationState()
        dbg("📄 새 페이지 추가: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] (총 \(pageHistory.count)개)")

        // 전역 히스토리 추가
        if !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }

    // MARK: - 제목 업데이트

    func updateCurrentPageTitle(_ title: String) {
        guard currentPageIndex >= 0, 
              currentPageIndex < pageHistory.count,
              !title.isEmpty else { 
            return 
        }

        // URL 검증
        if let stateModelURL = stateModel?.currentURL {
            let currentRecord = pageHistory[currentPageIndex]
            let currentNormalizedURL = currentRecord.normalizedURL()
            let stateNormalizedURL = PageRecord.normalizeURL(stateModelURL)

            if currentNormalizedURL != stateNormalizedURL {
                dbg("⚠️ 제목 업데이트 거부: 인덱스[\(currentPageIndex)] URL 불일치")
                return
            }
        }

        var updatedRecord = pageHistory[currentPageIndex]
        updatedRecord.updateTitle(title)
        pageHistory[currentPageIndex] = updatedRecord
        dbg("📝 제목 업데이트: '\(title)' [인덱스: \(currentPageIndex)]")
    }

    func updatePageTitle(for url: URL, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = trimmed.isEmpty ? (url.host ?? "제목 없음") : trimmed
        let normalizedURL = PageRecord.normalizeURL(url)

        // 해당 URL을 가진 가장 최근 레코드 찾기
        for i in stride(from: pageHistory.count - 1, through: 0, by: -1) {
            let record = pageHistory[i]
            if record.normalizedURL() == normalizedURL {
                var updatedRecord = record
                updatedRecord.updateTitle(safeTitle)
                pageHistory[i] = updatedRecord
                dbg("📝 URL 기반 제목 업데이트: '\(safeTitle)' [인덱스: \(i)]")
                return
            }
        }

        dbg("⚠️ URL 기반 제목 업데이트 실패: 해당 URL 없음 - \(url.absoluteString)")
    }

    var currentPageRecord: PageRecord? {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return nil }
        return pageHistory[currentPageIndex]
    }

    func findPageIndex(for url: URL) -> Int? {
        let normalizedURL = PageRecord.normalizeURL(url)
        let matchingIndices = pageHistory.enumerated().compactMap { index, record in
            record.normalizedURL() == normalizedURL ? index : nil
        }
        return matchingIndices.last
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
        restoreState = .sessionRestoring

        pageHistory = session.pageRecords
        currentPageIndex = max(0, min(session.currentIndex, pageHistory.count - 1))

        updateNavigationState()
        dbg("🔄 세션 복원: \(pageHistory.count)개 페이지, 현재 인덱스 \(currentPageIndex)")
    }

    func finishSessionRestore() {
        restoreState = .idle
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
        restoreState = .idle
        expectedNormalizedURL = nil
        restoreQueue.removeAll()
        lastProvisionalNavAt = nil
        lastProvisionalURL = nil
        lastNavigationURL = nil
        lastNavigationTime = Date(timeIntervalSince1970: 0)
        isProcessingRedirect = false
        dbg("🔄 네비게이션 플래그 및 큐 전체 리셋")
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted:
            dbg("👆 사용자 클릭 감지: \(navigationAction.request.url?.absoluteString ?? "nil")")
            if let sm = stateModel {
                BFCacheTransitionSystem.shared.storeLeavingSnapshotIfPossible(webView: webView, stateModel: sm)
            }

        case .backForward:
            dbg("🚫 네이티브 뒤로/앞으로 차단")
            if let url = navigationAction.request.url {
                if let existingIndex = findPageIndex(for: url) {
                    dbg("🚫 네이티브 백포워드 차단 - 큐에 추가: \(existingIndex)")
                    _ = enqueueRestore(to: existingIndex)
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stateModel?.handleLoadingStart()

        dbg("🚀 네비게이션 시작: \(webView.url?.absoluteString ?? "nil")")

        // 비루트 네비 감지용 스탬프
        if let u = webView.url, !(u.path == "/" || u.path.isEmpty) {
            lastProvisionalNavAt = Date()
            lastProvisionalURL = u
        }

        // 🎯 단순화된 리다이렉트 준비
        if let url = webView.url {
            isProcessingRedirect = true
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        stateModel?.handleLoadingFinish()
        let title = webView.title ?? webView.url?.host ?? "제목 없음"

        if let finalURL = webView.url {
            // enum 기반 분기 처리
            switch restoreState {
            case .sessionRestoring:
                updatePageTitle(for: finalURL, title: title)
                finishSessionRestore()
                dbg("🔄 세션 복원 완료: '\(title)'")

            case .queueRestoring(_):
                if let expectedNormalized = expectedNormalizedURL {
                    let actualNormalized = PageRecord.normalizeURL(finalURL)
                    if expectedNormalized == actualNormalized {
                        updatePageTitle(for: finalURL, title: title)
                        dbg("🤫 큐 복원 완료 - 제목만 업데이트: '\(title)'")
                    } else {
                        replaceCurrentPage(url: finalURL, title: title, siteType: "redirected")
                        dbg("🤫 큐 복원 중 URL변경 - 현재 항목 치환: '\(title)'")
                    }
                } else {
                    updatePageTitle(for: finalURL, title: title)
                    dbg("🤫 큐 복원 완료 - 예상 URL 없음, 제목만 업데이트: '\(title)'")
                }

                if let currentRecord = currentPageRecord {
                    var mutableRecord = currentRecord
                    mutableRecord.updateAccess()
                    pageHistory[currentPageIndex] = mutableRecord
                }

                finishCurrentRestore()

            case .idle, .completed, .failed, .preparing:
                addNewPage(url: finalURL, title: title)
                stateModel?.syncCurrentURL(finalURL)
                dbg("🆕 페이지 기록: '\(title)' (총 \(pageHistory.count)개)")
            }
        }

        // BFCache 스냅샷 저장
        if let sm = stateModel {
            BFCacheTransitionSystem.shared.storeArrivalSnapshotIfPossible(webView: webView, stateModel: sm)
        }

        stateModel?.triggerNavigationFinished()
        
        // 리다이렉트 처리 완료
        isProcessingRedirect = false
        
        dbg("✅ 네비게이션 완료")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")

        isProcessingRedirect = false

        if restoreState.isActive {
            failCurrentRestore()
            dbg("🤫 복원 실패 - 다음 큐 처리")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")

        isProcessingRedirect = false

        if restoreState.isActive {
            failCurrentRestore()
            dbg("🤫 복원 실패 - 다음 큐 처리")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            stateModel?.notifyHTTPError(httpResponse.statusCode, url: navigationResponse.response.url?.absoluteString ?? "")
        }

        // 다운로드 처리
        shouldDownloadResponse(navigationResponse, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        stateModel?.handleDidCommitNavigation(webView)
    }

    // 다운로드 델리게이트
    @available(iOS 14.0, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        handleDownloadStart(download: download, stateModel: stateModel)
    }

    @available(iOS 14.0, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
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
        let stateFlag = restoreState.isActive ? "[\(restoreState)]" : ""
        let queueState = restoreQueue.isEmpty ? "" : "[Q:\(restoreQueue.count)]"
        let redirectState = isProcessingRedirect ? "[🔄]" : ""
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(historyCount)\(stateFlag)\(queueState)\(redirectState) \(msg)")
    }
}

// MARK: - 방문기록 페이지 뷰 (변경 없음)
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

// MARK: - 세션 히스토리 행 뷰 (단순화)
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
