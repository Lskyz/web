import SwiftUI
import AVKit
import WebKit

// MARK: - WebTabSessionSnapshot: 탭 상태 저장/복원용 Codable 구조체
struct WebTabSessionSnapshot: Codable {
    let id: String          // 탭 UUID 문자열(= WebTab.id)
    let history: [String]   // 방문한 URL 문자열 배열 (back + current + forward)
    let index: Int          // 현재 히스토리 인덱스 (= backList.count)
}

// MARK: - WebTab: 브라우저 탭 모델
/// 탭의 식별자(UUID)와 ViewModel(WebViewStateModel)을 하나로 묶는 모델.
/// ✅ 포인트:
///  - 생성 시 stateModel.tabID를 항상 WebTab.id와 일치시켜 SwiftUI .id(...)와 매칭
///  - 스냅샷 저장 시에는 webView의 back/forward 기준으로 정확한 히스토리/인덱스 보존
///  - "복원 전용 init" 추가: 저장돼 있던 id/history/index로 정확히 재구성
struct WebTab: Identifiable, Equatable {
    let id: UUID
    let stateModel: WebViewStateModel
    var playerURL: URL? = nil
    var showAVPlayer: Bool = false

    // 읽기 편의 프로퍼티(기존 기능 유지)
    var currentURL: URL? { stateModel.currentURL }
    var historyURLs: [String] { stateModel.historyURLs }
    var currentHistoryIndex: Int { stateModel.currentHistoryIndex }

    // MARK: 기본 생성자 (새 탭)
    init(url: URL? = nil) {
        let newID = UUID()
        let model = WebViewStateModel()
        model.tabID = newID             // ✅ 탭과 모델 ID를 일치
        model.currentURL = url          // (초기 URL 있으면 세팅)
        self.id = newID
        self.stateModel = model
        TabPersistenceManager.debugMessages.append("새 탭 생성: ID \(id.uuidString)")
    }

    // MARK: 복원 전용 생성자
    /// 저장된 스냅샷(id/history/index)로 탭을 재구성한다.
    /// - history: 문자열 배열을 그대로 받아 내부에서 URL 배열로 변환
    /// - index: backList 기준 인덱스
    init(restoredID: UUID, restoredHistory: [String], restoredIndex: Int) {
        self.id = restoredID
        let model = WebViewStateModel()
        model.tabID = restoredID        // ✅ 탭과 모델 ID를 일치

        // 복원용 세션을 만들어 모델에 전달 (WKWebView는 makeUIView에서 실제 복원)
        let urls = restoredHistory.compactMap { URL(string: $0) }
        let safeIndex = max(0, min(restoredIndex, max(0, urls.count - 1)))
        if !urls.isEmpty {
            // restoreSession은 isRestoringSession 플래그/스택/현재 URL/pendingSession까지 설정
            model.restoreSession(WebViewSession(urls: urls, currentIndex: safeIndex))
        } else {
            // 히스토리 없으면 currentURL 없음(대시보드)
            model.currentURL = nil
        }

        self.stateModel = model
        TabPersistenceManager.debugMessages.append("복원 탭 생성: ID \(restoredID.uuidString), \(urls.count) URLs, 인덱스 \(safeIndex)")
    }

    static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - 스냅샷 변환 (히스토리와 인덱스 정확히 저장)
    /// webView가 있으면 back/forward 리스트 기준으로, 없으면 커스텀 스택 기준으로 저장
    func toSnapshot() -> WebTabSessionSnapshot {
        // 저장 전에 혹시라도 모델 ID가 어긋나 있으면 정렬
        alignIDsIfNeeded()

        let history = stateModel.historyStackIfAny().map { $0.absoluteString }
        let index = stateModel.currentIndexInSafeBounds()
        let snapshot = WebTabSessionSnapshot(id: id.uuidString, history: history, index: index)
        TabPersistenceManager.debugMessages.append("스냅샷 생성: ID \(id.uuidString), \(history.count) URLs, 인덱스 \(index)")
        return snapshot
    }

    /// 내부 편의: stateModel.tabID를 WebTab.id와 동기화 (저장 전에 방어)
    private func alignIDsIfNeeded() {
        if stateModel.tabID != id {
            stateModel.tabID = id
            TabPersistenceManager.debugMessages.append("ID 정렬: stateModel.tabID <- \(id.uuidString)")
        }
    }
}

// MARK: - TabPersistenceManager: 탭 저장/복원 관리
enum TabPersistenceManager {
    private static let key = "savedTabs"
    static var debugMessages: [String] = []

    // MARK: 저장
    /// 현재 열려있는 모든 탭을 스냅샷으로 직렬화하여 UserDefaults에 저장
    static func saveTabs(_ tabs: [WebTab]) {
        // 저장 직전 모든 탭의 ID 일치성을 한번 더 보장(방어)
        tabs.forEach { tab in
            if tab.stateModel.tabID != tab.id {
                tab.stateModel.tabID = tab.id
                TabPersistenceManager.debugMessages.append("저장 전 정렬: \(tab.id.uuidString)")
            }
        }

        let snapshots = tabs.map { $0.toSnapshot() }
        TabPersistenceManager.debugMessages.append("저장 시도: 탭 \(tabs.count)개, 스냅샷 요약: \(snapshots.map { "\($0.id): \($0.history.count) URLs, idx=\($0.index)" })")
        do {
            let data = try JSONEncoder().encode(snapshots)
            UserDefaults.standard.set(data, forKey: key)
            TabPersistenceManager.debugMessages.append("저장 성공: 데이터 크기 \(data.count) 바이트")
        } catch {
            TabPersistenceManager.debugMessages.append("저장 실패: 인코딩 오류 - \(error.localizedDescription)")
        }
    }

