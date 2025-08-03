import SwiftUI
import AVKit

// MARK: - 하나의 탭 정보 구조체
struct WebTab: Identifiable, Equatable {
    let id: UUID                              // 각 탭을 구분하기 위한 고유 ID
    let stateModel: WebViewStateModel         // 해당 탭의 웹 상태 (URL, 방문기록 등)
    var playerURL: URL?                       // AVPlayer 재생용 URL
    var showAVPlayer: Bool                    // AVPlayer 전체화면 여부

    var currentURL: URL? {                    // 현재 탭의 URL (단축 접근자)
        stateModel.currentURL
    }

    // 초기 생성자 (URL 기반으로 탭 생성)
    init(url: URL) {
        self.id = UUID()                      // 새 UUID 생성
        self.stateModel = WebViewStateModel() // 상태 모델 초기화
        self.stateModel.currentURL = url      // 초기 URL 설정
        self.playerURL = nil                  // 초기 재생 URL 없음
        self.showAVPlayer = false             // PIP 꺼짐 상태
    }

    // Equatable 비교 (탭 ID 기준으로만 비교)
    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 탭 리스트 및 선택 화면 (탭 관리자 뷰)
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss // 시트를 닫기 위한 dismiss 액션

    let initialStateModel: WebViewStateModel    // 외부에서 전달된 현재 사용 중인 탭의 상태 모델
    let onTabSelected: (WebViewStateModel) -> Void // 탭 선택 시 호출할 콜백 함수

    @State private var tabs: [WebTab] = []      // 현재 존재하는 전체 탭 목록
    @State private var selectedTabID: UUID?     // 현재 선택된 탭의 ID (선택 시각화용)

    var body: some View {
        VStack(spacing: 0) {
            // 🧭 상단 제목
            Text("탭 목록")
                .font(.largeTitle.bold())
                .padding(.top, 20)

            // 📜 탭 리스트 출력
            ScrollView {
                VStack(spacing: 12) {
                    // 🔄 현재 탭으로 돌아가기 버튼
                    Button(action: {
                        onTabSelected(initialStateModel) // 기존 탭 그대로 사용
                        dismiss()                        // 시트 닫기
                    }) {
                        Label("현재 탭 계속 사용", systemImage: "arrow.uturn.backward")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)

                    // 📄 모든 탭 목록 출력
                    ForEach(tabs) { tab in
                        Button(action: {
                            onTabSelected(tab.stateModel) // 선택된 탭으로 전환
                            dismiss()                      // 시트 닫기
                        }) {
                            HStack {
                                // 🌐 주소 및 도메인 표시
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tab.currentURL?.host ?? "새 탭") // 호스트명 표시
                                        .font(.headline)

                                    Text(tab.currentURL?.absoluteString ?? "") // 전체 URL
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                }

                                Spacer()

                                // ✅ 현재 사용 중인 탭일 경우 뱃지 표시
                                if tab.stateModel === initialStateModel {
                                    Text("현재 탭")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .cornerRadius(6)
                                }

                                // ❌ 탭 닫기 버튼 (X 아이콘)
                                Button(action: {
                                    closeTab(tab) // 탭 삭제
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.title2)
                                }
                            }
                            .padding()
                            .background(
                                // ✅ 현재 탭이면 테두리 강조
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(tab.stateModel === initialStateModel ? Color.blue : Color.clear, lineWidth: 2)
                                    .background(Color(UIColor.secondarySystemBackground).cornerRadius(10))
                            )
                            .padding(.horizontal)
                        }
                        .buttonStyle(PlainButtonStyle()) // iOS 기본 스타일 제거
                    }
                }
                .padding(.top)
            }

            Divider() // 상단과 하단 구분선

            // ➕ 새 탭 추가 버튼
            HStack {
                Spacer()
                Button(action: {
                    addNewTab() // 새 탭 추가
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
            setupInitialTabs() // 탭 초기화
        }
    }

    // MARK: - 초기 탭 설정 (최소 1개 보장)
    private func setupInitialTabs() {
        if tabs.isEmpty {
            let existing = WebTab(url: initialStateModel.currentURL ?? URL(string: "https://www.google.com")!) // 전달된 URL 기준
            tabs.append(existing)      // 첫 탭 생성
            selectedTabID = existing.id
        }
    }

    // MARK: - 새 탭 추가 함수
    private func addNewTab() {
        let new = WebTab(url: URL(string: "https://www.apple.com")!) // 기본 URL 설정
        tabs.append(new)          // 탭 목록에 추가
        selectedTabID = new.id    // 해당 탭을 선택 상태로
    }

    // MARK: - 탭 닫기 함수
    private func closeTab(_ tab: WebTab) {
        if let index = tabs.firstIndex(of: tab) {
            tabs.remove(at: index) // 해당 탭 제거
            if tabs.isEmpty {
                addNewTab()        // 남은 탭이 없다면 새로 하나 추가
            } else if selectedTabID == tab.id {
                selectedTabID = tabs.first!.id // 닫힌 탭이 선택된 탭이면 다른 탭 선택
            }
        }
    }
}