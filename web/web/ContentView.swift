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

    var body: some View {
        // ✅ 현재 선택된 탭의 인덱스 찾기
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            let selected = tabs[index]                   // 선택된 탭
            let state = selected.stateModel              // 선택된 탭의 상태 모델

            VStack(spacing: 0) {

                // 🔗 주소창 + 이동 버튼
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            // 전체 선택 처리
                            if !textFieldSelectedAll {
                                DispatchQueue.main.async {
                                    self.inputURL = self.inputURL
                                    UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                    textFieldSelectedAll = true
                                }
                            }
                        }
                        .onChange(of: isTextFieldFocused) { focused in
                            // 포커스 해제 시 전체선택 초기화
                            if !focused {
                                textFieldSelectedAll = false
                            }
                        }
                        .onSubmit {
                            // 주소창 제출 시 URL 이동
                            if let url = fixedURL(from: inputURL) {
                                state.currentURL = url
                            }
                            isTextFieldFocused = false
                        }
                        .overlay(
                            // ❌ 텍스트 지우기 버튼 (오른쪽)
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

                // 🌐 실제 웹 콘텐츠 뷰
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
                    // ◀️ 뒤로가기 버튼
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                    .disabled(!state.canGoBack)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // ▶️ 앞으로가기 버튼
                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right").font(.title2)
                    }
                    .disabled(!state.canGoForward)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 🔄 새로고침 버튼
                    Button(action: { state.reload() }) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 🕘 방문기록 버튼
                    Button(action: {
                        showHistorySheet = true
                    }) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    // 🗂️ 탭 관리자 진입 버튼
                    Button(action: {
                        showTabManager = true
                    }) {
                        Image(systemName: "square.on.square")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    // 📺 PIP 기능 토글 (UI 숨김)
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
            .onAppear {
                // 👉 탭 변경 시 상태 초기화 및 주소창 동기화
                selectedTabID = selected.id
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                }
            }
            .onReceive(state.$currentURL) { url in
                // 👉 URL 변경 시 주소창 동기화
                if let url = url {
                    inputURL = url.absoluteString
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { tabs[index].showAVPlayer },
                set: { tabs[index].showAVPlayer = $0 }
            )) {
                // 🎬 전체화면 AVPlayer
                if let url = tabs[index].playerURL {
                    AVPlayerView(url: url)
                }
            }
            .sheet(isPresented: $showHistorySheet) {
                // 📜 방문기록 보기
                NavigationView {
                    WebViewStateModel.HistoryPage(state: state)
                }
            }
            .fullScreenCover(isPresented: $showTabManager) {
                // 🗂️ 탭 관리자
                NavigationView {
                    TabManager(
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
            // ❗탭이 없을 경우 복구
            Text("탭 없음")
                .onAppear {
                    if let first = tabs.first {
                        selectedTabID = first.id
                    }
                }
        }
    }

    // 🔧 문자열을 유효한 URL로 변환하거나 검색 쿼리로 전환
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // http(s) 형식이면 그대로 사용
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 도메인 형식이면 자동 보정
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 검색어일 경우 구글 검색
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}