    // MARK: 복원
    /// 저장된 스냅샷을 읽어 WebTab 배열로 재구성
    static func loadTabs() -> [WebTab] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            TabPersistenceManager.debugMessages.append("복원 실패: UserDefaults에 데이터 없음")
            return []
        }

        TabPersistenceManager.debugMessages.append("복원 시도: 데이터 크기 \(data.count) 바이트")
        do {
            let snapshots = try JSONDecoder().decode([WebTabSessionSnapshot].self, from: data)
            TabPersistenceManager.debugMessages.append("복원 성공: \(snapshots.count)개 탭 복원")

            // 저장돼 있던 id/history/index로 정확히 탭을 복원
            let tabs: [WebTab] = snapshots.map { snap in
                let rid = UUID(uuidString: snap.id) ?? UUID()
                let hist = snap.history
                let idx  = max(0, min(snap.index, max(0, hist.count - 1)))
                TabPersistenceManager.debugMessages.append("탭 복원 준비: ID \(rid.uuidString), URLs \(hist.count), idx \(idx)")

                // ✅ 복원 전용 init 사용 (stateModel.tabID == id 유지)
                let restored = WebTab(restoredID: rid, restoredHistory: hist, restoredIndex: idx)
                return restored
            }
            return tabs
        } catch {
            TabPersistenceManager.debugMessages.append("복원 실패: 디코딩 오류 - \(error.localizedDescription)")
            return []
        }
    }
}

// ✅ (이미 존재) WebViewStateModel 유틸: 현재 URL이 준비되면 로드
extension WebViewStateModel {
    func loadURLIfReady() {
        if let url = currentURL, let webView = webView {
            webView.load(URLRequest(url: url))
            TabPersistenceManager.debugMessages.append("URL 로드 시도: \(url.absoluteString)")
        } else {
            TabPersistenceManager.debugMessages.append("URL 로드 실패: WebView 또는 URL 없음")
        }
    }
}

// MARK: - DashboardView: URL 없는 탭의 홈 화면
struct DashboardView: View {
    @State private var inputURL: String = ""
    let onSelectURL: (URL) -> Void
    let triggerLoad: () -> Void // 대시보드에서 URL 선택 후 실제 로드 트리거

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
                    guard let url = URL(string: inputURL) else { return }
                    onSelectURL(url)
                    // 약간 딜레이 후 실제 로드 트리거 (WebView 연결 타이밍 보정)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        triggerLoad()
                    }
                    TabPersistenceManager.debugMessages.append("대시보드에서 URL 이동: \(url)")
                }
            }
            .padding(.top, 20)
            Spacer()
        }
        .padding()
    }

    private func icon(title: String, url: String) -> some View {
        Button(action: {
            guard let u = URL(string: url) else { return }
            onSelectURL(u)
            // 약간 딜레이 후 실제 로드 트리거 (WebView 연결 타이밍 보정)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                triggerLoad()
            }
            TabPersistenceManager.debugMessages.append("북마크 이동: \(url)")
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
/// ✅ 변경점 유지:
///  - onTabSelected는 ViewModel가 아닌 "인덱스"를 넘겨 참조 엉킴 방지
///  - 탭 추가/삭제 시 저장 호출 유지
struct TabManager: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tabs: [WebTab]
    let initialStateModel: WebViewStateModel

    // MARK: 🔧 [유지] 참조 공유 방지: stateModel 대신 "인덱스"를 넘긴다.
    let onTabSelected: (Int) -> Void

    @State private var debugMessages: [String] = TabPersistenceManager.debugMessages
    @State private var showToast = false
    @State private var toastMessage = ""

    var body: some View {
        ZStack {
            VStack {
                Text("탭 목록")
                    .font(.title.bold())

                // 디버깅 로그 영역 (유지)
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

                // 탭 리스트
                ScrollView {
                    ForEach(tabs) { tab in
                        HStack {
                            Button(action: {
                                // 인덱스를 계산하여 콜백으로 전달
                                if let index = tabs.firstIndex(of: tab) {
                                    onTabSelected(index)
                                    dismiss()
                                    TabPersistenceManager.debugMessages.append("탭 선택: 인덱스 \(index) (ID \(tab.id.uuidString))")
                                    debugMessages = TabPersistenceManager.debugMessages
                                }
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

                // 새 탭 버튼
                Button(action: {
                    let newTab = WebTab(url: nil)
                    var tmp = tabs
                    tmp.append(newTab)
                    // 저장은 ContentView의 navDidFinish에서도 되지만,
                    // 생성/삭제 같은 구조 변경은 즉시 저장
                    TabPersistenceManager.saveTabs(tmp)
                    tabs = tmp

                    if let newIndex = tabs.firstIndex(of: newTab) {
                        onTabSelected(newIndex)
                    }

                    dismiss()
                    TabPersistenceManager.debugMessages.append("새 탭 추가: ID \(newTab.id.uuidString), 대시보드 표시")
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

            // 토스트
            if showToast {
                ToastView(message: toastMessage)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showToast = false }
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
            // 리스트 변경 시 저장(구조 변경)
            TabPersistenceManager.saveTabs(tabs)
            debugMessages = TabPersistenceManager.debugMessages
        }
    }

    private func closeTab(_ tab: WebTab) {
        if let idx = tabs.firstIndex(of: tab) {
            var tmp = tabs
            tmp.remove(at: idx)
            TabPersistenceManager.saveTabs(tmp)
            tabs = tmp
            TabPersistenceManager.debugMessages.append("탭 닫힘: ID \(tab.id.uuidString)")
            debugMessages = TabPersistenceManager.debugMessages
        }
    }
}

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

// 안전 인덱싱 확장 (기존 기능 유지)
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}