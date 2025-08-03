import SwiftUI
import AVKit

// MARK: - 개별 방문기록 항목 및 세션 저장 구조 (탭 복원용)
struct WebViewHistoryItem: Codable {
    let url: String       // 방문한 URL
    let title: String     // 해당 페이지 제목
}

// MARK: - 각 탭의 세션 상태를 저장하기 위한 구조체
// 기존 WebViewSession과 이름 충돌을 방지하기 위해 WebTabSession으로 선언
struct WebTabSession: Codable {
    let tabID: UUID             // 탭 고유 ID
    let currentIndex: Int       // 세션 내 현재 위치
    let items: [WebViewHistoryItem] // 방문했던 페이지 목록
}

// MARK: - 탭 데이터 모델 (웹뷰 상태 포함)
struct WebTab: Identifiable, Equatable {
    let id: UUID                               // 탭 고유 ID
    let stateModel: WebViewStateModel          // 웹뷰 상태를 관리하는 뷰모델
    var playerURL: URL? = nil                  // AVPlayer에 사용할 비디오 URL
    var showAVPlayer: Bool = false             // 전체화면 플레이어 표시 여부

    var currentURL: URL? {
        stateModel.currentURL                  // 현재 웹뷰의 URL
    }

    // ✅ 새 탭 생성자
    init(url: URL) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = self.id
        self.stateModel.currentURL = url
    }

    // ✅ 동일성 판단
    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 목록 관리 UI (탭 추가, 선택, 제거)
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tabs: [WebTab]                        // 전체 탭 목록
    let initialStateModel: WebViewStateModel           // 현재 탭 상태
    let onTabSelected: (WebViewStateModel) -> Void     // 탭 전환 콜백
    @State private var selectedTabID: UUID? = nil       // 현재 선택된 탭

    var body: some View {
        VStack(spacing: 0) {
            Text("탭 목록")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            ScrollView {
                VStack(spacing: 12) {
                    // ✅ 현재 탭 유지 버튼
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

                    // ✅ 기존 탭 리스트
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

                                // 현재 탭 표시
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

    // ✅ 최초 진입 시 탭이 없다면 하나 생성
    private func setupInitialTabs() {
        if tabs.isEmpty {
            let existing = WebTab(url: initialStateModel.currentURL ?? URL(string: "https://www.google.com")!)
            tabs.append(existing)
            selectedTabID = existing.id
        }
    }

    // ✅ 새 탭 추가
    private func addNewTab() {
        let new = WebTab(url: URL(string: "https://www.apple.com")!)
        tabs.append(new)
        selectedTabID = new.id
    }

    // ✅ 탭 제거
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
    let session: WebTabSession   // 세션 상태 저장
}

// MARK: - 탭 ↔ 스냅샷 변환 로직
extension WebTab {
    // ✅ 현재 탭을 저장용 스냅샷으로 변환
    func toSnapshot() -> WebTabSnapshot? {
        guard let url = self.currentURL else { return nil }

        let item = WebViewHistoryItem(url: url.absoluteString, title: "")
        let session = WebTabSession(tabID: id, currentIndex: 0, items: [item])
        return WebTabSnapshot(session: session)
    }

    // ✅ 저장된 스냅샷으로부터 탭 복원
    static func fromSnapshot(_ snapshot: WebTabSnapshot) -> WebTab {
        let urls = snapshot.session.items
        let currentIndex = snapshot.session.currentIndex

        let url = URL(string: urls[safe: currentIndex]?.url ?? "https://www.google.com")!
        var tab = WebTab(url: url)
        tab.stateModel.tabID = snapshot.session.tabID
        tab.stateModel.currentURL = url

        // 세션 복원 예약 (뒤로/앞으로 기록 포함)
        let session = WebViewSession(
            urls: urls.compactMap { URL(string: $0.url) },
            currentIndex: snapshot.session.currentIndex
        )
        tab.stateModel.pendingSession = session

        return tab
    }
}

// MARK: - 탭 저장 관리자 (UserDefaults 사용)
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

// MARK: - 배열 안전 접근용 확장
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}