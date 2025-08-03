import SwiftUI
import AVKit

// MARK: - 탭 하나의 데이터
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

// MARK: - 탭 리스트 및 선택 뷰
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss

    // 🔗 현재 선택된 탭 상태 외부에 전달
    let initialStateModel: WebViewStateModel
    let onTabSelected: (WebViewStateModel) -> Void

    // 🔄 탭 배열 및 상태
    @State private var tabs: [WebTab] = []
    @State private var selectedTabID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Text("탭 목록")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(tabs) { tab in
                        Button(action: {
                            // ✅ 탭 선택
                            onTabSelected(tab.stateModel)
                            dismiss()
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tab.currentURL?.host ?? "새 탭")
                                        .font(.headline)
                                    Text(tab.currentURL?.absoluteString ?? "")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                // ❌ 닫기
                                Button(action: {
                                    closeTab(tab)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.title2)
                                }
                            }
                            .padding()
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(10)
                            .padding(.horizontal)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.top)
            }

            Divider()

            HStack {
                Spacer()
                Button(action: {
                    addNewTab()
                }) {
                    Label("새 탭 추가", systemImage: "plus")
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                Spacer()
            }
            .padding(.bottom, 20)
        }
        .onAppear {
            setupInitialTabs()
        }
    }

    // MARK: - 초기 탭 목록 구성
    private func setupInitialTabs() {
        // 기존 탭이 있다면 복사
        if tabs.isEmpty {
            let existing = WebTab(url: initialStateModel.currentURL ?? URL(string: "https://www.google.com")!)
            tabs.append(existing)
            selectedTabID = existing.id
        }
    }

    // MARK: - 새 탭 추가
    private func addNewTab() {
        let new = WebTab(url: URL(string: "https://www.apple.com")!)
        tabs.append(new)
        selectedTabID = new.id
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