import SwiftUI
import AVKit
import WebKit

// MARK: - WebTabSessionSnapshot: 탭 상태 저장/복원용 Codable 구조체
struct WebTabSessionSnapshot: Codable {
    let id: String // 탭 UUID 문자열
    let history: [String] // 방문한 URL 문자열 배열
    let index: Int // 현재 히스토리 인덱스
}

// MARK: - WebTab: 브라우저 탭 모델
struct WebTab: Identifiable, Equatable {
    let id: UUID // 탭 고유 식별자
    let stateModel: WebViewStateModel // WKWebView 상태 관리 객체
    var playerURL: URL? = nil // 비디오 재생 URL
    var showAVPlayer: Bool = false // AVPlayer 전체화면 여부

    var currentURL: URL? { stateModel.currentURL }
    var historyURLs: [String] { stateModel.historyURLs }
    var currentHistoryIndex: Int { stateModel.currentHistoryIndex }

    // MARK: - 초기화
    init(url: URL? = nil) {
        self.id = UUID()
        self.stateModel = WebViewStateModel()
        self.stateModel.tabID = self.id
        self.stateModel.currentURL = url
        TabPersistenceManager.debugMessages.append("새 탭 생성: ID \(id.uuidString)")
    }

    // MARK: - Equatable 구현
    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - 스냅샷 변환
    func toSnapshot() -> WebTabSessionSnapshot {
        let snapshot = WebTabSessionSnapshot(
            id: id.uuidString,
            history: historyURLs,
            index: currentHistoryIndex
        )
        TabPersistenceManager.debugMessages.append("스냅샷 생성: ID \(id.uuidString), \(historyURLs.count) URLs")
        return snapshot
    }
}

// MARK: - TabPersistenceManager: 탭 저장/복원 관리
enum TabPersistenceManager {
    private static let key = "savedTabs"
    static var debugMessages: [String] = [] // 디버깅 메시지 저장소

    // MARK: - 탭 배열 저장
    static func saveTabs(_ tabs: [WebTab]) {
        let snapshots = tabs.map { $0.toSnapshot() }
        TabPersistenceManager.debugMessages.append("저장 시도: 탭 \(tabs.count)개, 스냅샷: \(snapshots.map { "\($0.id): \($0.history.count) URLs, 인덱스 \($0.index)" })")
        do {
            let data = try JSONEncoder().encode(snapshots)
            UserDefaults.standard.set(data, forKey: key)
            TabPersistenceManager.debugMessages.append("저장 성공: 데이터 크기 \(data.count) 바이트")
        } catch {
            TabPersistenceManager.debugMessages.append("저장 실패: 인코딩 오류 - \(error.localizedDescription)")
        }
    }

    // MARK: - 저장된 탭 복원
    static func loadTabs() -> [WebTab] {
        if let data = UserDefaults.standard.data(forKey: key) {
            TabPersistenceManager.debugMessages.append("복원 시도: 데이터 크기 \(data.count) 바이트")
            do {
                let snapshots = try JSONDecoder().decode([WebTabSessionSnapshot].self, from: data)
                TabPersistenceManager.debugMessages.append("복원 성공: \(snapshots.count)개 탭 복원")
                return snapshots.map { snapshot in
                    let id = UUID(uuidString: snapshot.id) ?? UUID()
                    let urls = snapshot.history
                    let index = snapshot.index
                    TabPersistenceManager.debugMessages.append("탭 복원: ID \(id), URL \(urls), 인덱스 \(index)")
                    let tab = WebTab()
                    tab.stateModel.tabID = id
                    tab.stateModel.restoredHistoryURLs = urls
                    tab.stateModel.restoredHistoryIndex = index
                    return tab
                }
            } catch {
                TabPersistenceManager.debugMessages.append("복원 실패: 디코딩 오류 - \(error.localizedDescription)")
                return []
            }
        } else {
            TabPersistenceManager.debugMessages.append("복원 실패: UserDefaults에 데이터 없음")
            return []
        }
    }
}

// MARK: - DashboardView: URL 없는 탭의 홈 화면
struct DashboardView: View {
    @State private var inputURL: String = "" // URL 입력 필드
    let onSelectURL: (URL) -> Void // URL 선택 콜백

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
                        TabPersistenceManager.debugMessages.append("대시보드에서 URL 이동: \(url)")
                    }
                }
            }
            .padding(.top, 20)
            Spacer()
        }
        .padding()
    }

    // MARK: - 북마크 아이콘 버튼
    private func icon(title: String, url: String) -> some View {
        Button(action: {
            if let u = URL(string: url) {
                onSelectURL(u)
                TabPersistenceManager.debugMessages.append("북마크 이동: \(url)")
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

// MARK: - TabManager: 탭 목록 관리 뷰
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tabs: [WebTab]
    let initialStateModel: WebViewStateModel
    let onTabSelected: (WebViewStateModel) -> Void
    @State private var debugMessages: [String] = TabPersistenceManager.debugMessages
    @State private var showToast = false
    @State private var toastMessage = ""

    var body: some View {
        ZStack {
            VStack {
                Text("탭 목록")
                    .font(.title.bold())

                // MARK: - 디버깅 로그 표시
                VStack(alignment: .leading) {
                    Text("디버깅 로그")
                        .font(.headline)
                        .padding(.top)
                    ScrollView {
                        ForEach(debugMessages, id: \.self) { message in
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding(.vertical, 2)
                        }
                    }
                    .frame(maxHeight: 150)
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)
                }

                ScrollView {
                    ForEach(tabs) { tab in
                        HStack {
                            Button(action: {
                                onTabSelected(tab.stateModel)
                                dismiss()
                                TabPersistenceManager.debugMessages.append("탭 선택: ID \(tab.id.uuidString)")
                                debugMessages = TabPersistenceManager.debugMessages
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
                            Button(action: { closeTab(tab) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                        .padding()
                    }
                }

                Button(action: {
                    tabs.append(WebTab())
                    TabPersistenceManager.saveTabs(tabs)
                    dismiss()
                    TabPersistenceManager.debugMessages.append("새 탭 추가: ID \(tabs.last?.id.uuidString ?? "없음")")
                    debugMessages = TabPersistenceManager.debugMessages
                }) {
                    Label("새 탭", systemImage: "plus")
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()
            }

            // MARK: - 토스트 메시지
            if showToast {
                ToastView(message: toastMessage)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation {
                                showToast = false
                            }
                        }
                    }
            }
        }
        .onAppear {
            debugMessages = TabPersistenceManager.debugMessages
            if let lastMessage = debugMessages.last {
                toastMessage = lastMessage
                showToast = true
            }
        }
        .onChange(of: tabs) { _ in
            TabPersistenceManager.saveTabs(tabs)
            debugMessages = TabPersistenceManager.debugMessages
        }
    }

    // MARK: - 탭 닫기
    private func closeTab(_ tab: WebTab) {
        if let idx = tabs.firstIndex(of: tab) {
            tabs.remove(at: idx)
            TabPersistenceManager.saveTabs(tabs)
            TabPersistenceManager.debugMessages.append("탭 닫힘: ID \(tab.id.uuidString)")
            debugMessages = TabPersistenceManager.debugMessages
        }
    }
}

// MARK: - ToastView: 디버깅 메시지 표시
struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .padding()
            .background(Color.black.opacity(0.7))
            .foregroundColor(.white)
            .cornerRadius(10)
            .padding(.top, 50)
    }
}

// MARK: - Collection 확장: 안전한 인덱스 접근
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
