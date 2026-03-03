// MyBrowserAppApp.swift
//  앱 진입점: 탭 배열과 선택된 탭 인덱스를 관리하고, 백그라운드 진입 시 탭 저장
import SwiftUI
import UIKit

// MARK: - 낮/밤 아이콘 전환
private let koreaTimeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
private let koreaCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = koreaTimeZone
    return calendar
}()

private func updateAppIconForTime(now: Date = Date()) {
    let hour = koreaCalendar.component(.hour, from: now)
    // 18시(오후 6시) ~ 06시: 밤하늘 아이콘, 그 외: 낮 아이콘
    let isNight = hour >= 18 || hour < 6
    let targetIcon: String? = isNight ? "AppIcon-Night" : nil  // nil = 기본(낮) 아이콘

    guard UIApplication.shared.supportsAlternateIcons else { return }

    let currentIcon = UIApplication.shared.alternateIconName
    guard currentIcon != targetIcon else { return }  // 이미 맞으면 생략

    UIApplication.shared.setAlternateIconName(targetIcon) { error in
        if let error = error {
            print("아이콘 전환 실패: \(error.localizedDescription)")
        } else {
            print("아이콘 전환 완료: \(isNight ? "밤하늘" : "낮")")
        }
    }
}

@main
struct MyBrowserAppApp: App {
    // 🌟 앱 재실행 시 마지막 보던 탭 복원
    // @AppStorage를 쓰면 UserDefaults에서 자동으로 불러오고 저장해 줍니다.
    @AppStorage("lastSelectedTabIndex") private var selectedTabIndex: Int = 0

    // 열려 있는 탭 배열: UserDefaults에서 복원
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs()

    // 앱 생명주기 감지 (백그라운드 진입 시 저장)
    @Environment(\.scenePhase) private var scenePhase
    private let iconRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // 백그라운드로 가면 탭 스냅샷 저장
                TabPersistenceManager.saveTabs(tabs)
                TabPersistenceManager.debugMessages.append("앱 백그라운드 진입: 탭 저장")
                // @AppStorage인 selectedTabIndex는 자동 저장됩니다.
            } else if newPhase == .active {
                // 🌙 포어그라운드 진입 시 시간에 맞는 아이콘으로 전환
                updateAppIconForTime()
            }
        }
        .onReceive(iconRefreshTimer) { now in
            guard scenePhase == .active else { return }
            updateAppIconForTime(now: now)
        }
    }
}
