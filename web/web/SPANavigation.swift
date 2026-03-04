import Foundation
import WebKit

// MARK: - SPA 네비게이션 (WebKit private API 기반)
extension WebViewDataModel {

    // WebKit private callback: pushState / replaceState / popstate 모두 여기서 수신
    // JS 훅 불필요 — WebKit C++ 레벨에서 직접 감지
    @objc(_webView:navigation:didSameDocumentNavigation:)
    func webView(_ webView: WKWebView,
                 wkNavigation: WKNavigation?,
                 didSameDocumentNavigation wkNavigationType: Int) {

        guard let url = webView.url else { return }
        let title = webView.title ?? url.host ?? ""

        switch WKSameDocumentNavigationType(rawValue: wkNavigationType) {

        case .sessionStatePush:
            // 새 SPA 페이지 → 동기 캡처 (backItem = 실제 떠나는 페이지, React 렌더 전)
            if let stateModel = stateModel {
                BFCacheTransitionSystem.shared.captureSyncLeavingSnapshot(
                    webView: webView, stateModel: stateModel
                )
            }
            addMetadataEntry(url: url, title: title)
            stateModel?.syncCurrentURL(url)
            stateModel?.triggerNavigationFinished()
            dbg("🌐 SPA push: \(url.absoluteString)")

        case .sessionStateReplace:
            // 현재 항목 교체 → 메타데이터만 갱신
            replaceCurrentMetadata(url: url, title: title, siteType: "spa_replace")
            stateModel?.syncCurrentURL(url)
            dbg("🌐 SPA replace: \(url.absoluteString)")

        case .sessionStatePop:
            // WebKit이 이미 내비게이션 처리 완료 → 표시만 동기화
            updatePageTitle(for: url, title: title)
            stateModel?.syncCurrentURL(url)
            stateModel?.triggerNavigationFinished()
            dbg("🌐 SPA pop: \(url.absoluteString)")

        case .anchorNavigation:
            // #hash 변경 → URL 표시만 갱신
            stateModel?.syncCurrentURL(url)
            dbg("🌐 SPA anchor: \(url.absoluteString)")

        default:
            dbg("🌐 SPA unknown type \(wkNavigationType): \(url.absoluteString)")
        }
    }
}
