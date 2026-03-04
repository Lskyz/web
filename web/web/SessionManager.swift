import Foundation
import WebKit

// MARK: - 세션 저장/복원 및 전역 히스토리
extension WebViewDataModel {

    // MARK: - 세션

    func saveSession() -> WebViewSession? {
        guard !pageHistory.isEmpty else {
            dbg("💾 세션 저장 실패: 히스토리 없음")
            return nil
        }
        // currentIndex는 WebKit backForwardList 기준 URL로 계산
        let currentURL = stateModel?.webView?.backForwardList.currentItem?.url
        let currentIndex = pageHistory.indices.last {
            pageHistory[$0].url == currentURL
        } ?? max(0, pageHistory.count - 1)

        let session = WebViewSession(pageRecords: pageHistory, currentIndex: currentIndex)
        dbg("💾 세션 저장: \(pageHistory.count)개 페이지")
        return session
    }

    func restoreSession(_ session: WebViewSession) {
        dbg("🔄 세션 복원 시작")
        pageHistory = session.pageRecords
        dbg("🔄 세션 복원: \(pageHistory.count)개 메타데이터 로드")
        // 실제 WebKit 네비게이션은 interactionState로 처리 (CustomWebView.makeUIView)
    }

    func finishSessionRestore() {
        // no-op: 호환성 유지
    }

    func resetNavigationFlags() {
        // no-op: isBackForwardNavigating 제거됨 — 호환성 유지
        dbg("🔄 네비게이션 플래그 리셋 (no-op)")
    }

    // MARK: - 전역 히스토리

    static var globalHistory: [HistoryEntry] = [] {
        didSet { saveGlobalHistory() }
    }

    static func saveGlobalHistory() {
        if let data = try? JSONEncoder().encode(globalHistory) {
            UserDefaults.standard.set(data, forKey: "globalHistory")
        }
    }

    static func loadGlobalHistory() {
        if let data = UserDefaults.standard.data(forKey: "globalHistory"),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            globalHistory = loaded
        }
    }
}
