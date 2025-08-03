import SwiftUI
import AVKit

// ✅ ContentView: 메인 웹 브라우저 화면을 구성
struct ContentView: View {

    // 🗂️ 탭 목록 상태 (각 탭은 WebView 상태를 포함)
    @State private var tabs: [WebTab] = [WebTab(url: URL(string: "https://www.google.com")!)]

    // 🌐 현재 선택된 탭 ID
    @State private var selectedTabID: UUID = UUID()

    // 🔠 주소창 텍스트 상태
    @State private var inputURL = "https://www.google.com"

    // 🔍 주소창 포커스 여부
    @FocusState private var isTextFieldFocused: Bool

    // ✅ 전체 선택 중복 방지용 플래그
    @State private var textFieldSelectedAll = false

    // 🖼️ PIP (Picture in Picture) 기능 토글 상태
    @State private var enablePIP: Bool = true

    // 📜 방문기록 시트 표시 여부
    @State private var showHistorySheet = false

    // 🗂️ 탭 관리자 화면 표시 여부
    @State private var showTabManager = false

    // ✅ UserDefaults 키 (탭 저장용)
    let tabSnapshotKey = "savedTabSnapshots"

    var body: some View {
        // ✅ 현재 선택된 탭의 인덱스 찾기
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            let selected = tabs[index]
            let state = selected.stateModel

            VStack(spacing: 0) {
                // 🔗 주소창 및 이동 버튼
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            if !textFieldSelectedAll {
                                DispatchQueue.main.async {
                                    self.inputURL = self.inputURL
                                    UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                    textFieldSelectedAll = true
                                }
                            }
                        }
                        .onChange(of: isTextFieldFocused) { focused in
                            if !focused {
                                textFieldSelectedAll = false
                            }
                        }
                        .onSubmit {
                            if let url = fixedURL(from: inputURL) {
                                state.currentURL = url
                            }
                            isTextFieldFocused = false
                        }
                        .overlay(
                            HStack {
                                Spacer()
                                if !inputURL.isEmpty {
                                    Button(action: { inputURL = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                    .padding(.trailing, 8)
                                }
                            }
                        )

                    Button("이동") {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                        }
                        isTextFieldFocused = false
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // 🌐 웹 콘텐츠 뷰
                CustomWebView(
                    stateModel: state,
                    playerURL: Binding(
                        get: { tabs[index].playerURL },
                        set: { tabs[index].playerURL = $0 }
                    ),
                    showAVPlayer: Binding(
                        get: { tabs[index].showAVPlayer },
                        set: { tabs[index].showAVPlayer = $0 }
                    )
                )

                // ⬅️➡️🔄 하단 툴바
                HStack {
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                    .disabled(!state.canGoBack)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right").font(.title2)
                    }
                    .disabled(!state.canGoForward)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    Button(action: { state.reload() }) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    Button(action: {
                        showHistorySheet = true
                    }) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    Button(action: {
                        showTabManager = true
                    }) {
                        Image(systemName: "square.on.square")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Toggle(isOn: $enablePIP) {
                        Image(systemName: "pip.enter")
                    }
                    .labelsHidden()
                    .hidden()
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                .background(Color(UIColor.secondarySystemBackground))
            }
            .ignoresSafeArea(.keyboard)

            // ✅ 탭 복원 및 주소창 초기화
            .onAppear {
                selectedTabID = selected.id
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                }

                // ✅ 앱 시작 시 저장된 탭 복원
                if let data = UserDefaults.standard.data(forKey: tabSnapshotKey),
                   let snapshots = try? JSONDecoder().decode([WebTabSnapshot].self, from: data) {
                    let restoredTabs = snapshots.map { WebTab.fromSnapshot($0) }
                    if !restoredTabs.isEmpty {
                        tabs = restoredTabs
                        selectedTabID = restoredTabs.first?.id ?? UUID()
                    }
                }
            }

            // ✅ 탭 변경 감지 시 자동 저장
            .onChange(of: tabs) { newTabs in
                let snapshots = newTabs.compactMap { $0.toSnapshot() }
                if let data = try? JSONEncoder().encode(snapshots) {
                    UserDefaults.standard.set(data, forKey: tabSnapshotKey)
                }
            }

            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }

            .fullScreenCover(isPresented: Binding(
                get: { tabs[index].showAVPlayer },
                set: { tabs[index].showAVPlayer = $0 }
            )) {
                if let url = tabs[index].playerURL {
                    AVPlayerView(url: url)
                }
            }

            .sheet(isPresented: $showHistorySheet) {
                NavigationView {
                    WebViewStateModel.HistoryPage(state: state)
                }
            }

            .fullScreenCover(isPresented: $showTabManager) {
                NavigationView {
                    TabManager(
                        tabs: $tabs,
                        initialStateModel: state,
                        onTabSelected: { selectedState in
                            if let selectedTab = tabs.first(where: { $0.stateModel === selectedState }) {
                                selectedTabID = selectedTab.id
                            }
                        }
                    )
                }
            }

        } else {
            Text("탭 없음")
                .onAppear {
                    if let first = tabs.first {
                        selectedTabID = first.id
                    }
                }
        }
    }

    // 🔧 문자열을 URL로 변환 또는 검색으로 변경
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}

// ⛔️ 삭제된 중복 정의 (다른 파일에 이미 선언되어 있어야 함)
// struct WebTabSnapshot { ... }
// extension WebTab { toSnapshot, fromSnapshot }