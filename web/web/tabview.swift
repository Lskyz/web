import SwiftUI
import AVKit

// MARK: - 탭 하나의 데이터 구조
struct WebTab: Identifiable, Equatable {
    let id = UUID()
    let stateModel = WebViewStateModel() // ✅ 각각 독립적인 상태 보존
    var playerURL: URL? = nil
    var showAVPlayer: Bool = false

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 전체를 관리하는 뷰
struct TabManager: View {
    @State private var tabs: [WebTab] = [WebTab()] // ✅ 최소 1개 탭
    @State private var selectedTabID: UUID = UUID() // ✅ 현재 표시 중인 탭
    @State private var showTabList = false          // ✅ 탭 리스트 보기

    var body: some View {
        ZStack {
            // ✅ 현재 선택된 탭만 렌더링
            if let selected = tabs.first(where: { $0.id == selectedTabID }) {
                ContentView(
                    state: selected.stateModel,
                    playerURL: Binding(
                        get: { selected.playerURL },
                        set: { newValue in
                            if let i = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                                tabs[i].playerURL = newValue
                            }
                        }
                    ),
                    showAVPlayer: Binding(
                        get: { selected.showAVPlayer },
                        set: { newValue in
                            if let i = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                                tabs[i].showAVPlayer = newValue
                            }
                        }
                    ),
                    onTabListRequested: {
                        showTabList = true
                    }
                )
            }

        }
        // ✅ 탭 목록 Sheet
        .sheet(isPresented: $showTabList) {
            NavigationView {
                List {
                    ForEach(tabs) { tab in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(tab.stateModel.currentURL?.host ?? "새 탭")
                                    .font(.headline)
                                Text(tab.stateModel.currentURL?.absoluteString ?? "")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Button(action: {
                                closeTab(tab)
                            }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.red)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedTabID = tab.id
                            showTabList = false
                        }
                    }

                    // ➕ 새 탭 추가
                    Button(action: {
                        let newTab = WebTab()
                        tabs.append(newTab)
                        selectedTabID = newTab.id
                        showTabList = false
                    }) {
                        Label("새 탭 열기", systemImage: "plus")
                            .font(.headline)
                    }
                    .padding(.vertical)
                }
                .navigationTitle("탭 목록")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { showTabList = false }
                    }
                }
            }
        }
        .onAppear {
            if let first = tabs.first {
                selectedTabID = first.id
            }
        }
    }

    // MARK: - 탭 닫기
    private func closeTab(_ tab: WebTab) {
        if let index = tabs.firstIndex(of: tab) {
            tabs.remove(at: index)
            if tabs.isEmpty {
                let newTab = WebTab()
                tabs.append(newTab)
                selectedTabID = newTab.id
            } else if selectedTabID == tab.id {
                selectedTabID = tabs.first!.id
            }
        }
    }
}