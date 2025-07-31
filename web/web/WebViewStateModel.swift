import Foundation
import Combine

class WebViewStateModel: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?
    
    func goBack() {
        NotificationCenter.default.post(name: NSNotification.Name("WebViewGoBack"), object: nil)
    }
    func goForward() {
        NotificationCenter.default.post(name: NSNotification.Name("WebViewGoForward"), object: nil)
    }
    
    func reload() {
        NotificationCenter.default.post(name: NSNotification.Name("WebViewReload"), object: nil)
    }
}