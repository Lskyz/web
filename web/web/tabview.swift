import SwiftUI

// ✅ 탭 리스트 + 전환/닫기 기능
struct TabManager: View {
    @Binding var tabs: [WebTab]              // 🔗 ContentView로부터 받은 탭 배열
    @Binding var selectedTabID: UUID         // 🔗 ContentView로부터 받은 현재 탭 ID
    @Environment(\.dismiss) var dismiss      // ⛔️ 닫기용 환경변수

    var body: some View {
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
                    dismiss() // ✅ 전환 후 sheet 닫기
                }
            }

            // ➕ 새 탭 추가 버튼
            Button(action: {
                let newTab = WebTab()
                tabs.append(newTab)
                selectedTabID = newTab.id
                dismiss() // ✅ 전환 후 sheet 닫기
            }) {
                Label("새 탭 열기", systemImage: "plus")
                    .font(.headline)
            }
            .padding(.vertical)
        }
        .navigationTitle("탭 목록")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("닫기") {
                    dismiss()
                }
            }
        }
    }

    // ✅ 탭 닫기 동작
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