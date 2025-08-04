import SwiftUI

// MARK: - MyBrowserAppApp: 앱 진입점
@main
struct MyBrowserAppApp: App {
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs() // 초기 탭 목록
    @State private var selectedTabIndex: Int = 0 // 현재 선택된 탭 인덱스
    @Environment(\.scenePhase) private var scenePhase // 앱 생명주기 감지

    // MARK: - 초기화
    init() {
        _ = SilentAudioPlayer.shared // 무음 오디오 플레이어 초기화
        WebViewStateModel.loadGlobalHistory() // 전역 방문 기록 로드
        TabPersistenceManager.debugMessages.append("앱 초기화: 탭 \(tabs.count)개 로드")
    }

    // MARK: - Scene 구성
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
