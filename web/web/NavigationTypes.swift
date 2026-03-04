import Foundation

// MARK: - 커스텀 네비게이션 타입
enum NavigationType: String, Codable, CaseIterable {
    case normal      = "normal"
    case reload      = "reload"
    case home        = "home"
    case spaNavigation = "spa"
    case userClick   = "userClick"
}

// MARK: - WebKit SPA 네비게이션 타입 (didSameDocumentNavigation private API)
@objc enum WKSameDocumentNavigationType: Int {
    case anchorNavigation  = 0  // #hash 변경
    case sessionStatePush  = 1  // history.pushState()
    case sessionStateReplace = 2 // history.replaceState()
    case sessionStatePop   = 3  // history.back/forward() or popstate
}
