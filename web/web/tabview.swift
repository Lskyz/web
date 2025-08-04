import SwiftUI
import AVKit
import WebKit

// MARK: - WebTab 모델
// 각 브라우저 탭을 식별 및 상태 관리하기 위한 구조체
struct WebTab: Identifiable, Equatable {
    let id: UUID                      // 탭 고유 식별자
    let stateModel: WebViewStateModel // WKWebView 상태 및 히스토리 관리 객체
    var playerURL: URL? = nil         // AVPlayer로 재생할 비디오 URL
    var showAVPlayer: Bool = false    // AVPlayer 전체화면 여부

    // 현재 페이지 URL (ViewModel에서 업데이트)
    var currentURL: URL? {
        stateModel.currentURL
    }

    // 현재 탭의 전체 방문 히스토리 URL 목록
    var historyURLs: [String] {
        stateModel.historyURLs
    }

    // 현재 히스토리 인덱스 위치
    var currentHistoryIndex: Int {
        stateModel.currentHistoryIndex
    }

    /// 새 탭 생성 시 호출
    /// - Parameter url: 초기 로드할 URL (없으면 대시보드 사용)
    init(url: URL? = nil) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = self.id
        self.stateModel.currentURL = url
    }

    /// Equatable 구현 (id 기준 비교)
    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 저장/복원 관리자
// UserDefaults를 이용해 탭의 ID, 방문 히스토리 URL 배열, 현재 인덱스를 저장/복원
enum TabPersistenceManager {
    private static let key = "savedTabs"

    /// 탭 배열 저장
    static func saveTabs(_ tabs: [WebTab]) {
        let info = tabs.map { tab -> [String: Any] in
            return [
                "id": tab.id.uuidString,          // 탭 고유 ID
                "history": tab.historyURLs,       // 방문 히스토리 URL 리스트
                "index": tab.currentHistoryIndex  // 현재 위치 인덱스
            ]
        }

        if let data = try? JSONSerialization.data(withJSONObject: info, options: []) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 저장된 탭 복원
    static func loadTabs() -> [WebTab] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return raw.map { dict in
            let id = UUID(uuidString: dict["id"] as? String ?? "") ?? UUID()
            let urls = dict["history"] as? [String] ?? []
            let index = dict["index"] as? Int ?? 0

            var tab = WebTab() // 기본 생성자로 초기화 후 수동 덮어쓰기
            tab.stateModel.tabID = id
            tab.stateModel.restoredHistoryURLs = urls
            tab.stateModel.restoredHistoryIndex = index
            return tab
        }
    }
}

// MARK: - 대시보드 뷰
// 탭에 URL이 없을 때 표시되는 홈 화면 뷰
struct DashboardView: View {
    @State private var inputURL: String = ""
    let onSelectURL: (URL) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("대시보드")
                .font(.largeTitle.bold())

            // 기본 북마크 버튼
            HStack(spacing: 40) {
                icon(title: "Google", url: "https://www.google.com")
                icon(title: "Naver", url: "https://www.naver.com")
            }

            // URL 입력 및 이동
            HStack {
                TextField("URL 입력", text: $inputURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("이동") {
                    if let url = URL(string: inputURL) {
                        onSelectURL(url)
                    }
                }
            }
            .padding(.top, 20)

            Spacer()
        }
        .padding()
    }

    /// 북마크 아이콘 버튼 컴포넌트
    private func icon(title: String, url: String) -> some View {
        Button(action: {
            if let u = URL(string: url) {
                onSelectURL(u)
            }
        }) {
            VStack {
                Image(systemName: "globe")
                    .resizable()
                    .frame(width: 40, height: 40)
                Text(title)
                    .font(.headline)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
    }
}

// MARK: - 탭 관리자 뷰
// 탭 목록 표시, 선택 및 닫기, 새 탭 추가 기능 제공
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tabs: [WebTab]
    let initialStateModel: WebViewStateModel
    let onTabSelected: (WebViewStateModel) -> Void

    var body: some View {
        VStack {
            Text("탭 목록")
                .font(.title.bold())

            ScrollView {
                ForEach(tabs) { tab in
                    HStack {
                        // 탭 전환 버튼
                        Button(action: {
                            onTabSelected(tab.stateModel)
                            dismiss()
                        }) {
                            VStack(alignment: .leading) {
                                Text(tab.currentURL?.host ?? "대시보드")
                                    .font(.headline)
                                Text(tab.currentURL?.absoluteString ?? "")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        Spacer()
                        // 탭 닫기 버튼
                        Button(action: { closeTab(tab) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                    .padding()
                }
            }

            // 새 탭 추가 버튼
            Button(action: {
                tabs.append(WebTab())
                dismiss()
            }) {
                Label("새 탭", systemImage: "plus")
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding()
        }
    }

    /// 특정 탭을 배열에서 제거
    private func closeTab(_ tab: WebTab) {
        if let idx = tabs.firstIndex(of: tab) {
            tabs.remove(at: idx)
        }
    }
}

// MARK: - 안전한 컬렉션 인덱스 접근 확장
// index 범위 초과로 인한 크래시 방지
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
