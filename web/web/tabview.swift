import SwiftUI
import AVKit

// MARK: - WebTab 모델
struct WebTab: Identifiable, Equatable {
    let id: UUID                                  // 탭 고유 ID
    let stateModel: WebViewStateModel             // WebView 상태 관리 객체
    var playerURL: URL? = nil                     // AVPlayer URL (선택적)
    var showAVPlayer: Bool = false                // AVPlayer 표시 여부

    // 현재 페이지 URL
    var currentURL: URL? {
        stateModel.currentURL
    }

    // MARK: - 새 탭 생성
    init(url: URL? = nil) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = self.id
        self.stateModel.currentURL = url
    }

    // MARK: - 저장된 정보로 복원 (UserDefaults에서 로드된 dict)
    init(fromSaved dict: [String: String]) {
        self.id = UUID(uuidString: dict["id"] ?? "") ?? UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = self.id
        if let urlStr = dict["url"], let url = URL(string: urlStr) {
            self.stateModel.currentURL = url
        }
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 저장/복원 관리자
enum TabPersistenceManager {
    private static let key = "savedTabs"

    /// 탭 리스트의 ID와 현재 URL만 저장
    static func saveTabs(_ tabs: [WebTab]) {
        let info: [[String: String]] = tabs.map { tab in
            [
                "id": tab.id.uuidString,
                "url": tab.currentURL?.absoluteString ?? ""
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: []) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 저장된 탭 리스트 복원
    static func loadTabs() -> [WebTab] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: String]] else {
            return []
        }

        return raw.map { dict in
            WebTab(fromSaved: dict)
        }
    }
}

// MARK: - 대시보드
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

// MARK: - 통합 브라우저 및 탭 관리 (디버깅 뷰 제거)
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
        let newTab = WebTab()
        tabs.append(newTab)
        selectedIndex = tabs.count - 1
    }
}

// MARK: - Tab Manager
struct TabManager: View {
    @Environment(\\.dismiss) private var dismiss
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

// MARK: - 내부 프라이빗 Stack 접근 헬퍼
extension WebViewStateModel {
    func historyStackIfAny() -> [URL] {
        Mirror(reflecting: self).children.first { $0.label == "historyStack" }?.value as? [URL] ?? []
    }

    func currentIndexInSafeBounds() -> Int {
        Mirror(reflecting: self).children.first { $0.label == "currentIndexInStack" }?.value as? Int ?? -1
    }
}
