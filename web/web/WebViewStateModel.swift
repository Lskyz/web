import Foundation

class WebViewStateModel: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?
    @Published var bookmarks: [URL] = []

    func goBack() {
        NotificationCenter.default.post(name: NSNotification.Name("WebViewGoBack"), object: nil)
    }

    func goForward() {
        NotificationCenter.default.post(name: NSNotification.Name("WebViewGoForward"), object: nil)
    }
}
