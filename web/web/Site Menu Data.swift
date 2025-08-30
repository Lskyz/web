//  WebViewDataModel.swift
//  🎯 단순화된 정상 히스토리 시스템 + 직렬화 큐 복원 시스템
//  ✅ 정상 기록, 정상 배열 - 예측 가능한 동작
//  🚫 네이티브 시스템 완전 차단 - 순수 커스텀만
//  🔧 연타 레이스 방지 - enum 기반 직렬화 큐 시스템
//  🔧 제목 덮어쓰기 문제 해결 - URL 검증 추가
//  📁 다운로드 델리게이트 코드 헬퍼로 이관 완료
//  🔍 구글 검색 SPA 문제 완전 해결 - 검색 쿼리 변경 감지 + 강화된 정규화
//  🆕 Google 검색 플로우 개선 - 메인페이지 검색 진행 중 pop 처리
//  🏠 루트 Replace 오염 방지 - JS 디바운싱 + Swift 홈클릭 구분
//  🔧 범용 URL 정규화 적용 - 트래킹만 제거, 의미 파라미터 보존
//  🎯 **BFCache 통합 - 스와이프 제스처 처리 제거**
//  🔄 **리다이렉트 중복 방지** - 동일 도메인 리다이렉트 감지 및 필터링

//

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
    case redirect = "redirect"  // 🔄 리다이렉트 타입 추가
}

// MARK: - 복원 큐 아이템
struct RestoreQueueItem {
    let targetIndex: Int
    let requestedAt: Date
    let id: UUID = UUID()
}

// MARK: - 🔄 리다이렉트 추적 구조체
private struct RedirectTracker {
    let originalURL: URL
    let timestamp: Date
    let redirectChain: [URL]
    
    init(originalURL: URL) {
        self.originalURL = originalURL
        self.timestamp = Date()
        self.redirectChain = [originalURL]
    }
    
    mutating func addRedirect(_ url: URL) -> RedirectTracker {
        var newTracker = self
        newTracker.redirectChain.append(url)
        return newTracker
    }
    
    // 리다이렉트 체인이 완료되었는지 확인 (3초 타임아웃)
    func isExpired() -> Bool {
        Date().timeIntervalSince(timestamp) > 3.0
    }
    
    // 같은 도메인군인지 확인
    func isSameDomainFamily(_ url: URL) -> Bool {
        let originalHost = normalizeHost(originalURL.host)
        let newHost = normalizeHost(url.host)
        return originalHost == newHost
    }
    
    private func normalizeHost(_ host: String?) -> String {
        guard let host = host?.lowercased() else { return "" }
        
        // www 제거
        let withoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        
        // m. 제거 (모바일 서브도메인)
        let withoutMobile = withoutWWW.hasPrefix("m.") ? String(withoutWWW.dropFirst(2)) : withoutWWW
        
        return withoutMobile
    }
    
    // 최종 URL (체인의 마지막)
    var finalURL: URL {
        return redirectChain.last ?? originalURL
    }
    
    // 리다이렉트인지 확인
    var isRedirect: Bool {
        return redirectChain.count > 1
    }
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
    var redirectChain: [URL]? // 🔄 리다이렉트 체인 저장

