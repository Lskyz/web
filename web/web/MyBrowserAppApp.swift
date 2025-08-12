// MyBrowserAppApp.swift
//  앱 진입점: 탭 배열과 선택된 탭 인덱스를 관리하고, 백그라운드 진입 시 탭 저장
import SwiftUI

@main
struct MyBrowserAppApp: App {
    // 🌟 앱 재실행 시 마지막 보던 탭 복원
    // @AppStorage를 쓰면 UserDefaults에서 자동으로 불러오고 저장해 줍니다.
    @AppStorage("lastSelectedTabIndex") private var selectedTabIndex: Int = 0

    // 열려 있는 탭 배열: UserDefaults에서 복원
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs()

    // 앱 생명주기 감지 (백그라운드 진입 시 저장)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // AV 오디오 세션 미리 활성화
        _ = SilentAudioPlayer.shared
        // ✅ 수정: WebViewDataModel로 변경 (전역 방문 기록 로드)
        WebViewDataModel.loadGlobalHistory()
        TabPersistenceManager.debugMessages.append(
            "앱 초기화: 탭 \(tabs.count)개 로드, 선택된 탭 인덱스 \(selectedTabIndex)"
        )
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                // ContentView에 Binding으로 전달
                ContentView(
                    tabs: $tabs,
                    selectedTabIndex: $selectedTabIndex
                )
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                // 백그라운드로 가면 탭 스냅샷 저장
                TabPersistenceManager.saveTabs(tabs)
                TabPersistenceManager.debugMessages.append("앱 백그라운드 진입: 탭 저장")
                // @AppStorage인 selectedTabIndex는 자동 저장됩니다.
            }
        }
    }
}
