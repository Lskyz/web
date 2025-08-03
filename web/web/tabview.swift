import SwiftUI
import AVKit

// MARK: - 탭 데이터 구조
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel
    var playerURL: URL?
    var showAVPlayer: Bool

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

// MARK: - 탭 관리자 View (탭 리스트 + 전환 UI)
struct TabManager: View {
    // ✅ ContentView에서 넘겨받은 초기 상태
    let initialStateModel: WebViewStateModel

    // ✅ 탭 선택 시 반영할 콜백
    let onTabSelected: (WebViewStateModel) -> Void

    // ✅ 내부 탭 상태
    @Environment(\.dismiss) private var dismiss
    @State private var tabs: [WebTab] = []
    @State private var selectedTabID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Text("탭 선택").font(.headline).padding(.top)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(tabs) { tab in
                        HStack {
                            // ✅ 도메인 표시 (간단한 썸네일 역할)
                            VStack(alignment: .leading) {
                                Text(tab.currentURL?.host ?? "새 탭")
                                    .font(.headline)
                                Text(tab.currentURL?.absoluteString ?? "")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }

                            Spacer()

                            // ✅ 전환 버튼
                            Button(action: {
                                if let model = tab.stateModel {
                                    onTabSelected(model)
                                }
                                dismiss()
                            }) {
                                Text("전환")
                                    .font(.subheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            }

                            // ❌ 탭 닫기 버튼
                            Button(action: {
                                closeTab(tab)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.title2)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                }
            }

            Divider()

            // ➕ 새 탭 추가
            Button(action: addNewTab) {
                HStack {
                    Image(systemName: "plus")
                    Text("새 탭 열기")
                }
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding(.horizontal)
            }
            .padding(.bottom, 16)
        }
        .onAppear {
            // ✅ 기존 상태를 포함한 기본 탭 구성
            let first = WebTab(url: initialStateModel.currentURL ?? URL(string: "https://www.google.com")!)
            first.stateModel.copy(from: initialStateModel)
            tabs = [first]
            selectedTabID = first.id
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
                selectedTabID = tabs.first?.id
            }
        }
    }
}