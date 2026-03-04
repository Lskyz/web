import Foundation
import SwiftUI
import WebKit

fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - WebViewDataModel
// 역할: 페이지 메타데이터 저장 + WKNavigationDelegate
// 네비게이션 로직(canGoBack, goBack 등)은 WebViewStateModel이 WebKit KVO로 직접 처리
final class WebViewDataModel: NSObject, ObservableObject, WKNavigationDelegate {
    var tabID: UUID?
    weak var stateModel: WebViewStateModel?

    // 메타데이터 전용 — 네비게이션 소스 아님
    @Published var pageHistory: [PageRecord] = []

    override init() {
        super.init()
        Self.loadGlobalHistory()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted:
            if let stateModel = stateModel {
                BFCacheTransitionSystem.shared.storeLeavingSnapshotIfPossible(
                    webView: webView, stateModel: stateModel
                )
            }
        case .backForward:
            decisionHandler(.allow)
            return
        default:
            break
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        stateModel?.handleLoadingStart()
        dbg("🚀 네비게이션 시작: \(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        stateModel?.handleLoadingFinish()
        guard let url = webView.url else { return }
        let title = webView.title ?? url.host ?? "제목 없음"

        addMetadataEntry(url: url, title: title)
        stateModel?.syncCurrentURL(url)
        stateModel?.triggerNavigationFinished()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let stateModel = self?.stateModel, let wv = stateModel.webView else { return }
            BFCacheTransitionSystem.shared.storeArrivalSnapshotIfPossible(webView: wv, stateModel: stateModel)
        }
        dbg("✅ 네비게이션 완료: '\(title)'")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")
        dbg("❌ Provisional 실패: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        stateModel?.handleLoadingError()
        stateModel?.notifyError(error, url: webView.url?.absoluteString ?? "")
        dbg("❌ 네비게이션 실패: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse,
           httpResponse.statusCode >= 400 {
            stateModel?.notifyHTTPError(httpResponse.statusCode, url: navigationResponse.response.url?.absoluteString ?? "")
        }
        shouldDownloadResponse(navigationResponse, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        stateModel?.handleDidCommitNavigation(webView)
    }

    @available(iOS 14.0, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        handleDownloadStart(download: download, stateModel: stateModel)
    }

    @available(iOS 14.0, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        handleDownloadStart(download: download, stateModel: stateModel)
    }

    // MARK: - 디버그

    func dbg(_ msg: String) {
        let id = tabID?.uuidString.prefix(6) ?? "noTab"
        TabPersistenceManager.debugMessages.append("[\(ts())][\(id)][\(pageHistory.count)] \(msg)")
    }
}
