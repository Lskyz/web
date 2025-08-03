import SwiftUI
import AVKit

// MARK: - 하나의 탭 정보 구조체
struct WebTab: Identifiable, Equatable {
    let id: UUID                              // 각 탭을 구분하기 위한 고유 ID
    let stateModel: WebViewStateModel         // 해당 탭의 웹 상태 (URL, 방문기록 등)
    var playerURL: URL?                       // AVPlayer 재생용 URL
    var showAVPlayer: Bool                    // AVPlayer 전체화면 여부

    var currentURL: URL? {
        stateModel.currentURL
    }

    // 초기 생성자
    init(url: URL) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.currentURL = url
        self.playerURL = nil
        self.showAVPlayer = false
    }

    // Equatable 비교 (탭 ID 기준)
    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 리스트 및 선택 화면
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss

    // 외부에서 전달받은 현재 탭 상태
    let initialStateModel: WebViewStateModel
    // 탭 선택 시 호출할 클로저
    let onTabSelected: (WebViewStateModel) -> Void

    // 전체 탭 목록 및 현재 선택된 탭 ID
    @State private var tabs: [WebTab] = []
    @State private var selectedTabID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // 🧭 제목
            Text("탭 목록")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            ScrollView {
                VStack(spacing: 12) {
                    
                    // 🔄 현재 탭으로 돌아가기
                    Button(action: {
                        onTabSelected(initialStateModel)
                        dismiss()
                    }) {
                        Label("현재 탭 계속 사용", systemImage: "arrow.uturn.backward")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)

                    // 📄 탭 목록
                    ForEach(tabs) { tab in
                        Button(action: {
                            // 탭 선택 시 호출
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
                                        .lineLimit(1)
                                }

                                Spacer()

                                // ✅ 현재 탭 표시 뱃지
                                if tab.stateModel === initialStateModel {
                                    Text("현재 탭")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
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
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(tab.stateModel === initialStateModel ? Color.blue : Color.clear, lineWidth: 2)
                                    .background(Color(UIColor.secondarySystemBackground).cornerRadius(10))
                            )
                            .padding(.horizontal)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.top)
            }

            Divider()

            // ➕ 새 탭 추가 버튼
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

    // MARK: - 초기 탭 설정 (최소 1개 보장)
    private func setupInitialTabs() {
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

    // MARK: - 탭 닫기 로직
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