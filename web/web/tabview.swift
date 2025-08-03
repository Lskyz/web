import SwiftUI
import AVKit

// MARK: - 방문 기록 항목 (탭의 내역을 저장할 때 사용)
struct WebViewHistoryItem: Codable {
    let url: String   // 방문한 페이지의 URL 문자열
    let title: String // 페이지 제목 (현재는 사용하지 않지만 구조상 포함)
}

// MARK: - 하나의 탭에 대한 세션 정보
struct WebTabSession: Codable {
    let tabID: UUID                // 탭 고유 식별자
    let currentIndex: Int          // 현재 보고 있는 URL의 인덱스
    let items: [WebViewHistoryItem] // 방문했던 페이지 목록
}

// MARK: - WebTab 구조체 (실제 하나의 탭을 나타냄)
struct WebTab: Identifiable, Equatable {
    let id: UUID                       // 탭의 고유 ID
    let stateModel: WebViewStateModel // 웹 뷰 상태 모델
    var playerURL: URL? = nil         // AVPlayer용 URL (비디오 전용)
    var showAVPlayer = false          // 전체화면 재생 여부

    var currentURL: URL? {
        stateModel.currentURL         // 현재 표시 중인 URL
    }

    /// 새 탭 생성자
    init(url: URL? = nil) {
        id = UUID()
        stateModel = WebViewStateModel()
        stateModel.tabID = id
        stateModel.currentURL = url   // 시작 URL이 있다면 설정
    }

    /// 저장된 세션(WebTabSession)에서 복원할 때 사용
    init(fromSession session: WebTabSession) {
        id = session.tabID
        stateModel = WebViewStateModel()
        stateModel.tabID = id

        let urls = session.items.compactMap { URL(string: $0.url) } // 문자열 → URL로 변환
        let idx  = session.currentIndex

        // 복원 가능한 인덱스면 세션 복원
        if urls.indices.contains(idx) {
            stateModel.restoreSession(WebViewSession(urls: urls, currentIndex: idx))
        }
        // 아니면 첫 번째 URL만 로드
        else if let u = urls.first {
            stateModel.currentURL = u
        }
    }

    /// 동등성 비교: ID 기준으로 비교
    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭의 저장 스냅샷 구조체 (UserDefaults에 저장할 형태)
struct WebTabSnapshot: Codable {
    let session: WebTabSession
}

// MARK: - WebTab → Snapshot 변환 및 복원
extension WebTab {
    func toSnapshot() -> WebTabSnapshot {
        // 내부 방문 기록(historyStack)을 가져오되, 비어 있다면 현재 URL 포함
        let seq = stateModel.historyStackIfAny()

        // 기록을 WebViewHistoryItem 배열로 변환
        let items = seq.map { WebViewHistoryItem(url: $0.absoluteString, title: "") }

        // 현재 인덱스와 함께 세션 생성
        let session = WebTabSession(
            tabID: id,
            currentIndex: stateModel.currentIndexInSafeBounds(),
            items: items
        )

        return WebTabSnapshot(session: session)
    }

    static func fromSnapshot(_ snapshot: WebTabSnapshot) -> WebTab {
        WebTab(fromSession: snapshot.session)
    }
}

// MARK: - 탭 저장/복원 매니저 (UserDefaults 기반)
enum TabPersistenceManager {
    private static let key = "savedWebTabs"

    /// 현재 탭 배열을 UserDefaults에 저장
    static func saveTabs(_ tabs: [WebTab]) {
        let arr = tabs.map { $0.toSnapshot() } // 탭 → Snapshot으로 변환
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// UserDefaults에서 저장된 탭 복원
    static func loadTabs() -> [WebTab] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([WebTabSnapshot].self, from: d)
        else {
            return []
        }
        return arr.map(WebTab.fromSnapshot)
    }
}

// MARK: - 메인 브라우저 UI
struct UnifiedBrowserView: View {
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs() // 저장된 탭 불러오기
    @State private var selectedIndex = 0                                  // 현재 선택된 탭 인덱스
    @State private var showTabManager = false                             // 탭 전환 화면 표시 여부

    var body: some View {
        ZStack {
            if let tab = tabs[safe: selectedIndex] {
                // URL이 있으면 WebView로 보여주기
                if let _ = tab.currentURL {
                    CustomWebView(
                        stateModel: tab.stateModel,
                        playerURL: $tabs[selectedIndex].playerURL,
                        showAVPlayer: $tabs[selectedIndex].showAVPlayer
                    )
                } else {
                    // URL이 없으면 대시보드 보여주기
                    DashboardView { url in
                        tab.stateModel.currentURL = url
                    }
                }
            }

            // 하단 도구 버튼 (탭 관리, 새 탭 생성)
            VStack {
                Spacer()
                HStack {
                    Button(action: { showTabManager = true }) {
                        Image(systemName: "square.on.square")
                    }
                    Spacer()
                    Button(action: addNewTab) {
                        Image(systemName: "plus")
                    }
                }
                .padding()
            }
        }
        // 탭 관리자 시트
        .sheet(isPresented: $showTabManager) {
            TabManager(
                tabs: $tabs,
                initialStateModel: tabs[selectedIndex].stateModel
            ) { chosen in
                if let idx = tabs.firstIndex(where: { $0.stateModel === chosen }) {
                    selectedIndex = idx
                }
            }
        }
        // 앱 종료 직전 탭 저장
        .onDisappear {
            TabPersistenceManager.saveTabs(tabs)
        }
    }

    // 새 탭 추가 함수
    private func addNewTab() {
        let new = WebTab()
        tabs.append(new)
        selectedIndex = tabs.count - 1
    }
}

// MARK: - 탭 선택 및 닫기 화면
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tabs: [WebTab]
    let initialStateModel: WebViewStateModel
    let onTabSelected: (WebViewStateModel) -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text("탭 목록").font(.title.bold()).padding(.top)

            ScrollView {
                ForEach(tabs) { tab in
                    HStack {
                        // 탭 선택 버튼
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
                        Button(action: { close(tab) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
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
                    .cornerRadius(8)
            }
            .padding()
        }
    }

    // 탭 제거
    private func close(_ tab: WebTab) {
        if let idx = tabs.firstIndex(of: tab) {
            tabs.remove(at: idx)
        }
    }
}

// MARK: - 안전한 배열 인덱스 접근 확장
extension Collection {
    subscript(safe idx: Index) -> Element? {
        indices.contains(idx) ? self[idx] : nil
    }
}