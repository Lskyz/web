import SwiftUI

// MARK: - 탭 하나를 구성하는 데이터 구조
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel            // ✅ WebView 상태 모델
    var playerURL: URL?                          // ✅ AVPlayer용 URL
    var showAVPlayer: Bool                       // ✅ AVPlayer 표시 여부

    var currentURL: URL? {
        stateModel.currentURL
    }

    init(stateModel: WebViewStateModel) {
        self.id = UUID()
        self.stateModel = stateModel
        self.playerURL = nil
        self.showAVPlayer = false
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 리스트 및 전환 로직 포함
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss

    // ✅ ContentView에서 넘어온 최초 탭
    let initialStateModel: WebViewStateModel

    // ✅ 선택된 탭을 다시 넘겨주는 콜백
    let onTabSelected: (WebViewStateModel) -> Void

    // 🧠 내부 탭 상태 목록 및 선택된 탭 ID
    @State private var tabs: [WebTab] = []
    @State private var selectedTabID: UUID?

    var body: some View {
        VStack {
            Text("탭 목록")
                .font(.headline)
                .padding(.top, 20)

            List {
                ForEach(tabs) { tab in
                    Button(action: {
                        // ✅ 탭 선택 → 콜백 호출 → 화면 복귀
                        onTabSelected(tab.stateModel)
                        dismiss()
                    }) {
                        HStack {
                            Text(tab.currentURL?.absoluteString ?? "빈 탭")
                                .lineLimit(1)
                            Spacer()
                            if tab.id == selectedTabID {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteTab)
            }

            HStack {
                Spacer()

                // ➕ 새 탭 추가
                Button(action: {
                    let newState = WebViewStateModel()
                    newState.currentURL = URL(string: "https://www.apple.com")
                    let newTab = WebTab(stateModel: newState)
                    tabs.append(newTab)
                    selectedTabID = newTab.id
                }) {
                    Label("새 탭", systemImage: "plus")
                }

                Spacer()

                // ✅ 닫기 (전환 안 하고 복귀)
                Button("닫기") {
                    dismiss()
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            // ✅ 초기 탭 목록에 현재 탭 삽입 (중복 방지)
            if tabs.isEmpty {
                let firstTab = WebTab(stateModel: initialStateModel)
                tabs.append(firstTab)
                selectedTabID = firstTab.id
            }
        }
    }

    // MARK: - 탭 삭제
    private func deleteTab(at offsets: IndexSet) {
        tabs.remove(atOffsets: offsets)
        if let first = tabs.first {
            selectedTabID = first.id
        } else {
            // 탭이 다 사라졌을 때 하나는 자동 생성
            let fallback = WebViewStateModel()
            fallback.currentURL = URL(string: "https://www.google.com")
            let fallbackTab = WebTab(stateModel: fallback)
            tabs.append(fallbackTab)
            selectedTabID = fallbackTab.id
        }
    }
}