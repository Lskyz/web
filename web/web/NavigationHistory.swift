import Foundation
import WebKit

// MARK: - 히스토리 메타데이터 관리
extension WebViewDataModel {

    // 현재 페이지 레코드 (WebKit backForwardList 기준)
    var currentPageRecord: PageRecord? {
        guard let url = stateModel?.webView?.backForwardList.currentItem?.url else { return nil }
        return findMetadataRecord(for: url)
    }

    // URL로 메타데이터 레코드 조회
    func findMetadataRecord(for url: URL) -> PageRecord? {
        let isDesktopMode = stateModel?.isDesktopMode ?? false
        let normalized = PageRecord.normalizeURL(url, isDesktopMode: isDesktopMode)
        return pageHistory.last { $0.normalizedURL(isDesktopMode: isDesktopMode) == normalized }
    }

    // 메타데이터 추가 (내비게이션 로직 없음, 기록 전용)
    func addMetadataEntry(url: URL, title: String) {
        guard !PageRecord.isLoginRelatedURL(url) else { return }

        let isDesktopMode = stateModel?.isDesktopMode ?? false
        let normalized = PageRecord.normalizeURL(url, isDesktopMode: isDesktopMode)

        if let idx = pageHistory.lastIndex(where: {
            $0.normalizedURL(isDesktopMode: isDesktopMode) == normalized
        }) {
            var record = pageHistory[idx]
            record.updateTitle(title)
            pageHistory[idx] = record
            dbg("🔄 메타데이터 갱신: '\(title)'")
        } else {
            let record = PageRecord(url: url, title: title)
            pageHistory.append(record)
            dbg("📄 메타데이터 추가: '\(title)' (총 \(pageHistory.count)개)")
        }

        // 전역 히스토리
        if !Self.globalHistory.contains(where: { $0.url == url }) {
            Self.globalHistory.append(HistoryEntry(url: url, title: title, date: Date()))
        }
    }

    // 현재 페이지 메타데이터 교체 (SPA replaceState용)
    func replaceCurrentMetadata(url: URL, title: String, siteType: String) {
        let isDesktopMode = stateModel?.isDesktopMode ?? false
        let normalized = PageRecord.normalizeURL(url, isDesktopMode: isDesktopMode)

        if let idx = pageHistory.lastIndex(where: {
            $0.normalizedURL(isDesktopMode: isDesktopMode) == normalized
        }) {
            var record = pageHistory[idx]
            record.url = url
            record.updateTitle(title)
            record.siteType = siteType
            pageHistory[idx] = record
        } else {
            addMetadataEntry(url: url, title: title)
        }
        dbg("🔄 SPA Replace 메타데이터 갱신")
    }

    func updateCurrentPageTitle(_ title: String) {
        guard let url = stateModel?.webView?.backForwardList.currentItem?.url else { return }
        updatePageTitle(for: url, title: title)
    }

    func updatePageTitle(for url: URL, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = trimmed.isEmpty ? (url.host ?? "제목 없음") : trimmed
        let isDesktopMode = stateModel?.isDesktopMode ?? false
        let normalized = PageRecord.normalizeURL(url, isDesktopMode: isDesktopMode)

        for i in stride(from: pageHistory.count - 1, through: 0, by: -1) {
            if pageHistory[i].normalizedURL(isDesktopMode: isDesktopMode) == normalized {
                var record = pageHistory[i]
                record.updateTitle(safeTitle)
                pageHistory[i] = record
                dbg("📝 제목 갱신: '\(safeTitle)'")
                return
            }
        }
    }

    func findPageIndex(for url: URL) -> Int? {
        let isDesktopMode = stateModel?.isDesktopMode ?? false
        let normalized = PageRecord.normalizeURL(url, isDesktopMode: isDesktopMode)
        return pageHistory.indices.last { pageHistory[$0].normalizedURL(isDesktopMode: isDesktopMode) == normalized }
    }

    func clearHistory() {
        Self.globalHistory.removeAll()
        Self.saveGlobalHistory()
        pageHistory.removeAll()
        dbg("🧹 전체 히스토리 삭제")
    }

    // MARK: - 하위 호환 API
    var historyURLs: [String] { pageHistory.map { $0.url.absoluteString } }
    var currentHistoryIndex: Int { 0 }
    func historyStackIfAny() -> [URL] { pageHistory.map { $0.url } }
    func currentIndexInSafeBounds() -> Int { 0 }

    // addNewPage - 하위 호환 (BFCache UI 등에서 호출)
    func addNewPage(url: URL, title: String = "") {
        addMetadataEntry(url: url, title: title)
    }
}
