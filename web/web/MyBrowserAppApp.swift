import SwiftUI

@main
struct MyBrowserAppApp: App {

    init() {
        // ✅ 오디오 세션 자동 활성화
        _ = SilentAudioPlayer.shared

        // ✅ 앱 실행 시 전역 방문기록 복원
        WebViewStateModel.loadGlobalHistory()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {   // ✅ 필수: 화면 전환이 가능한 네비게이션 컨테이너
                ContentView()
            }
        }
    }
}