    init(url: URL, title: String = "", siteType: String? = nil, navigationType: NavigationType = .normal, redirectChain: [URL]? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title.isEmpty ? (url.host ?? "제목 없음") : title
        self.timestamp = Date()
        self.lastAccessed = Date()
        self.siteType = siteType
        self.navigationType = navigationType
        self.redirectChain = redirectChain
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

    // 🔧 트래킹/광고 파라미터(무시 대상) — 필요시 여기에만 추가
    private static let ignoredTrackingKeys: Set<String> = [
        "utm_source","utm_medium","utm_campaign","utm_term","utm_content","utm_id",
        "gclid","fbclid","igshid","msclkid","yclid","ref","ref_src","ref_url",
        "ved","ei","sclient","source","sourceid","gbv","lr","hl","biw","bih","dpr"
    ]

    // 값 부재(nil)와 빈값("")을 **구분 보존**하여 미세 차이도 잡는다.
    private static func normalizedQueryMapPreservingEmpty(_ comps: URLComponents?) -> [String: [String?]] {
        let items = comps?.queryItems ?? []
        var dict: [String: [String?]] = [:]
        for it in items {
            let name = it.name.lowercased()
            if ignoredTrackingKeys.contains(name) { continue }
            dict[name, default: []].append(it.value) // String? 그대로 보존(nil vs "")
        }
        // 정렬로 안정화(값 순서 변화에 영향받지 않도록)
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

    // 경로 정규화: 중복/트레일링 슬래시 정리, http→https 승격
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

    // 🔧 쿼리 차이 로깅 (디버깅용)
    static func logDiffIfSamePathButDifferentQuery(prev: URL, curr: URL) {
        guard let a = normalizedComponents(for: prev), let b = normalizedComponents(for: curr) else { return }
        let pa = a.path, pb = b.path
        if pa == pb {
            let qa = normalizedQueryMapPreservingEmpty(a)
            let qb = normalizedQueryMapPreservingEmpty(b)
            if qa != qb {
                let removed = Set(qa.keys).subtracting(qb.keys).sorted()
                let added   = Set(qb.keys).subtracting(qa.keys).sorted()
                let common  = Set(qa.keys).intersection(qb.keys).sorted()
                TabPersistenceManager.debugMessages.append("✏️ 쿼리 차이: -\(removed) +\(added)")
                for k in common where qa[k]! != qb[k]! {
                    TabPersistenceManager.debugMessages.append("✏️ 값 변경 [\(k)]: \(String(describing: qa[k]!)) -> \(String(describing: qb[k]!))")
                }
            }
        }
    }

    // ✅ 범용 정규화: **트래킹만 제거**, 그 외 파라미터는 전부 보존
    static func normalizeURL(_ url: URL) -> String {
        // 검색엔진은 기존 특화 정규화 유지
        if isSearchURL(url) {
            return normalizeSearchURL(url)
        }

        guard var comps = normalizedComponents(for: url) else { return url.absoluteString }

        // 쿼리: 트래킹 키 제외하고 **모든 키/값 보존**
        let kept = normalizedQueryMapPreservingEmpty(comps)
        if kept.isEmpty {
            comps.queryItems = nil
        } else {
            // String? 배열을 queryItems로 재구성
            var items: [URLQueryItem] = []
            for (k, arr) in kept.sorted(by: { $0.key < $1.key }) {
                for v in arr {
                    items.append(URLQueryItem(name: k, value: v)) // nil과 "" 구분 유지
                }
            }
            comps.queryItems = items
        }

        // 프래그먼트: 기본적으로 제거(필요 시 정책적으로 남길 수 있음)
        comps.fragment = nil

        return comps.url?.absoluteString ?? url.absoluteString
    }

    func normalizedURL() -> String {
        return Self.normalizeURL(self.url)
    }

    // 🔍 검색 URL인지 확인
    static func isSearchURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }

        let searchHosts = ["google.com", "bing.com", "yahoo.com", "duckduckgo.com", "baidu.com"]
        let isSearchHost = searchHosts.contains { host.contains($0) }

        if !isSearchHost { return false }

        // 검색 파라미터 확인
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return false }

