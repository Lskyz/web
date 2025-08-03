import SwiftUI

// MARK: - 탭 하나를 구성하는 데이터 구조
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel            // ✅ 웹뷰 상태 모델
    var playerURL: URL?                          // ✅ AVPlayer용 URL
    var showAVPlayer: Bool                       // ✅ AVPlayer 표시 여부

    var currentURL: URL? {
        stateModel.currentURL
    }

    init(url: URL) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.currentURL = url
        self.playerURL = nil
        self.showAVPlayer = false
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ContentView를 재활용하기 위한 wrapper
struct ContentViewWrapper: View {
    var tab: WebTab

    var body: some View {
        ContentView(
            stateModel: tab.stateModel,
            playerURL: Binding(
                get: { tab.playerURL },
                set: { _ in } // ❗탭 목록에서 조작은 없음
            ),
            showAVPlayer: Binding(
                get: { tab.showAVPlayer },
                set: { _ in }
            )
        )
    }
}

// MARK: - 탭 리스트 화면 (sheet로 띄워짐)
struct TabListView: View {
    @Binding var tabs: [WebTab]
    @Binding var selectedTabID: UUID?
    @Binding var showSheet: Bool

    var body: some View {
        NavigationView {
            List {
                ForEach(tabs) { tab in
                    Button(action: {
                        selectedTabID = tab.id
                        showSheet = false
                    }) {
                        HStack {
                            Text(tab.currentURL?.absoluteString ?? "탭")
                                .lineLimit(1)
                            if tab.id == selectedTabID {
                                Spacer()
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteTab)
            }
            .navigationTitle("탭 목록")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("닫기") {
                        showSheet = false
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        addNewTab()
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    // MARK: - 새 탭 추가
    private func addNewTab() {
        let newTab = WebTab(url: URL(string: "https://www.apple.com")!)
        tabs.append(newTab)
        selectedTabID = newTab.id
        showSheet = false
    }

    // MARK: - 탭 삭제
    private func deleteTab(at offsets: IndexSet) {
        for index in offsets {
            let removed = tabs[index]
            tabs.remove(at: index)

            if removed.id == selectedTabID {
                selectedTabID = tabs.first?.id
            }
        }

        if tabs.isEmpty {
            addNewTab()
        }
    }
}

// MARK: - 탭 기능을 포함한 메인 매니저 뷰
struct TabManagerView: View {
    @State private var tabs: [WebTab] = [WebTab(url: URL(string: "https://www.google.com")!)]
    @State private var selectedTabID: UUID?
    @State private var showTabList = false

    var body: some View {
        ZStack {
            if let selectedTab = tabs.first(where: { $0.id == selectedTabID }) {
                ContentView(
                    stateModel: selectedTab.stateModel,
                    playerURL: Binding(
                        get: { selectedTab.playerURL },
                        set: { url in
                            if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                                tabs[index].playerURL = url
                            }
                        }
                    ),
                    showAVPlayer: Binding(
                        get: { selectedTab.showAVPlayer },
                        set: { value in
                            if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                                tabs[index].showAVPlayer = value
                            }
                        }
                    )
                )
            } else {
                Text("탭이 없습니다.")
            }
        }
        .sheet(isPresented: $showTabList) {
            TabListView(tabs: $tabs, selectedTabID: $selectedTabID, showSheet: $showTabList)
        }
        .onAppear {
            if selectedTabID == nil {
                selectedTabID = tabs.first?.id
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showTabList = true
                }) {
                    Image(systemName: "square.on.square")
                }
            }
        }
    }
}