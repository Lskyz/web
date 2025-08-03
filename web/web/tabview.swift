import SwiftUI
import AVKit

// MARK: - 개별 방문기록 항목 및 세션 저장 구조 (탭 복원용)
struct WebViewHistoryItem: Codable {
    let url: String       // 방문한 URL
    let title: String     // 해당 페이지 제목
}

// MARK: - 각 탭의 세션 상태를 저장하기 위한 구조체
struct WebTabSession: Codable {
    let tabID: UUID
    let currentIndex: Int
    let items: [WebViewHistoryItem]
}

// MARK: - 탭 데이터 모델 (웹뷰 상태 포함)
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel
    var playerURL: URL? = nil
    var showAVPlayer: Bool = false

    var currentURL: URL? {
        stateModel.currentURL
    }

    // ✅ 새 탭 생성자 (즉시 로드)
    init(url: URL) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = self.id
        self.stateModel.currentURL = url
    }

    // ✅ 세션 복원용 생성자 (즉시 로딩 방지)
    init(fromSession session: WebTabSession) {
        self.id = session.tabID
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = session.tabID
        self.playerURL = nil
        self.showAVPlayer = false

        let urls = session.items.compactMap { URL(string: $0.url) }
        let index = session.currentIndex

        if urls.indices.contains(index) {
            self.stateModel.currentURL = urls[index]
            self.stateModel.pendingSession = WebViewSession(
                urls: urls,
                currentIndex: index
            )
        }
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 목록 관리 UI
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

// MARK: - 탭 저장용 구조체
struct WebTabSnapshot: Codable {
    let session: WebTabSession
}

// MARK: - 탭 ↔ 스냅샷 변환
extension WebTab {
    func toSnapshot() -> WebTabSnapshot? {
        guard let url = self.currentURL else { return nil }

        let item = WebViewHistoryItem(url: url.absoluteString, title: "")
        let session = WebTabSession(tabID: id, currentIndex: 0, items: [item])
        return WebTabSnapshot(session: session)
    }

    static func fromSnapshot(_ snapshot: WebTabSnapshot) -> WebTab {
        return WebTab(fromSession: snapshot.session)
    }
}

// MARK: - 탭 저장 관리자
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

// MARK: - 안전한 인덱싱
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}