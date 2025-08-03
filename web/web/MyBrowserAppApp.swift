import SwiftUI

@main
struct MyBrowserAppApp: App {
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs()
    @State private var selectedTabIndex: Int = 0

    init() {
        // ✅ 무음 방지용 오디오 플레이어 초기화
        _ = SilentAudioPlayer.shared

        // ✅ 앱 실행 시 전역 방문 기록 불러오기
        WebViewStateModel.loadGlobalHistory()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView(
                    tabs: $tabs,
                    selectedTabIndex: $selectedTabIndex
                )
            }
        }
    }
}