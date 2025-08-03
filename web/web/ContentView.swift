import SwiftUI
import AVKit

// ✅ ContentView: 메인 브라우저 인터페이스
struct ContentView: View {

    // 📌 탭 목록 (외부에서 바인딩으로 주입됨)
    @Binding var tabs: [WebTab]

    // 📌 선택된 탭 인덱스 (외부에서 주입됨)
    @Binding var selectedTabIndex: Int

    // 🔠 주소 입력 필드 내용
    @State private var inputURL: String = ""

    // 🔍 텍스트필드 포커스 상태 관리
    @FocusState private var isTextFieldFocused: Bool

    // ✅ 텍스트 전체 선택 중복 방지
    @State private var textFieldSelectedAll = false

    // 📜 방문기록 시트 표시 여부
    @State private var showHistorySheet = false

    // 🗂️ 탭 관리자 시트 표시 여부
    @State private var showTabManager = false

    // 🎞️ PIP 기능 활성화 여부 (UI에는 표시하지 않음)
    @State private var enablePIP: Bool = true

    // 💾 탭 스냅샷 저장 키
    let tabSnapshotKey = "savedTabSnapshots"

    var body: some View {
        // ✅ 선택된 탭 인덱스가 유효한지 확인
        if tabs.indices.contains(selectedTabIndex) {

            // 🧭 현재 선택된 탭과 상태모델 가져오기
            let selectedTab = tabs[selectedTabIndex]
            let state = selectedTab.stateModel

            VStack(spacing: 0) {
                // 🔗 주소 입력창 및 이동 버튼
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)                  // ⬛ 모서리 둥근 텍스트필드
                        .autocapitalization(.none)                      // 🔠 자동 대문자 비활성
                        .disableAutocorrection(true)                    // 🔤 자동수정 비활성
                        .keyboardType(.URL)                             // ⌨️ URL 입력 키보드
                        .focused($isTextFieldFocused)                   // 🧠 포커스 상태 바인딩
                        .onTapGesture {
                            // ✳️ 텍스트 전체 선택 (한 번만)
                            if !textFieldSelectedAll {
                                DispatchQueue.main.async {
                                    UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                    textFieldSelectedAll = true
                                }
                            }
                        }
                        .onChange(of: isTextFieldFocused) { focused in
                            // ✳️ 포커스 해제되면 플래그 초기화
                            if !focused {
                                textFieldSelectedAll = false
                            }
                        }
                        .onSubmit {
                            // ⏎ 입력 확정 시 URL로 이동
                            if let url = fixedURL(from: inputURL) {
                                state.currentURL = url
                            }
                            isTextFieldFocused = false
                        }
                        .overlay(
                            // ❌ 주소창 오른쪽에 클리어 버튼
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

                    // ▶️ "이동" 버튼
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

                // 🌐 웹 콘텐츠를 표시하는 WebView
                CustomWebView(
                    stateModel: state,
                    playerURL: Binding(
                        get: { selectedTab.playerURL },
                        set: { selectedTab.playerURL = $0 }
                    ),
                    showAVPlayer: Binding(
                        get: { selectedTab.showAVPlayer },
                        set: { selectedTab.showAVPlayer = $0 }
                    )
                )

                // 🔻 하단 툴바 (← → 새로고침 기록 탭 PIP)
                HStack {
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                    .disabled(!state.canGoBack)                        // ⛔ 뒤로가기 불가능 시 비활성화
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

                    // 🕒 방문기록 보기 버튼
                    Button(action: {
                        showHistorySheet = true
                    }) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    // 📑 탭 관리자 버튼
                    Button(action: {
                        showTabManager = true
                    }) {
                        Image(systemName: "square.on.square")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    // 🔄 PIP 토글 스위치 (숨김 처리됨)
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

            // ✅ 첫 진입 시 주소창 초기화
            .onAppear {
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                }
            }

            // ✅ 탭 배열 변경 시 자동 저장
            .onChange(of: tabs) { newTabs in
                let snapshots = newTabs.compactMap { $0.toSnapshot() }
                if let data = try? JSONEncoder().encode(snapshots) {
                    UserDefaults.standard.set(data, forKey: tabSnapshotKey)
                }
            }

            // ✅ 웹 탐색 중 주소창 동기화
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }

            // 🎥 전체화면 AVPlayer 뷰 (사용자 요청 시 표시)
            .fullScreenCover(isPresented: Binding(
                get: { selectedTab.showAVPlayer },
                set: { selectedTab.showAVPlayer = $0 }
            )) {
                if let url = selectedTab.playerURL {
                    AVPlayerView(url: url)
                }
            }

            // 📜 방문기록 시트 표시
            .sheet(isPresented: $showHistorySheet) {
                NavigationView {
                    WebViewStateModel.HistoryPage(state: state)
                }
            }

            // 🗂️ 탭 관리자 표시
            .fullScreenCover(isPresented: $showTabManager) {
                NavigationView {
                    TabManager(
                        tabs: $tabs,
                        initialStateModel: state,
                        onTabSelected: { selectedState in
                            if let newIndex = tabs.firstIndex(where: { $0.stateModel === selectedState }) {
                                selectedTabIndex = newIndex
                            }
                        }
                    )
                }
            }

        } else {
            // ❗선택된 인덱스가 유효하지 않은 경우
            Text("탭 없음")
                .onAppear {
                    if !tabs.isEmpty {
                        selectedTabIndex = 0
                    }
                }
        }
    }

    // 🔧 입력값을 URL로 변환하거나 검색 쿼리로 처리
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // http:// 또는 https:// 포함된 URL
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // www.example.com 형태인 경우 https:// 붙여서 처리
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 일반 검색어로 판단하고 구글 검색
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}