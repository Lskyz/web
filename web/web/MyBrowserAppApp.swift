import SwiftUI

/// ✅ 앱의 진입점 (Main Application)
@main
struct MyBrowserAppApp: App {

    // 📌 현재 열려 있는 웹 탭 목록 (탭 배열)
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs()

    // ⭐ 현재 선택된 탭의 인덱스 (탭 전환에 사용됨)
    @State private var selectedTabIndex: Int = 0

    /// ✅ 앱 초기화 시 실행되는 로직
    init() {
        // 🎧 무음 방지용 오디오 세션 설정 (앱 실행 시 1초짜리 무음 사운드 재생을 위한 초기화)
        _ = SilentAudioPlayer.shared

        // 🕘 전역 방문 기록 로딩 (UserDefaults에서 불러오기)
        WebViewStateModel.loadGlobalHistory()
    }

    /// ✅ 앱 UI 구성
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                // 🧭 메인 브라우저 컨테이너 뷰로 이동
                ContentView(
                    tabs: $tabs,                       // 바인딩된 탭 배열 전달
                    selectedTabIndex: $selectedTabIndex // 현재 선택된 탭 인덱스 전달
                )
            }
        }
    }
}
