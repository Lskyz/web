import SwiftUI
import AVKit

// MARK: - 하나의 탭을 나타내는 구조체 (각 웹뷰 상태 관리)
struct WebTab: Identifiable, Equatable {
    let id: UUID                                // 각 탭 고유 식별자
    let stateModel: WebViewStateModel           // 해당 탭의 웹 상태 (URL, 방문기록 등)
    var playerURL: URL?                         // AVPlayer에 전달할 비디오 URL
    var showAVPlayer: Bool                      // AVPlayer 전체화면 표시 여부

    var currentURL: URL? {
        stateModel.currentURL                   // 현재 탭의 URL 접근자
    }

    // MARK: - 초기화 (새 탭 생성 시 호출됨)
    init(url: URL) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = self.id         // 탭 ID 설정
        self.stateModel.currentURL = url        // 초기 로딩할 URL 지정
        // self.stateModel.loadHistoryForCurrentTab() ✅ 삭제됨 - 전역 기록 방식으로 변경됨
        self.playerURL = nil
        self.showAVPlayer = false
    }

    // MARK: - Equatable 비교 구현 (id 기준으로 비교)
    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 관리 화면 (탭 선택 및 추가/삭제 기능 제공)
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss       // 현재 뷰 닫기용
    @Binding var tabs: [WebTab]                       // 전체 탭 목록 바인딩
    let initialStateModel: WebViewStateModel          // 현재 선택된 탭의 상태
    let onTabSelected: (WebViewStateModel) -> Void    // 탭 선택 시 콜백
    @State private var selectedTabID: UUID?           // 선택된 탭 ID 추적

    var body: some View {
        VStack(spacing: 0) {
            Text("탭 목록")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            ScrollView {
                VStack(spacing: 12) {
                    // 현재 탭 계속 사용 버튼
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

                    // 모든 탭 리스트
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

                                // 탭 닫기 버튼
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

            // 새 탭 추가 버튼
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

    // MARK: - 탭이 하나도 없을 경우 초기 탭 생성
    private func setupInitialTabs() {
        if tabs.isEmpty {
            let existing = WebTab(url: initialStateModel.currentURL ?? URL(string: "https://www.google.com")!)
            tabs.append(existing)
            selectedTabID = existing.id
        }
    }

    // MARK: - 새 탭 추가 함수
    private func addNewTab() {
        let new = WebTab(url: URL(string: "https://www.apple.com")!)
        tabs.append(new)
        selectedTabID = new.id
    }

    // MARK: - 탭 닫기 함수
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

// MARK: - WebTab 저장용 구조체 (UserDefaults 저장을 위해 단순 구조화)
struct WebTabSnapshot: Codable {
    let urlString: String                       // 현재 탭의 URL을 문자열로 저장
}

// MARK: - WebTab ↔ Snapshot 변환 확장
extension WebTab {
    // 현재 WebTab을 스냅샷 형태로 변환
    func toSnapshot() -> WebTabSnapshot? {
        guard let url = self.currentURL else { return nil }
        return WebTabSnapshot(urlString: url.absoluteString)
    }

    // 스냅샷에서 WebTab 복원
    static func fromSnapshot(_ snapshot: WebTabSnapshot) -> WebTab {
        let url = URL(string: snapshot.urlString) ?? URL(string: "https://www.google.com")!
        var tab = WebTab(url: url)
        tab.stateModel.tabID = tab.id
        // tab.stateModel.loadHistoryForCurrentTab() ✅ 삭제됨 - 전역 기록 방식으로 변경됨
        return tab
    }
}

// MARK: - 탭 저장/복원 도구 (UserDefaults 사용)
enum TabPersistenceManager {
    private static let key = "savedWebTabs"

    // 탭들 저장 (스냅샷 → JSON 인코딩 → UserDefaults 저장)
    static func saveTabs(_ tabs: [WebTab]) {
        let snapshots = tabs.compactMap { $0.toSnapshot() }
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // 저장된 탭들 불러오기 (UserDefaults → 디코딩 → WebTab 복원)
    static func loadTabs() -> [WebTab] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshots = try? JSONDecoder().decode([WebTabSnapshot].self, from: data) else {
            return []
        }
        return snapshots.map(WebTab.fromSnapshot)
    }
}