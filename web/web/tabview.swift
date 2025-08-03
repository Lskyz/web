import SwiftUI
import AVKit

// MARK: - 방문 기록 항목 (탭 내 히스토리 저장용)
struct WebViewHistoryItem: Codable {
    let url: String       // 방문한 URL
    let title: String     // 해당 페이지 제목 (지금은 생략)
}

// MARK: - 각 탭의 히스토리 세션 저장 구조
struct WebTabSession: Codable {
    let tabID: UUID                // 탭 고유 식별자
    let currentIndex: Int         // 현재 보고 있는 페이지 인덱스
    let items: [WebViewHistoryItem] // URL 히스토리 목록
}

// MARK: - 탭 데이터 모델 (각 탭에 대응되는 상태 정보 보유)
struct WebTab: Identifiable, Equatable {
    let id: UUID                            // 고유 ID
    let stateModel: WebViewStateModel       // 웹뷰 상태 모델 (URL 등)
    var playerURL: URL? = nil               // 비디오 재생용
    var showAVPlayer: Bool = false          // 전체화면 재생 여부

    // 현재 페이지의 URL (stateModel로부터 간접 참조)
    var currentURL: URL? {
        stateModel.currentURL
    }

    // ✅ 일반 탭 생성자 (즉시 로딩)
    init(url: URL) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = self.id
        self.stateModel.currentURL = url
    }

    // ✅ 세션 복원용 생성자
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

// MARK: - 탭 목록 UI 및 관리
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tabs: [WebTab]                         // 탭 배열 바인딩
    let initialStateModel: WebViewStateModel            // 현재 선택된 탭
    let onTabSelected: (WebViewStateModel) -> Void      // 탭 선택 시 콜백
    @State private var selectedTabID: UUID?             // 선택된 탭 추적

    var body: some View {
        VStack(spacing: 0) {
            Text("탭 목록")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            ScrollView {
                VStack(spacing: 12) {
                    // 🔄 현재 탭으로 돌아가기 버튼
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

                    // 📑 각 탭 미리보기 및 선택
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

    // ✅ 최초 탭 하나도 없으면 기본 생성
    private func setupInitialTabs() {
        if tabs.isEmpty {
            let existing = WebTab(url: initialStateModel.currentURL ?? URL(string: "https://www.google.com")!)
            tabs.append(existing)
            selectedTabID = existing.id
        }
    }

    // ✅ 새 탭 추가 시 애플 페이지로 시작
    private func addNewTab() {
        let new = WebTab(url: URL(string: "https://www.apple.com")!)
        tabs.append(new)
        selectedTabID = new.id
    }

    // ✅ 탭 닫기
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

// MARK: - 탭 ↔ 저장 스냅샷 변환
extension WebTab {
    func toSnapshot() -> WebTabSnapshot? {
        // ✅ stateModel이 보관 중인 세션을 추출
        guard let session = stateModel.saveSession() else { return nil }

        // ✅ 세션에 담을 방문 기록 변환
        let items = session.urls.map {
            WebViewHistoryItem(url: $0.absoluteString, title: "")  // 제목은 비워둠
        }

        // ✅ 인덱스 포함한 세션 구성
        let sessionToSave = WebTabSession(
            tabID: id,
            currentIndex: session.currentIndex,
            items: items
        )

        return WebTabSnapshot(session: sessionToSave)
    }

    static func fromSnapshot(_ snapshot: WebTabSnapshot) -> WebTab {
        return WebTab(fromSession: snapshot.session)
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

// MARK: - 인덱스 안전 접근 확장
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}