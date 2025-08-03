import SwiftUI
import AVKit

// MARK: - 하나의 탭 정보 구조체
struct WebTab: Identifiable, Equatable {
    let id: UUID                              // 각 탭을 구분하기 위한 고유 ID
    let stateModel: WebViewStateModel         // 해당 탭의 웹 상태 (URL, 방문기록 등)
    var playerURL: URL?                       // AVPlayer 재생용 URL
    var showAVPlayer: Bool                    // AVPlayer 전체화면 여부

    var currentURL: URL? {                    // 현재 탭의 URL (단축 접근자)
        stateModel.currentURL
    }

    // 초기 생성자 (URL 기반으로 탭 생성)
    init(url: URL) {
        self.id = UUID()                      // 새 UUID 생성
        self.stateModel = WebViewStateModel() // 상태 모델 초기화
        self.stateModel.tabID = self.id       // ✅ 탭 ID 연결
        self.stateModel.currentURL = url      // 초기 URL 설정
        self.stateModel.loadHistoryForCurrentTab() // ✅ 탭별 기록 복원
        self.playerURL = nil                  // 초기 재생 URL 없음
        self.showAVPlayer = false             // PIP 꺼짐 상태
    }

    // Equatable 비교 (탭 ID 기준으로만 비교)
    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 리스트 및 선택 화면 (탭 관리자 뷰)
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var tabs: [WebTab]
    let initialStateModel: WebViewStateModel
    let onTabSelected: (WebViewStateModel) -> Void

    @State private var selectedTabID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Text("탭 목록")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            ScrollView {
                VStack(spacing: 12) {
                    Button(action: {
                        onTabSelected(initialStateModel)
                        dismiss()
                    }) {
                        Label("현재 탭 계속 사용", systemImage: "arrow.uturn.backward")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)

                    ForEach(tabs) { tab in
                        Button(action: {
                            onTabSelected(tab.stateModel)
                            dismiss()
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tab.currentURL?.host ?? "새 탭")
                                        .font(.headline)
                                    Text(tab.currentURL?.absoluteString ?? "")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if tab.stateModel === initialStateModel {
                                    Text("현재 탭")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .cornerRadius(6)
                                }

                                Button(action: {
                                    closeTab(tab)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.title2)
                                }
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(tab.stateModel === initialStateModel ? Color.blue : Color.clear, lineWidth: 2)
                                    .background(Color(UIColor.secondarySystemBackground).cornerRadius(10))
                            )
                            .padding(.horizontal)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.top)
            }

            Divider()

            HStack {
                Spacer()
                Button(action: {
                    addNewTab()
                }) {
                    Label("새 탭 추가", systemImage: "plus")
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                Spacer()
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            setupInitialTabs()
        }
    }

    private func setupInitialTabs() {
        if tabs.isEmpty {
            let existing = WebTab(url: initialStateModel.currentURL ?? URL(string: "https://www.google.com")!)
            tabs.append(existing)
            selectedTabID = existing.id
        }
    }

    private func addNewTab() {
        let new = WebTab(url: URL(string: "https://www.apple.com")!)
        tabs.append(new)
        selectedTabID = new.id
    }

    private func closeTab(_ tab: WebTab) {
        if let index = tabs.firstIndex(of: tab) {
            tabs.remove(at: index)
            if tabs.isEmpty {
                addNewTab()
            } else if selectedTabID == tab.id {
                selectedTabID = tabs.first!.id
            }
        }
    }
}

// MARK: - WebTab 저장용 구조체 (UserDefaults에 저장하기 위한 단순 구조)
struct WebTabSnapshot: Codable {
    let urlString: String
}

// MARK: - WebTab ↔ Snapshot 변환
extension WebTab {
    func toSnapshot() -> WebTabSnapshot? {
        guard let url = self.currentURL else { return nil }
        return WebTabSnapshot(urlString: url.absoluteString)
    }

    static func fromSnapshot(_ snapshot: WebTabSnapshot) -> WebTab {
        let url = URL(string: snapshot.urlString) ?? URL(string: "https://www.google.com")!
        var tab = WebTab(url: url)
        tab.stateModel.tabID = tab.id                    // ✅ 탭 ID 설정
        tab.stateModel.loadHistoryForCurrentTab()        // ✅ 탭별 기록 복원
        return tab
    }
}

// MARK: - 탭 저장/복원 관리자
enum TabPersistenceManager {
    private static let key = "savedWebTabs"

    static func saveTabs(_ tabs: [WebTab]) {
        let snapshots = tabs.compactMap { $0.toSnapshot() }
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func loadTabs() -> [WebTab] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshots = try? JSONDecoder().decode([WebTabSnapshot].self, from: data) else {
            return []
        }
        return snapshots.map(WebTab.fromSnapshot)
    }
}