import Foundation
import Combine

class WebViewStateModel: ObservableObject {
    // ✅ 현재 표시 중인 URL
    @Published var currentURL: URL? = nil

    // ✅ WebView 탐색 가능 여부
    @Published var canGoBack = false
    @Published var canGoForward = false

    // ✅ AVPlayer로 재생할 영상 URL
    @Published var playerURL: URL? = nil

    // ✅ AVPlayerView를 표시할지 여부
    @Published var showAVPlayer = false

    // ✅ WebView 조작용 Notification 트리거 메서드
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }
}