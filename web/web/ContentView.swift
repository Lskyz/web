import SwiftUI
import AVKit

// ✅ ContentView: 메인 브라우저 화면 구성
struct ContentView: View {

    // 🗂️ 탭 목록 상태 (앱 실행 시 저장된 탭 복원)
    @State private var tabs: [WebTab] = {
        if let data = UserDefaults.standard.data(forKey: "savedTabSnapshots"),
           let snapshots = try? JSONDecoder().decode([WebTabSnapshot].self, from: data) {
            let restoredTabs = snapshots.map { WebTab.fromSnapshot($0) }
            return restoredTabs.isEmpty ? [WebTab(url: URL(string: "https://www.google.com")!)] : restoredTabs
        } else {
            return [WebTab(url: URL(string: "https://www.google.com")!)]
        }
    }()

    // 🌐 현재 선택된 탭 ID
    @State private var selectedTabID: UUID = {
        if let data = UserDefaults.standard.data(forKey: "savedTabSnapshots"),
           let snapshots = try? JSONDecoder().decode([WebTabSnapshot].self, from: data),
           let first = snapshots.first {
            return WebTab.fromSnapshot(first).id
        } else {
            return UUID()
        }
    }()

    // 🔠 주소 입력 필드 상태
    @State private var inputURL = "https://www.google.com"

    // 🔍 주소 입력창 포커스 여부
    @FocusState private var isTextFieldFocused: Bool

    // ✅ 텍스트필드 전체 선택 중복 방지용 플래그
    @State private var textFieldSelectedAll = false

    // 🖼️ PIP 기능 토글 (실제 UI에는 숨김 처리)
    @State private var enablePIP: Bool = true

    // 📜 방문기록 시트 표시 여부
    @State private var showHistorySheet = false

    // 🗂️ 탭 관리자 표시 여부
    @State private var showTabManager = false

    // ✅ 탭 스냅샷 저장 키
    let tabSnapshotKey = "savedTabSnapshots"

    var body: some View {
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            let selected = tabs[index]
            let state = selected.stateModel

            VStack(spacing: 0) {
                // 🔗 주소창과 이동 버튼
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

                    // ▶️ 이동 버튼
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

                // 🌐 웹 콘텐츠 영역
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

                // ⬅️➡️🔄 툴바
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

                    // 🕒 방문 기록 버튼
                    Button(action: {
                        showHistorySheet = true
                    }) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    // 📑 탭 목록 버튼
                    Button(action: {
                        showTabManager = true
                    }) {
                        Image(systemName: "square.on.square")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    // 🔄 PIP 토글 (숨김 처리됨)
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

            // ✅ 화면 진입 시 URL 동기화
            .onAppear {
                selectedTabID = selected.id
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                }
            }

            // ✅ 탭 변경 시 자동 저장
            .onChange(of: tabs) { newTabs in
                let snapshots = newTabs.compactMap { $0.toSnapshot() }
                if let data = try? JSONEncoder().encode(snapshots) {
                    UserDefaults.standard.set(data, forKey: tabSnapshotKey)
                }
            }

            // ✅ URL 변경 시 주소창 반영
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }

            // 🎥 전체화면 AVPlayer
            .fullScreenCover(isPresented: Binding(
                get: { tabs[index].showAVPlayer },
                set: { tabs[index].showAVPlayer = $0 }
            )) {
                if let url = tabs[index].playerURL {
                    AVPlayerView(url: url)
                }
            }

            // 📜 방문기록 시트
            .sheet(isPresented: $showHistorySheet) {
                NavigationView {
                    WebViewStateModel.HistoryPage(state: state)
                }
            }

            // 🗂️ 탭 목록 관리자
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
            // ❗탭이 비어있을 경우 대체 뷰
            Text("탭 없음")
                .onAppear {
                    if let first = tabs.first {
                        selectedTabID = first.id
                    }
                }
        }
    }

    // 🔧 입력값 → URL로 변환 또는 구글 검색으로 처리
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 명시적 http(s) URL인 경우
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 도메인 형식인 경우 (e.g., example.com)
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 일반 검색어 처리 → 구글 검색 URL 생성
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}