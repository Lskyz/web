import SwiftUI
import AVKit

// MARK: 방문 기록 한 항목
struct WebViewHistoryItem: Codable {
    let url: String   // 실제 방문한 URL 스트링
    let title: String // 페이지 제목 (미사용 가능)
}

// MARK: 탭 하나의 세션 정보 (historyStack + currentIndex)
struct WebTabSession: Codable {
    let tabID: UUID
    let currentIndex: Int
    let items: [WebViewHistoryItem]
}

// MARK: 탭 모델 + 복원 관리
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel
    var playerURL: URL? = nil
    var showAVPlayer = false

    var currentURL: URL? { stateModel.currentURL }

    // 새 탭 생성 시
    init(url: URL? = nil) {
        id = UUID()
        stateModel = WebViewStateModel()
        stateModel.tabID = id
        stateModel.currentURL = url
    }

    // UserDefaults 에서 복원할 때
    init(fromSession session: WebTabSession) {
        id = session.tabID
        stateModel = WebViewStateModel()
        stateModel.tabID = id

        let urls = session.items.compactMap { URL(string: $0.url) }
        let idx  = session.currentIndex

        if urls.indices.contains(idx) {
            stateModel.restoreSession(WebViewSession(urls: urls, currentIndex: idx))
        } else if let u = urls.first {
            stateModel.currentURL = u
        }
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool { lhs.id == rhs.id }
}

// MARK: 저장용 snapshot 구조체
struct WebTabSnapshot: Codable {
    let session: WebTabSession
}

extension WebTab {
    func toSnapshot() -> WebTabSnapshot {
        // historyStack이 없어도 최소 현재 URL은 하나만 저장
        let seq = stateModel.historyStackIfAny()
        let items = seq.map { WebViewHistoryItem(url: $0.absoluteString, title: "") }
        let session = WebTabSession(tabID: id,
                                    currentIndex: stateModel.currentIndexIndexInSafeBounds(),
                                    items: items)
        return WebTabSnapshot(session: session)
    }

    static func fromSnapshot(_ snapshot: WebTabSnapshot) -> WebTab {
        WebTab(fromSession: snapshot.session)
    }
}

// MARK: UserDefaults 저장/복원 매니저
enum TabPersistenceManager {
    private static let key = "savedWebTabs"
    static func saveTabs(_ tabs: [WebTab]) {
        let arr = tabs.map { $0.toSnapshot() }
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    static func loadTabs() -> [WebTab] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([WebTabSnapshot].self, from: d)
        else { return [] }
        return arr.map(WebTab.fromSnapshot)
    }
}

// MARK: 통합 브라우저 뷰 담당
struct UnifiedBrowserView: View {
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs()
    @State private var selectedIndex = 0
    @State private var showTabManager = false

    var body: some View {
        ZStack {
            if let tab = tabs[safe: selectedIndex] {
                if let _ = tab.currentURL {
                    CustomWebView(
                        stateModel: tab.stateModel,
                        playerURL: $tabs[selectedIndex].playerURL,
                        showAVPlayer: $tabs[selectedIndex].showAVPlayer
                    )
                } else {
                    DashboardView { url in
                        tab.stateModel.currentURL = url
                    }
                }
            }
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
        .onDisappear {
            TabPersistenceManager.saveTabs(tabs)
        }
    }

    private func addNewTab() {
        let new = WebTab()
        tabs.append(new)
        selectedIndex = tabs.count - 1
    }
}

// MARK: 탭 관리자 화면
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
                        Button(action: {
                            onTabSelected(tab.stateModel)
                            dismiss()
                        }) {
                            VStack(alignment: .leading) {
                                Text(tab.currentURL?.host ?? "대시보드")
                                    .font(.headline)
                                Text(tab.currentURL?.absoluteString ?? "")
                                    .font(.caption).foregroundColor(.gray)
                            }
                        }
                        Spacer()
                        Button(action: { close(tab) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 4)
                }
            }
            Button(action: {
                tabs.append(WebTab()); dismiss()
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

    private func close(_ tab: WebTab) {
        if let idx = tabs.firstIndex(of: tab) {
            tabs.remove(at: idx)
        }
    }
}

// MARK: 안전한 인덱스 접근
extension Collection {
    subscript(safe idx: Index) -> Element? {
        indices.contains(idx) ? self[idx] : nil
    }
}