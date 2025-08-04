import SwiftUI

@main
struct MyBrowserAppApp: App {
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs()
    @State private var selectedTabIndex: Int = 0
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = SilentAudioPlayer.shared
        WebViewStateModel.loadGlobalHistory()
        TabPersistenceManager.debugMessages.append("앱 초기화: 탭 \(tabs.count)개 로드")
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
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                TabPersistenceManager.saveTabs(tabs)
                TabPersistenceManager.debugMessages.append("앱 백그라운드 진입: 탭 저장")
            }
        }
    }
}
