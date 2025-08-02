import Foundation
import Combine

class WebViewStateModel: ObservableObject {
    // ✅ 기존 탐색 기능용
    @Published var currentURL: URL? = nil
    @Published var canGoBack = false
    @Published var canGoForward = false

    // ✅ AVPlayerView로 재생할 영상 URL
    @Published var playerURL: URL? = nil

    // ✅ AVPlayerView를 표시할지 여부
    @Published var showAVPlayer = false
}