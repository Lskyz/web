import SwiftUI

// MARK: - 앱 진입점
@main
struct MyBrowserAppApp: App {
    // 앱 전체에서 관리되는 탭 목록
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs()
    // 현재 선택된 탭 인덱스
    @State private var selectedTabIndex: Int = 0
    // ScenePhase 감지용
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - 초기화
    init() {
        // 무음 방지용 오디오 플레이어 초기화
        _ = SilentAudioPlayer.shared
        // 전역 방문 기록 불러오기
        WebViewStateModel.loadGlobalHistory()
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
        // ScenePhase 변경 감지
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                TabPersistenceManager.saveTabs(tabs)
                TabPersistenceManager.debugMessages.append("앱 백그라운드 진입: 탭 저장")
            }
        }
    }
}
