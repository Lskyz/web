import SwiftUI
import AVKit

// MARK: - 방문 기록 항목
struct WebViewHistoryItem: Codable {
    let url: String
    let title: String
}

// MARK: - 탭 세션 구조
struct WebTabSession: Codable {
    let tabID: UUID
    let currentIndex: Int
    let items: [WebViewHistoryItem]
}

// MARK: - WebTab 모델
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel
    var playerURL: URL? = nil
    var showAVPlayer: Bool = false

    var currentURL: URL? {
        stateModel.currentURL
    }

    init(url: URL? = nil) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = self.id
        self.stateModel.currentURL = url
    }

    init(fromSession session: WebTabSession) {
        self.id = session.tabID
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = session.tabID

        let urls = session.items.compactMap { URL(string: $0.url) }
        let index = session.currentIndex

        if urls.indices.contains(index) {
            let session = WebViewSession(urls: urls, currentIndex: index)
            self.stateModel.restoreSession(session)  // ✅ 세션 복원 실행
        }
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 저장/복원 관리
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

// MARK: - 탭 스냅샷
struct WebTabSnapshot: Codable {
    let session: WebTabSession
}

extension WebTab {
    func toSnapshot() -> WebTabSnapshot? {
        guard let session = stateModel.saveSession() else { return nil }

        let items = session.urls.map {
            WebViewHistoryItem(url: $0.absoluteString, title: "")
        }

        let sessionToSave = WebTabSession(tabID: id, currentIndex: session.currentIndex, items: items)
        return WebTabSnapshot(session: sessionToSave)
    }

    static func fromSnapshot(_ snapshot: WebTabSnapshot) -> WebTab {
        WebTab(fromSession: snapshot.session)
    }
}

// MARK: - 대시보드 뷰
struct DashboardView: View {
    @State private var inputURL: String = ""
    let onSelectURL: (URL) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("대시보드")
                .font(.largeTitle.bold())

            HStack(spacing: 40) {
                icon(title: "Google", url: "https://www.google.com")
                icon(title: "Naver", url: "https://www.naver.com")
            }

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

// MARK: - 브라우저 통합 뷰
struct UnifiedBrowserView: View {
    @State private var tabs: [WebTab] = TabPersistenceManager.loadTabs()
    @State private var selectedIndex: Int = 0
    @State private var showingTabManager = false

    var body: some View {
        ZStack {
            if let tab = tabs[safe: selectedIndex] {
                if let url = tab.currentURL {
                    CustomWebView(
                        stateModel: tab.stateModel,
                        playerURL: $tabs[selectedIndex].playerURL,
                        showAVPlayer: $tabs[selectedIndex].showAVPlayer
                    )
                } else {
                    DashboardView { url in
                        tabs[selectedIndex].stateModel.currentURL = url
                    }
                }
            }

            VStack {
                Spacer()
                HStack {
                    Button(action: { showingTabManager = true }) {
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
        .sheet(isPresented: $showingTabManager) {
            TabManager(
                tabs: $tabs,
                initialStateModel: tabs[selectedIndex].stateModel,
                onTabSelected: { selected in
                    if let idx = tabs.firstIndex(where: { $0.stateModel === selected }) {
                        selectedIndex = idx
                    }
                }
            )
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

// MARK: - 탭 전환 및 삭제
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
                        Button(action: {
                            closeTab(tab)
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                    .padding()
                }
            }

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

    private func closeTab(_ tab: WebTab) {
        if let idx = tabs.firstIndex(of: tab) {
            tabs.remove(at: idx)
        }
    }
}

// MARK: - 인덱스 안전 접근
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}