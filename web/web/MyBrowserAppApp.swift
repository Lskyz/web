import SwiftUI

@main
struct MyBrowserAppApp: App {
    
    // ✅ 앱 시작 시 무음 오디오 재생을 통한 오디오 세션 활성화
    init() {
        AVPSessionManager.shared.startSilentPlayback()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}