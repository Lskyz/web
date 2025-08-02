import Foundation
import Combine

// ✅ WebView의 상태를 관리하는 ViewModel
class WebViewStateModel: ObservableObject {

    // ✅ 현재 페이지의 URL을 나타내며, 값이 변경되면 방문 기록에 자동 저장됩니다.
    @Published var currentURL: URL? = nil {
        didSet {
            if let url = currentURL {
                // 마지막 방문 페이지 저장 (앱 종료 후 복원용)
                UserDefaults.standard.set(url.absoluteString, forKey: "lastURL")

                // 방문 기록에 추가
                addToHistory(url: url)
            }
        }
    }

    // ✅ WebView의 '뒤로 가기' 가능 여부
    @Published var canGoBack = false

    // ✅ WebView의 '앞으로 가기' 가능 여부
    @Published var canGoForward = false

    // ✅ AVPlayer로 재생할 영상의 URL
    @Published var playerURL: URL? = nil

    // ✅ AVPlayer를 전체화면으로 표시할지 여부
    @Published var showAVPlayer = false

    // ✅ 방문 기록을 저장하는 배열 (최신 순)
    @Published var history: [URL] = []

    // ✅ 방문 기록에 URL을 추가하며, 중복 방지 및 용량 제한 처리
    func addToHistory(url: URL) {
        // 중복 제거
        if !history.contains(url) {
            history.append(url)

            // 기록이 너무 많아지면 오래된 항목 제거 (예: 최대 100개 유지)
            if history.count > 100 {
                history.removeFirst()
            }
        }
    }

    // ✅ WebView 뒤로가기 동작을 트리거
    func goBack() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoBack"), object: nil)
    }

    // ✅ WebView 앞으로가기 동작을 트리거
    func goForward() {
        NotificationCenter.default.post(name: Notification.Name("WebViewGoForward"), object: nil)
    }

    // ✅ WebView 새로고침 동작을 트리거
    func reload() {
        NotificationCenter.default.post(name: Notification.Name("WebViewReload"), object: nil)
    }

    // ✅ 방문기록을 보여주는 별도 페이지 (ContentView에서 NavigationLink로 호출)
    struct HistoryPage: View {
        @ObservedObject var state: WebViewStateModel

        var body: some View {
            List {
                // 기록 목록 출력
                ForEach(state.history, id: \.self) { url in
                    Button(action: {
                        // 항목 클릭 시 해당 페이지로 이동
                        state.currentURL = url
                    }) {
                        Text(url.absoluteString)
                            .lineLimit(1)
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("방문 기록")
        }

        // ✅ 리스트에서 항목 삭제 기능
        func delete(at offsets: IndexSet) {
            state.history.remove(atOffsets: offsets)
        }
    }
}