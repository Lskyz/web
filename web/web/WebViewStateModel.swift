import Foundation
import Combine
import SwiftUI

// 🌐 WebView의 상태를 관리하는 뷰 모델
class WebViewStateModel: ObservableObject {

    // 🔗 현재 WebView에 표시 중인 URL
    // 외부에서 수정 가능하도록 @Published var 사용
    // 변경될 때마다 UserDefaults에 저장 + 방문 기록 추가
    @Published var currentURL: URL? = nil {
        didSet {
            if let url = currentURL {
                // 마지막 방문한 주소 저장 (앱 재시작 시 로드용)
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")
                // 방문기록에 추가
                addToHistory(url)
            }
        }
    }

    // 🔙 뒤로가기 가능 여부 (WebView에서 상태 업데이트)
    @Published var canGoBack = false

    // 🔜 앞으로가기 가능 여부
    @Published var canGoForward = false

    // 🎥 AVPlayer로 재생할 영상의 URL
    @Published var playerURL: URL? = nil

    // 🎬 AVPlayerView 표시 여부
    @Published var showAVPlayer = false

    // 🕓 방문 기록 리스트
    @Published var history: [URL] = [] {
        didSet {
            saveHistory()  // 변경 시 자동 저장
        }
    }

    // 💾 방문기록 최대 저장 개수 (최신 100개)
    private let maxHistoryCount = 100

    // 🏁 초기화 시 기록 불러오기 + 마지막 URL 복원
    init() {
        loadHistory()

        if let lastURLString = UserDefaults.standard.string(forKey: "lastURL"),
           let url = URL(string: lastURLString) {
            self.currentURL = url
        }
    }

    // ➕ 방문기록에 새 URL 추가
    private func addToHistory(_ url: URL) {
        // 중복 저장 방지
        guard !history.contains(url) else { return }

        // 기록 추가
        history.append(url)

        // 최대 개수 초과 시 오래된 항목 삭제
        if history.count > maxHistoryCount {
            history.removeFirst(history.count - maxHistoryCount)
        }
    }

    // 💽 방문기록 저장 (UserDefaults 사용)
    private func saveHistory() {
        let strings = history.map { $0.absoluteString }
        UserDefaults.standard.set(strings, forKey: "history")
    }

    // 📂 앱 시작 시 저장된 기록 불러오기
    private func loadHistory() {
        if let stored = UserDefaults.standard.array(forKey: "history") as? [String] {
            self.history = stored.compactMap { URL(string: $0) }
        }
    }

    // ❌ 방문기록 전체 삭제
    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: "history")
    }

    // ❌ 개별 URL 삭제
    func removeHistoryItem(_ url: URL) {
        history.removeAll { $0 == url }
    }

    // ⬅️ WebView에 뒤로가기 알림 보내기
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    // ➡️ WebView에 앞으로가기 알림
    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    // 🔁 WebView 새로고침 알림
    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // 🔧 삭제됨: setCurrentURL(url) → 직접 currentURL에 할당 방식으로 변경
    // func setCurrentURL(_ url: URL) {
    //     self.currentURL = url
    // }

    // 📘 방문기록 전용 페이지 (별도 화면으로 제공)
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel

        var body: some View {
            List {
                // 🔴 전체 삭제 버튼 섹션
                if !state.history.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            state.clearHistory()
                        } label: {
                            HStack {
                                Spacer()
                                Text("전체 삭제")
                                Spacer()
                            }
                        }
                    }
                }

                // 📜 방문 기록 목록 섹션
                Section(header: Text("방문 기록")) {
                    ForEach(state.history.reversed(), id: \.self) { url in
                        HStack {
                            // 👉 해당 URL로 이동
                            Button(action: {
                                state.currentURL = url
                            }) {
                                Text(url.absoluteString)
                                    .lineLimit(1)
                                    .foregroundColor(.primary)
                            }

                            Spacer()

                            // 🗑️ 삭제 버튼
                            Button(action: {
                                state.removeHistoryItem(url)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("방문기록")
        }
    }
}