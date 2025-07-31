import Foundation

class WebViewStateModel: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?
    @Published var bookmarks: [URL] = []
}
