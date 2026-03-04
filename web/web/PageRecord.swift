import Foundation
import WebKit

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
        if !title.isEmpty { self.title = title }
        lastAccessed = Date()
    }

    mutating func updateAccess() {
        lastAccessed = Date()
    }

    // MARK: - URL 정규화

    private static let ignoredTrackingKeys: Set<String> = [
        "utm_source","utm_medium","utm_campaign","utm_term","utm_content","utm_id",
        "gclid","fbclid","igshid","msclkid","yclid","ref","ref_src","ref_url",
        "ved","ei","sclient","source","sourceid","gbv","lr","hl","biw","bih","dpr"
    ]

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

    private static func normalizeMobileRedirect(_ url: URL, isDesktopMode: Bool = false) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return url }
        if isDesktopMode {
            if host.hasPrefix("m.") {
                components.host = "www.\(String(host.dropFirst(2)))"
                return components.url ?? url
            }
        } else {
            if host.hasPrefix("www.") {
                components.host = "m.\(String(host.dropFirst(4)))"
                return components.url ?? url
            }
        }
        return url
    }

    private static func normalizedComponents(for url: URL, isDesktopMode: Bool = false) -> URLComponents? {
        let normalizedURL = normalizeMobileRedirect(url, isDesktopMode: isDesktopMode)
        var comps = URLComponents(url: normalizedURL, resolvingAgainstBaseURL: false)
        if comps?.scheme == "http" { comps?.scheme = "https" }
        if var path = comps?.path {
            while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
            if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            comps?.path = path
        }
        return comps
    }

    static func logDiffIfSamePathButDifferentQuery(prev: URL, curr: URL) {
        guard let a = normalizedComponents(for: prev), let b = normalizedComponents(for: curr) else { return }
        if a.path == b.path {
            let qa = normalizedQueryMapPreservingEmpty(a)
            let qb = normalizedQueryMapPreservingEmpty(b)
            if qa != qb {
                let removed = Set(qa.keys).subtracting(qb.keys).sorted()
                let added   = Set(qb.keys).subtracting(qa.keys).sorted()
                TabPersistenceManager.debugMessages.append("✏️ 쿼리 차이: -\(removed) +\(added)")
            }
        }
    }

    static func normalizeURL(_ url: URL, isDesktopMode: Bool = false) -> String {
        if isSearchURL(url) { return normalizeSearchURL(url) }
        guard var comps = normalizedComponents(for: url, isDesktopMode: isDesktopMode) else { return url.absoluteString }
        let kept = normalizedQueryMapPreservingEmpty(comps)
        if kept.isEmpty {
            comps.queryItems = nil
        } else {
            var items: [URLQueryItem] = []
            for (k, arr) in kept.sorted(by: { $0.key < $1.key }) {
                for v in arr { items.append(URLQueryItem(name: k, value: v)) }
            }
            comps.queryItems = items
        }
        comps.fragment = nil
        return comps.url?.absoluteString ?? url.absoluteString
    }

    func normalizedURL(isDesktopMode: Bool = false) -> String {
        return Self.normalizeURL(self.url, isDesktopMode: isDesktopMode)
    }

    static func isSearchURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let searchHosts = ["google.com", "bing.com", "yahoo.com", "duckduckgo.com", "baidu.com"]
        guard searchHosts.contains(where: { host.contains($0) }) else { return false }
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return queryItems.contains { ["q", "query", "search", "p"].contains($0.name) }
    }

    static func normalizeSearchURL(_ url: URL) -> String {
        guard let host = url.host?.lowercased(),
              host.contains("google.com") || host.contains("bing.com") || host.contains("yahoo.com") else {
            return normalizeURL(url)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.scheme == "http" { components?.scheme = "https" }

        let essentialParams: [String]
        if host.contains("google.com") { essentialParams = ["q"] }
        else if host.contains("bing.com") { essentialParams = ["q"] }
        else if host.contains("yahoo.com") { essentialParams = ["p"] }
        else { essentialParams = ["q", "query", "search"] }

        let ignoredParams = Set([
            "sbfbu","pi","sei","sca_esv","ei","oq","gs_lp","sclient","source","sourceid",
            "ie","oe","hl","lr","cr","num","start","safe","filter","nfpr","spell","sa",
            "gbv","tbs","tbm","udm","uule","near","cad","rct","cd","ved","usg","biw",
            "bih","dpr","pf","pws","nobiw","uact","ijn"
        ])

        if let queryItems = components?.queryItems {
            let filtered = queryItems.filter { essentialParams.contains($0.name) && !ignoredParams.contains($0.name) }
            components?.queryItems = filtered.isEmpty ? nil : filtered.sorted { $0.name < $1.name }
        }
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    static func isLoginRelatedURL(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return ["login","signin","auth","oauth","sso","redirect","callback",
                "nid.naver.com","accounts.google.com","facebook.com/login","twitter.com/oauth",
                "returnurl=","redirect_uri=","continue=","state=","code="].contains { s.contains($0) }
    }
}

// MARK: - 세션
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

// MARK: - 전역 방문 기록
struct HistoryEntry: Identifiable, Hashable, Codable {
    var id = UUID()
    let url: URL
    let title: String
    let date: Date
}
