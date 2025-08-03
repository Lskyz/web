import SwiftUI
import AVKit

/// ✅ 메인 브라우저 인터페이스 뷰
struct ContentView: View {

    // 📌 외부에서 전달받은 탭 목록 (다중 탭 관리)
    @Binding var tabs: [WebTab]

    // 📌 현재 선택된 탭의 인덱스
    @Binding var selectedTabIndex: Int

    // 🔠 주소창 입력값 (URL 또는 검색어)
    @State private var inputURL: String = ""

    // 🔍 주소창 포커스 상태 추적
    @FocusState private var isTextFieldFocused: Bool

    // ✅ 텍스트 전체 선택 여부 (최초 클릭 시 사용)
    @State private var textFieldSelectedAll = false

    // 📜 방문 기록 시트 표시 여부
    @State private var showHistorySheet = false

    // 🗂️ 탭 관리자 시트 표시 여부
    @State private var showTabManager = false

    // 🎞️ PIP 모드 (화면에 표시되진 않음)
    @State private var enablePIP: Bool = true

    // 💾 탭 상태 저장 키
    let tabSnapshotKey = "savedTabSnapshots"

    var body: some View {
        // ✅ 현재 선택된 탭이 존재하는 경우
        if tabs.indices.contains(selectedTabIndex) {

            // 현재 탭의 상태 모델 참조
            let state = tabs[selectedTabIndex].stateModel

            VStack(spacing: 0) {
                // 🔗 주소 입력 필드와 이동 버튼
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            // 최초 클릭 시 전체 선택
                            if !textFieldSelectedAll {
                                DispatchQueue.main.async {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.selectAll(_:)),
                                        to: nil, from: nil, for: nil
                                    )
                                    textFieldSelectedAll = true
                                }
                            }
                        }
                        .onChange(of: isTextFieldFocused) { focused in
                            // 포커스 해제 시 전체 선택 상태 초기화
                            if !focused {
                                textFieldSelectedAll = false
                            }
                        }
                        .onSubmit {
                            // ⏎ 눌렀을 때 URL로 이동
                            if let url = fixedURL(from: inputURL) {
                                state.currentURL = url
                            }
                            isTextFieldFocused = false
                        }
                        .overlay(
                            HStack {
                                Spacer()
                                // ❌ 입력 지우기 버튼
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

                // ✅ 현재 URL이 있으면 WebView, 없으면 대시보드
                if let url = state.currentURL {
                    CustomWebView(
                        stateModel: state,
                        playerURL: Binding(
                            get: { tabs[selectedTabIndex].playerURL },
                            set: { tabs[selectedTabIndex].playerURL = $0 }
                        ),
                        showAVPlayer: Binding(
                            get: { tabs[selectedTabIndex].showAVPlayer },
                            set: { tabs[selectedTabIndex].showAVPlayer = $0 }
                        )
                    )
                } else {
                    // 🌟 새 탭 진입 시 대시보드 표시
                    DashboardView { selectedURL in
                        tabs[selectedTabIndex].stateModel.currentURL = selectedURL
                    }
                }

                // 🔧 하단 도구 버튼들
                HStack {
                    // ◀️ 뒤로가기
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                    .disabled(!state.canGoBack)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // ▶️ 앞으로가기
                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right").font(.title2)
                    }
                    .disabled(!state.canGoForward)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 🔁 새로고침
                    Button(action: { state.reload() }) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 🕘 방문기록 보기
                    Button(action: { showHistorySheet = true }) {
                        Image(systemName: "clock.arrow.circlepath").font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    // 📑 탭 관리 버튼
                    Button(action: { showTabManager = true }) {
                        Image(systemName: "square.on.square").font(.title2)
                    }
                    .padding(.horizontal, 8)

                    // 🎞️ PIP 토글 (숨김 처리됨)
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
                // ✅ 탭 진입 시 주소창 동기화
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                }

                // ✅ (중요!) pendingSession이 있다면 복원 실행
                if let session = state.pendingSession {
                    state.restoreSession(session)
                    tabs[selectedTabIndex].stateModel.pendingSession = nil
                }
            }
            .onChange(of: tabs) { newTabs in
                // ✅ 탭 배열 변경 시 자동 저장
                let snapshots = newTabs.compactMap { $0.toSnapshot() }
                if let data = try? JSONEncoder().encode(snapshots) {
                    UserDefaults.standard.set(data, forKey: tabSnapshotKey)
                }
            }
            .onReceive(state.$currentURL) { url in
                // ✅ URL 변경 시 주소창 실시간 업데이트
                if let url = url {
                    inputURL = url.absoluteString
                }
            }
            // 🎥 전체화면 AVPlayer
            .fullScreenCover(isPresented: Binding(
                get: { tabs[selectedTabIndex].showAVPlayer },
                set: { tabs[selectedTabIndex].showAVPlayer = $0 }
            )) {
                if let url = tabs[selectedTabIndex].playerURL {
                    AVPlayerView(url: url)
                }
            }
            // 📜 방문 기록 시트
            .sheet(isPresented: $showHistorySheet) {
                NavigationView {
                    WebViewStateModel.HistoryPage(state: state)
                }
            }
            // 🗂️ 탭 관리자 시트
            .fullScreenCover(isPresented: $showTabManager) {
                NavigationView {
                    TabManager(
                        tabs: $tabs,
                        initialStateModel: state,
                        onTabSelected: { selectedState in
                            if let index = tabs.firstIndex(where: { $0.stateModel === selectedState }) {
                                selectedTabIndex = index
                            }
                        }
                    )
                }
            }

        } else {
            // ❗탭이 전혀 없을 경우: 대시보드에서 새 탭 생성
            DashboardView { url in
                let newTab = WebTab(url: url)
                tabs.append(newTab)
                selectedTabIndex = tabs.count - 1
            }
        }
    }

    /// 🔧 입력값을 URL로 변환
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 명시적 http:// or https://
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 도메인 형태 자동 보정
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 검색어는 구글 검색 URL로 변환
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}