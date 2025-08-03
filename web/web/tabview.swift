import SwiftUI

// MARK: - 탭 하나를 구성하는 데이터 구조
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel            // ✅ 네가 만든 상태 모델
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

// MARK: - 실제 탭 UI를 제어하는 뷰
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss     // ✅ 복귀용

    @State private var tabs: [WebTab] = [WebTab(url: URL(string: "https://www.google.com")!)]
    @State private var selectedTabID: UUID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            // 상단 탭 목록
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(tabs) { tab in
                        Button(action: {
                            selectedTabID = tab.id
                        }) {
                            Text(tab.currentURL?.host ?? "탭")
                                .padding(8)
                                .background(tab.id == selectedTabID ? Color.blue : Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .contextMenu {
                            Button("탭 닫기") {
                                closeTab(tab)
                            }
                        }
                    }

                    // 새 탭 추가
                    Button(action: {
                        addNewTab()
                    }) {
                        Image(systemName: "plus")
                            .padding(8)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }.padding(.horizontal)
            }

            Divider()

            // 실제 웹뷰 표시
            if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                let tab = tabs[index]

                // ✅ 네가 만든 CustomWebView 구조 그대로 사용
                CustomWebView(
                    stateModel: tab.stateModel,
                    playerURL: Binding(
                        get: { tabs[index].playerURL },
                        set: { tabs[index].playerURL = $0 }
                    ),
                    showAVPlayer: Binding(
                        get: { tabs[index].showAVPlayer },
                        set: { tabs[index].showAVPlayer = $0 }
                    )
                )
                .background(
                    NavigationLink(
                        destination: AVPView(url: tab.playerURL ?? URL(string: "about:blank")!),
                        isActive: Binding(
                            get: { tabs[index].showAVPlayer },
                            set: { tabs[index].showAVPlayer = $0 }
                        )
                    ) {
                        EmptyView()
                    }
                    .hidden()
                )
            } else {
                Text("탭 없음")
            }

            Divider()

            // ✅ 하단 제어 + 닫기 버튼 추가
            HStack {
                // 📥 ContentView로 복귀
                Button(action: {
                    dismiss()
                }) {
                    Label("닫기", systemImage: "chevron.down")
                        .padding(8)
                }

                Spacer()

                // ❌ 현재 탭 닫기
                Button("현재 탭 닫기") {
                    if let tab = tabs.first(where: { $0.id == selectedTabID }) {
                        closeTab(tab)
                    }
                }
                .padding()
            }
            .background(Color(UIColor.secondarySystemBackground))
        }
        .onAppear {
            if let first = tabs.first {
                selectedTabID = first.id
            }
        }
    }

    // MARK: - 새 탭 추가
    private func addNewTab() {
        let newTab = WebTab(url: URL(string: "https://www.apple.com")!)
        tabs.append(newTab)
        selectedTabID = newTab.id
    }

    // MARK: - 탭 닫기
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