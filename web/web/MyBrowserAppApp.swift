import SwiftUI

@main
struct MyBrowserAppApp: App {
    
    init() {
        // ✅ 오디오 세션 자동 활성화
        _ = SilentAudioPlayer.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}