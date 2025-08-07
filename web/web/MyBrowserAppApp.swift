import SwiftUI

@main
struct MyBrowserAppApp: App {
    // 탭 배열: UserDefaults로부터 복원
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs()
    // 마지막 선택된 탭 인덱스: UserDefaults에서 복원
    @State private var selectedTabIndex: Int = UserDefaults.standard.integer(forKey: "selectedTabIndex")
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
        // 앱 백그라운드 전환 시 탭과 인덱스 저장
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                TabPersistenceManager.saveTabs(tabs)
                // 현재 선택 탭 인덱스 저장
                UserDefaults.standard.set(selectedTabIndex, forKey: "selectedTabIndex")
                TabPersistenceManager.debugMessages.append("앱 백그라운드 진입: 탭/인덱스 저장")
            }
        }
        // 탭이 바뀌거나 추가/삭제시 인덱스 저장
        .onChange(of: tabs) { _ in
            UserDefaults.standard.set(selectedTabIndex, forKey: "selectedTabIndex")
        }
        .onChange(of: selectedTabIndex) { idx in
            UserDefaults.standard.set(idx, forKey: "selectedTabIndex")
        }
        // 앱 실행시 잘못된 인덱스 복원 방지
        .onAppear {
            if tabs.isEmpty {
                selectedTabIndex = 0
            } else if !(0..<tabs.count).contains(selectedTabIndex) {
                selectedTabIndex = 0
            }
        }
    }
}