        let searchParams = ["q", "query", "search", "p"]
        return queryItems.contains { searchParams.contains($0.name) }
    }

    // 🔍 **핵심 해결책 2: 강화된 구글 검색 URL 정규화** (임시 파라미터 적극 제거)
    static func normalizeSearchURL(_ url: URL) -> String {
        guard let host = url.host?.lowercased(),
              host.contains("google.com") || host.contains("bing.com") || host.contains("yahoo.com") else {
            return normalizeURL(url)
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if components?.scheme == "http" {
            components?.scheme = "https"
        }

        // 🚫 **강화된 파라미터 필터링** - 검색 엔진별 핵심 파라미터만 유지
        if let queryItems = components?.queryItems {
            let essentialParams: [String]

            if host.contains("google.com") {
                // 구글 검색에서 핵심적인 파라미터만 유지
                essentialParams = ["q"] // 검색 쿼리만 중요
            } else if host.contains("bing.com") {
                essentialParams = ["q"]
            } else if host.contains("yahoo.com") {
                essentialParams = ["p"]
            } else {
                essentialParams = ["q", "query", "search"]
            }

            // 🚫 **구글의 임시/추적 파라미터들 제거**
            let ignoredParams = Set([
                "sbfbu", "pi", "sei", "sca_esv", "ei", "oq", "gs_lp", "sclient",
                "source", "sourceid", "ie", "oe", "hl", "lr", "cr", "num", "start",
                "safe", "filter", "nfpr", "spell", "sa", "gbv", "tbs", "tbm",
                "udm", "uule", "near", "cad", "rct", "cd", "ved", "usg",
                "biw", "bih", "dpr", "pf", "pws", "nobiw", "uact", "ijn"
            ])

            let filteredItems = queryItems.filter { item in
                // 필수 파라미터이고 무시 목록에 없는 것만 유지
                essentialParams.contains(item.name) && !ignoredParams.contains(item.name)
            }

            if !filteredItems.isEmpty {
                components?.queryItems = filteredItems.sorted { $0.name < $1.name }
            } else {
                components?.query = nil
            }
        }

        // 🆕 **Hash fragment도 정규화** (Google SPA 파라미터 제거)
        if let fragment = components?.fragment {
            // Hash 내의 파라미터들도 정규화
            let hashIgnoredParams = Set(["sbfbu", "pi", "sei", "sca_esv", "ei"])
            let hashComponents = fragment.components(separatedBy: "&")
            let filteredHashComponents = hashComponents.filter { component in
                let paramName = component.components(separatedBy: "=").first ?? ""
                return !hashIgnoredParams.contains(paramName)
            }

            if filteredHashComponents.isEmpty || filteredHashComponents.joined().isEmpty {
                components?.fragment = nil
            } else {
                components?.fragment = filteredHashComponents.joined(separator: "&")
            }
        } else {
            components?.fragment = nil
        }

        return components?.url?.absoluteString ?? url.absoluteString
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

    // 🔄 **도메인 패밀리 확인** (리다이렉트 중복 방지용)
    static func isSameDomainFamily(_ url1: URL, _ url2: URL) -> Bool {
        let host1 = normalizeDomainForComparison(url1.host)
        let host2 = normalizeDomainForComparison(url2.host)
        return host1 == host2 && !host1.isEmpty
    }
    
    private static func normalizeDomainForComparison(_ host: String?) -> String {
        guard let host = host?.lowercased() else { return "" }
        
        // www. 제거
        var normalized = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        
        // m. 제거 (모바일 서브도메인)
        normalized = normalized.hasPrefix("m.") ? String(normalized.dropFirst(2)) : normalized
        
        // mobile. 제거
        normalized = normalized.hasPrefix("mobile.") ? String(normalized.dropFirst(7)) : normalized
        
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

// MARK: - 🎯 **WebViewDataModel - enum 기반 단순화된 큐 복원 시스템**
final class WebViewDataModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID?

    // ✅ 순수 히스토리 배열 (정상 기록, 정상 배열)
    @Published private(set) var pageHistory: [PageRecord] = []
    @Published private(set) var currentPageIndex: Int = -1

    // ✅ 단순한 네비게이션 상태
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false

    // 🎯 **핵심: enum 기반 복원 상태 관리**
    @Published private(set) var restoreState: NavigationRestoreState = .idle
    private var restoreQueue: [RestoreQueueItem] = []
    private var expectedNormalizedURL: String? = nil

    // 🔄 **리다이렉트 추적**
    private var currentRedirectTracker: RedirectTracker? = nil
    private var lastNavigationTime: Date = Date(timeIntervalSince1970: 0)
    private static let redirectDetectionWindow: TimeInterval = 3.0 // 3초 이내 연속 네비게이션은 리다이렉트로 간주

    // 🎯 **비루트 네비 직후 루트 pop 무시용**: provisional 네비게이션 추적
    private var lastProvisionalNavAt: Date?
    private var lastProvisionalURL: URL?
    private static let rootPopNavWindow: TimeInterval = 0.6 // 600ms

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

    // MARK: - 🔄 **리다이렉트 감지 및 처리**

    private func shouldTreatAsRedirect(from previousURL: URL?, to newURL: URL) -> Bool {
        guard let prevURL = previousURL else { return false }
        
        let timeSinceLast = Date().timeIntervalSince(lastNavigationTime)
        
        // 빠른 연속 네비게이션 + 같은 도메인 패밀리 = 리다이렉트
        let isQuickNavigation = timeSinceLast < Self.redirectDetectionWindow
        let isSameDomainFamily = PageRecord.isSameDomainFamily(prevURL, newURL)
        
        // 특별한 리다이렉트 패턴들
        let isKnownRedirectPattern = detectKnownRedirectPattern(from: prevURL, to: newURL)
        
        let shouldTreat = (isQuickNavigation && isSameDomainFamily) || isKnownRedirectPattern
        
        if shouldTreat {
            dbg("🔄 리다이렉트 감지: \(prevURL.absoluteString) → \(newURL.absoluteString)")
            dbg("   시간차: \(String(format: "%.2f", timeSinceLast))초, 도메인패밀리: \(isSameDomainFamily), 알려진패턴: \(isKnownRedirectPattern)")
        }
        
        return shouldTreat
    }

    private func detectKnownRedirectPattern(from oldURL: URL, to newURL: URL) -> Bool {
        let oldHost = oldURL.host?.lowercased() ?? ""
        let newHost = newURL.host?.lowercased() ?? ""
        
        // 네이버: www.naver.com → m.naver.com
        if oldHost.contains("naver.com") && newHost.contains("naver.com") {
            if (oldHost.hasPrefix("www.") && newHost.hasPrefix("m.")) ||
               (oldHost == "naver.com" && newHost == "m.naver.com") {
                return true
            }
        }
        
        // 다음: www.daum.net → m.daum.net
        if oldHost.contains("daum.net") && newHost.contains("daum.net") {
            if (oldHost.hasPrefix("www.") && newHost.hasPrefix("m.")) ||
               (oldHost == "daum.net" && newHost == "m.daum.net") {
                return true
            }
        }
        
        // 구글: www.google.com → m.google.com (모바일 검색)
        if oldHost.contains("google.com") && newHost.contains("google.com") {
            if oldHost.hasPrefix("www.") && newHost.hasPrefix("m.") {
                return true
            }
        }
        
        // 일반적인 www → mobile 패턴
        if oldHost.contains("www.") && (newHost.contains("m.") || newHost.contains("mobile.")) {
            let baseDomain1 = oldHost.replacingOccurrences(of: "www.", with: "")
            let baseDomain2 = newHost.replacingOccurrences(of: "m.", with: "").replacingOccurrences(of: "mobile.", with: "")
            return baseDomain1 == baseDomain2
        }
        
        return false
    }

    private func handleRedirect(from originalURL: URL, to finalURL: URL) {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else {
            // 히스토리가 비어있으면 정상적으로 새 페이지 추가
            addNewPageInternal(url: finalURL, title: "", navigationType: .redirect, redirectChain: [originalURL, finalURL])
            return
        }
        
        var currentRecord = pageHistory[currentPageIndex]
        
        // 현재 레코드가 리다이렉트의 원본 URL과 일치하는지 확인
        if PageRecord.isSameDomainFamily(currentRecord.url, originalURL) {
            // 기존 레코드를 최종 URL로 업데이트
            currentRecord.url = finalURL
            currentRecord.navigationType = .redirect
            currentRecord.redirectChain = [originalURL, finalURL]
            currentRecord.updateAccess()
            
            pageHistory[currentPageIndex] = currentRecord
            
            dbg("🔄 리다이렉트 처리: 기존 레코드 업데이트")
            dbg("   원본: \(originalURL.absoluteString)")
            dbg("   최종: \(finalURL.absoluteString)")
            
            // StateModel URL 동기화
            stateModel?.syncCurrentURL(finalURL)
        } else {
            // 일치하지 않으면 새 페이지로 추가 (안전장치)
            addNewPageInternal(url: finalURL, title: "", navigationType: .redirect, redirectChain: [originalURL, finalURL])
        }
    }

    // MARK: - 🎯 **enum 기반 복원 시스템 관리 (모든 로직을 DataModel로 통합)**

    func enqueueRestore(to targetIndex: Int) -> PageRecord? {
        guard targetIndex >= 0, targetIndex < pageHistory.count else {
            dbg("❌ 잘못된 복원 인덱스: \(targetIndex)")
            return nil
        }

        let item = RestoreQueueItem(targetIndex: targetIndex, requestedAt: Date())
        restoreQueue.append(item)
        dbg("📥 복원 큐 추가: 인덱스 \(targetIndex) (큐 길이: \(restoreQueue.count))")

        // 미리 타겟 레코드 반환 (UI 즉시 업데이트용)
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

        // StateModel에 복원 요청
        stateModel?.performQueuedRestore(to: targetRecord.url)

        // 복원 중 상태로 전환
        restoreState = .queueRestoring(targetIndex)
    }

    func finishCurrentRestore() {
        guard restoreState.isActive else { return }

        restoreState = .completed
        expectedNormalizedURL = nil
        dbg("✅ 복원 완료, 다음 큐 처리 시작")

        // 상태 리셋 후 다음 큐 처리
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

        // 상태 리셋 후 다음 큐 처리
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.restoreState = .idle
            self.processNextRestore()
        }
    }

    func isHistoryNavigationActive() -> Bool {
        return restoreState.isActive
    }

    // MARK: - 🎯 **단순화된 네비게이션 메서드**

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

    // MARK: - 🔍 **핵심 해결책 3: 검색 페이지 전용 인덱스 찾기**

    private func findSearchPageIndex(for url: URL) -> Int? {
        guard PageRecord.isSearchURL(url) else { return nil }

        let searchURL = PageRecord.normalizeSearchURL(url)

        for (index, record) in pageHistory.enumerated().reversed() {
            // 🚫 **현재 페이지는 제외** (SPA pop에서 현재 페이지로 돌아가는 경우 방지)
            if index == currentPageIndex {
                continue
            }

            if PageRecord.isSearchURL(record.url) {
                let recordSearchURL = PageRecord.normalizeSearchURL(record.url)
                if recordSearchURL == searchURL {
                    return index
                }
            }
        }

        return nil
    }

    // MARK: - 🌐 **SPA 네비게이션 처리** (🏠 루트 Replace 오염 방지 적용)

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

            // 🎯 **비루트 네비 직후(600ms) 들어온 루트 replace는 전이성으로 보고 무시**
            if isRoot, let t = lastProvisionalNavAt,
               Date().timeIntervalSince(t) < Self.rootPopNavWindow {
                dbg("🔕 replace 무시 - 비루트 네비 직후 전이성 루트 replace")
                return
            }

            if isRoot {
                // 진짜 홈 이동만 새 페이지로 반영하고, 그 외 루트 replace는 히스토리 오염 방지 목적 무시
                if let cur = currentPageRecord, !(cur.url.path == "/" || cur.url.path.isEmpty) {
                    dbg("🏠 홈 이동으로 판단 → 새 페이지 추가")
                    if !isHistoryNavigationActive() {
                        addNewPage(url: url, title: title)
                    } else {
                        dbg("🤫 복원 중 홈 이동 무시")
                    }
                } else {
                    dbg("🔕 루트 replace 무시(중복/전이성)")
                }
                return
            }

            // 정상 replace
            replaceCurrentPage(url: url, title: title, siteType: siteType)

        case "pop":
            let isRoot = (url.path == "/" || url.path.isEmpty)

            // 🎯 **핵심 가드: 비루트 네비 직후 루트 pop 무시**
            if isRoot, let t = lastProvisionalNavAt,
               Date().timeIntervalSince(t) < Self.rootPopNavWindow,
               let u = lastProvisionalURL, !(u.path == "/" || u.path.isEmpty) {
                // 검색/상세로 가는 비루트 네비를 막 시작했는데, 중간에 튄 루트 pop은 잡음으로 간주
                dbg("🔕 pop 무시 - 비루트 네비 직후의 전이성 루트 pop (\(String(format: "%.3f", Date().timeIntervalSince(t)))s) from \(u.absoluteString)")
                return
            }

            // 🎯 **루트 pop의 실제 복원**: 과거에 루트가 있을 때만
            if isRoot {
                if currentPageIndex > 0,
                   let idx = pageHistory[0..<currentPageIndex].lastIndex(where: { $0.url.path == "/" || $0.url.path.isEmpty }) {
                    dbg("🔄 pop - 과거 루트 기록 복원: index \(idx)")
                    _ = enqueueRestore(to: idx)
                } else {
                    dbg("🔕 pop 무시 - 과거 루트 기록 없음(노이즈 루트 pop)")
                }
                return
            }

            // 🔍 **검색 URL 특수 처리** (구글 검색어 복귀 방지)
            if PageRecord.isSearchURL(url) {
                dbg("🔍 SPA pop - 검색 URL 감지: \(url.absoluteString)")

                // 검색 URL의 경우 쿼리 파라미터 변경을 확인
                if let existingIndex = findSearchPageIndex(for: url) {
                    let existingRecord = pageHistory[existingIndex]
                    let existingSearchURL = PageRecord.normalizeSearchURL(existingRecord.url)
                    let newSearchURL = PageRecord.normalizeSearchURL(url)

                    if existingSearchURL == newSearchURL {
                        // 검색 쿼리가 동일하면 복원
                        dbg("🔄 SPA pop - 동일한 검색 쿼리, 복원: \(existingIndex)")
                        dbg("   기존: \(existingSearchURL)")
                        dbg("   신규: \(newSearchURL)")
                        _ = enqueueRestore(to: existingIndex)
                    } else {
                        // 검색 쿼리가 다르면 새 페이지 추가
                        dbg("🔍 SPA pop - 검색 쿼리 변경 감지, 새 페이지 추가")
                        dbg("   기존: \(existingSearchURL)")
                        dbg("   신규: \(newSearchURL)")
                        if !isHistoryNavigationActive() {
                            addNewPage(url: url, title: title)
                        } else {
                            dbg("🤫 복원 중 검색 쿼리 변경 무시: \(url.absoluteString)")
                        }
                    }
                } else {
                    // 기존 검색 페이지가 없으면 새 페이지 추가
                    dbg("🔍 SPA pop - 새 검색 페이지 추가: \(url.absoluteString)")
                    if !isHistoryNavigationActive() {
                        addNewPage(url: url, title: title)
                    } else {
                        dbg("🤫 복원 중 새 검색 페이지 무시: \(url.absoluteString)")
                    }
                }
            } else {
                // **일반 URL의 경우**
                if let existingIndex = findPageIndex(for: url) {
                    dbg("🔄 SPA pop - 기존 히스토리 항목 복원: \(existingIndex)")
                    _ = enqueueRestore(to: existingIndex)
                } else {
                    // 기존 항목이 없으면 새 페이지 추가 (복원 중이 아닐 때만)
                    if !isHistoryNavigationActive() {
                        addNewPage(url: url, title: title)
                        dbg("🆕 SPA pop - 새 페이지 추가")
                    } else {
                        dbg("🤫 복원 중 SPA pop 무시: \(url.absoluteString)")
                    }
                }
            }

        case "hash", "dom":
            // 홈페이지면 새 페이지, 아니면 현재 페이지 교체
            if isHomepageURL(url) && !isHistoryNavigationActive() {
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
        if type != "title" && !isHistoryNavigationActive() && !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }

    // MARK: - 🌐 **SPA 훅 JavaScript 스크립트** (🏠 루트 Replace 디바운싱 적용)

    static func makeSPANavigationScript() -> WKUserScript {
        let scriptSource = """
        // 🌐 완전형 SPA 네비게이션 & DOM 변경 감지 훅 + 🏠 루트 Replace 디바운싱
        (function() {
            'use strict';

            console.log('🌐 SPA 네비게이션 훅 초기화');

            const originalPushState = history.pushState;
            const originalReplaceState = history.replaceState;

            // 🏠 **루트 Replace 디바운싱 설정**
            const SPA_BOOT_SUPPRESS_MS = 500;  // 초기 부트 중 루트 replace 무시
            const ROOT_REPLACE_DELAY_MS = 250; // 루트 replace 지연 후 전송
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

            // 🏠 **홈(로고) 클릭 식별 리스너**
            document.addEventListener('click', (e) => {
                const a = e.target.closest && e.target.closest('a[href="/"], a[data-home], a[role="home"]');
                if (a) {
                    lastHomeClickAt = Date.now();
                    console.log('🏠 홈 클릭 감지:', a);
                }
            }, true);

            // ===== 범용 커뮤니티 패턴 매칭 =====
            function detectSiteType(url) {
                const urlObj = new URL(url, window.location.origin);
                const host = urlObj.hostname.toLowerCase();
                const path = (urlObj.pathname + urlObj.search + urlObj.hash).toLowerCase();

                let pattern = 'unknown';

                // 🔍 검색 엔진 감지
                if (host.includes('google.com') && (path.includes('/search') || urlObj.searchParams.has('q'))) {
                    pattern = 'google_search';
                } else if (host.includes('bing.com') && (path.includes('/search') || urlObj.searchParams.has('q'))) {
                    pattern = 'bing_search';
                } else if (host.includes('yahoo.com') && (path.includes('/search') || urlObj.searchParams.has('p'))) {
                    pattern = 'yahoo_search';
                }
                // 숫자형 단일 경로
                else if (path.match(/^\\/\\d+$/)) {
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

            // 🏠 **개선된 네비게이션 전송 함수** (루트 replace 디바운싱)
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

                // 🏠 홈 클릭 힌트 부여
                const recentlyHomeClicked = (now - lastHomeClickAt) <= 600;
                if (recentlyHomeClicked) {
                    siteType = `${siteType}_homeclick`;
                }

                // 🏠 **부트 중 루트 replace 무시**
                if (type === 'replace' && isRoot && (now - bootAt) < SPA_BOOT_SUPPRESS_MS) {
                    console.log('⚠️ suppress root replace during boot:', u.href);
                    return;
                }

                // 비루트 네비 시간 갱신
                if (!isRoot) {
                    lastNonRootNavAt = now;
                }

                // 🏠 **루트 replace는 지연 전송(디바운스)**
                if (type === 'replace' && isRoot && !recentlyHomeClicked) {
                    // 이전 대기 취소
                    if (rootReplaceTimer) {
                        clearTimeout(rootReplaceTimer);
                        rootReplaceTimer = null;
                        pendingRootPayload = null;
                    }
                    // 지연 예약
                    pendingRootPayload = {
                        type, url: u.href, title: title || document.title, state, siteType
                    };
                    rootReplaceTimer = setTimeout(() => {
                        // 지연 중에 비루트 네비가 발생했다면 폐기
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

                // 🏠 **기존 notifyNavigation 대신 sendOrDelay 사용**
                sendOrDelay(type, url, title, state);
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

            console.log('✅ SPA 네비게이션 훅 설정 완료 (루트 Replace 디바운싱 적용)');
        })();
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
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

    // MARK: - 🎯 **핵심: 단순한 새 페이지 추가 로직 (범용 정규화 적용) + 리다이렉트 중복 방지**

    func addNewPage(url: URL, title: String = "") {
        addNewPageInternal(url: url, title: title, navigationType: .normal, redirectChain: nil)
    }

    private func addNewPageInternal(url: URL, title: String = "", navigationType: NavigationType = .normal, redirectChain: [URL]? = nil) {
        if PageRecord.isLoginRelatedURL(url) {
            dbg("🔒 로그인 페이지 히스토리 제외: \(url.absoluteString)")
            return
        }

        // ✅ 복원 중에는 차단
        if isHistoryNavigationActive() {
            dbg("🤫 복원 중 새 페이지 추가 차단: \(url.absoluteString)")
            return
        }

        // 🔄 **리다이렉트 중복 방지 검사**
        if let currentRecord = currentPageRecord, navigationType != .redirect {
            // 현재 페이지와의 리다이렉트 관계 확인
            if shouldTreatAsRedirect(from: currentRecord.url, to: url) {
                handleRedirect(from: currentRecord.url, to: url)
                return
            }
        }

        // ✅ **핵심 로직 (범용 정규화 적용)**: 현재 페이지와 같으면 제목만 업데이트
        if let currentRecord = currentPageRecord {
            let currentNormalized = currentRecord.normalizedURL()
            let newNormalized = PageRecord.normalizeURL(url)

            // 🔧 쿼리 차이 로깅 (디버깅용)
            PageRecord.logDiffIfSamePathButDifferentQuery(prev: currentRecord.url, curr: url)

            if currentNormalized == newNormalized {
                updatePageTitle(for: url, title: title)
                dbg("🔄 같은 페이지 - 제목만 업데이트: '\(title)'")
                
                // 네비게이션 시간 업데이트 (리다이렉트 감지를 위해)
                lastNavigationTime = Date()
                return
            } else {
                dbg("🆕 URL 차이 감지 - 새 페이지 추가")
                dbg("   현재: \(currentNormalized)")
                dbg("   신규: \(newNormalized)")
            }
        }

        // ✅ **새 페이지 추가**: forward 스택 제거 후 추가
        if currentPageIndex >= 0 && currentPageIndex < pageHistory.count - 1 {
            let removedCount = pageHistory.count - currentPageIndex - 1
            pageHistory.removeSubrange((currentPageIndex + 1)...)
            dbg("🗑️ forward 스택 \(removedCount)개 제거")
        }

        let newRecord = PageRecord(
            url: url, 
            title: title, 
            navigationType: navigationType,
            redirectChain: redirectChain
        )
        pageHistory.append(newRecord)
        currentPageIndex = pageHistory.count - 1

        // 네비게이션 시간 업데이트 (리다이렉트 감지용)
        lastNavigationTime = Date()

        updateNavigationState()
        dbg("📄 새 페이지 추가: '\(newRecord.title)' [ID: \(String(newRecord.id.uuidString.prefix(8)))] (총 \(pageHistory.count)개)")
        
        if let chain = redirectChain, chain.count > 1 {
            dbg("🔄 리다이렉트 체인: \(chain.map { $0.absoluteString }.joined(separator: " → "))")
        }

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

    // 🔧 **개선된 제목 업데이트**: 공백 제목 보정 추가
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
                dbg("📝 URL 기반 제목 업데이트(보정): '\(safeTitle)' [인덱스: \(i)] URL: \(url.absoluteString)")
                return
            }
        }

        dbg("⚠️ URL 기반 제목 업데이트 실패: 해당 URL 없음 - \(url.absoluteString)")
    }

    var currentPageRecord: PageRecord? {
        guard currentPageIndex >= 0, currentPageIndex < pageHistory.count else { return nil }
        return pageHistory[currentPageIndex]
    }

    // 🎯 **BFCache 통합 - handleSwipeGestureDetected 제거**
    // 모든 스와이프 제스처 처리는 BFCacheTransitionSystem으로 이관

    func findPageIndex(for url: URL) -> Int? {
        // ⚠️ **주의**: 이 함수는 미리보기용만 사용
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
        currentRedirectTracker = nil
        lastNavigationTime = Date(timeIntervalSince1970: 0)
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

    // MARK: - WKNavigationDelegate (enum 기반 복원 분기 적용 + 리다이렉트 감지)

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stateModel?.handleLoadingStart()

        dbg("🚀 네비게이션 시작: \(webView.url?.absoluteString ?? "nil")")

        // 🎯 **비루트 네비 감지용 스탬프**
        if let u = webView.url, !(u.path == "/" || u.path.isEmpty) {
            lastProvisionalNavAt = Date()
            lastProvisionalURL = u
        }

        // 🔄 **리다이렉트 추적 시작**
        if let url = webView.url {
            if let tracker = currentRedirectTracker {
                if tracker.isExpired() {
                    // 기존 추적 만료 - 새로운 추적 시작
                    currentRedirectTracker = RedirectTracker(originalURL: url)
                    dbg("🔄 리다이렉트 추적 만료 후 새 시작: \(url.absoluteString)")
                } else if tracker.isSameDomainFamily(url) {
                    // 같은 도메인 패밀리 - 체인에 추가
                    currentRedirectTracker = tracker.addRedirect(url)
                    dbg("🔄 리다이렉트 체인 추가: \(url.absoluteString) (체인 길이: \(currentRedirectTracker?.redirectChain.count ?? 0))")
                } else {
                    // 다른 도메인 - 새로운 추적 시작
                    currentRedirectTracker = RedirectTracker(originalURL: url)
                    dbg("🔄 도메인 변경으로 새 리다이렉트 추적 시작: \(url.absoluteString)")
                }
            } else {
                // 첫 번째 추적 시작
                currentRedirectTracker = RedirectTracker(originalURL: url)
                dbg("🔄 첫 번째 리다이렉트 추적 시작: \(url.absoluteString)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        stateModel?.handleLoadingFinish()
        let title = webView.title ?? webView.url?.host ?? "제목 없음"

        if let finalURL = webView.url {
            // 🔄 **리다이렉트 처리 확인**
            var shouldHandleAsRedirect = false
            var redirectChain: [URL]? = nil
            
            if let tracker = currentRedirectTracker {
                if tracker.isRedirect && tracker.isSameDomainFamily(finalURL) {
                    // 리다이렉트가 완료됨
                    shouldHandleAsRedirect = true
                    redirectChain = tracker.redirectChain + [finalURL]
                    dbg("🔄 리다이렉트 완료 감지: \(tracker.originalURL.absoluteString) → \(finalURL.absoluteString)")
                }
                // 추적 완료
                currentRedirectTracker = nil
            }

            // 🎯 **핵심: didFinish enum 기반 분기 처리**
            switch restoreState {
            case .sessionRestoring:
                // ✅ **세션 복원 중**: URL 기반으로 안전하게 업데이트
                updatePageTitle(for: finalURL, title: title)
                finishSessionRestore()
                dbg("🔄 세션 복원 완료: '\(title)'")

            case .queueRestoring(_):
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

            case .idle, .completed, .failed, .preparing:
                // ✅ **일반적인 새 탐색**: 리다이렉트 처리 포함
                if shouldHandleAsRedirect {
                    // 🔄 리다이렉트로 처리
                    if let chain = redirectChain {
                        handleRedirect(from: chain.first!, to: finalURL)
                    }
                } else {
                    // 일반 새 페이지 추가
                    addNewPageInternal(
                        url: finalURL, 
                        title: title, 
                        navigationType: .normal,
                        redirectChain: redirectChain
                    )
                    stateModel?.syncCurrentURL(finalURL)
                    dbg("🆕 페이지 기록: '\(title)' (총 \(pageHistory.count)개)")
                }
            }
        }

        stateModel?.triggerNavigationFinished()
        dbg("✅ 네비게이션 완료")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")

        // 🔄 리다이렉트 추적 리셋
        currentRedirectTracker = nil

        // 복원 중이면 해당 복원 실패 처리
        if restoreState.isActive {
            failCurrentRestore()
            dbg("🤫 복원 실패 - 다음 큐 처리")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")

        // 🔄 리다이렉트 추적 리셋
        currentRedirectTracker = nil

        // 복원 중이면 해당 복원 실패 처리
        if restoreState.isActive {
            failCurrentRestore()
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
        let stateFlag = restoreState.isActive ? "[\(restoreState)]" : ""
        let queueState = restoreQueue.isEmpty ? "" : "[Q:\(restoreQueue.count)]"
        let redirectState = currentRedirectTracker != nil ? "[🔄]" : ""
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(navState)]\(historyCount)\(stateFlag)\(queueState)\(redirectState) \(msg)")
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

// MARK: - 세션 히스토리 행 뷰 (🔄 리다이렉트 표시 추가)
struct SessionHistoryRowView: View {
    let record: PageRecord
    let isCurrent: Bool

    private var navigationTypeIcon: String {
        switch record.navigationType {
        case .home: return "house.fill"
        case .reload: return "arrow.clockwise"
        case .spaNavigation: return "sparkles"
        case .userClick: return "hand.tap.fill"
        case .redirect: return "arrow.triangle.turn.up.right.diamond.fill" // 🔄 리다이렉트 아이콘
        default: return "circle"
        }
    }

    private var navigationTypeColor: Color {
        switch record.navigationType {
        case .home: return .green
        case .reload: return .orange
        case .spaNavigation: return .blue
        case .userClick: return .red
        case .redirect: return .purple // 🔄 리다이렉트 색상
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

                // 🔄 리다이렉트 체인 표시
                if let redirectChain = record.redirectChain, redirectChain.count > 1 {
                    Text("🔄 \(redirectChain.count)단계 리다이렉트: \(redirectChain.first?.host ?? "?") → \(redirectChain.last?.host ?? "?")")
                        .font(.caption2)
                        .foregroundColor(.purple)
                        .padding(.top, 2)
                }

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
