import SwiftUI
import AVKit

/// ✅ 메인 브라우저 인터페이스 뷰
struct ContentView: View {

    // 📌 외부에서 전달받은 탭 목록
    @Binding var tabs: [WebTab]

    // 📌 현재 선택된 탭의 인덱스 (탭 전환 시 사용)
    @Binding var selectedTabIndex: Int

    // 🔠 주소창에 입력된 문자열 (검색어나 URL)
    @State private var inputURL: String = ""

    // 🔍 텍스트 필드의 포커스 상태
    @FocusState private var isTextFieldFocused: Bool

    // ✅ 텍스트 필드 전체 선택을 한 번만 하기 위한 플래그
    @State private var textFieldSelectedAll = false

    // 📜 방문 기록 시트를 보여줄지 여부
    @State private var showHistorySheet = false

    // 🗂️ 탭 관리자 뷰를 보여줄지 여부
    @State private var showTabManager = false

    // 🎞️ PIP 모드 활성화 여부 (UI에서는 숨김 처리됨)
    @State private var enablePIP: Bool = true

    // 💾 UserDefaults 저장 키
    let tabSnapshotKey = "savedTabSnapshots"

    var body: some View {
        // ✅ 현재 선택된 탭이 유효한지 확인
        if tabs.indices.contains(selectedTabIndex) {

            // 📦 현재 탭의 상태 모델 가져오기
            let state = tabs[selectedTabIndex].stateModel

            VStack(spacing: 0) {
                // 🔗 주소 입력 필드와 "이동" 버튼
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)            // ⬛ 둥근 테두리
                        .autocapitalization(.none)                 // 🔠 자동 대문자 비활성
                        .disableAutocorrection(true)               // 🔤 자동 수정 비활성
                        .keyboardType(.URL)                        // ⌨️ URL 전용 키보드
                        .focused($isTextFieldFocused)              // 🧠 포커스 상태 연결
                        .onTapGesture {
                            // ✳️ 텍스트 전체 선택 (최초 한 번만)
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
                            // ✳️ 포커스 해제되면 초기화
                            if !focused {
                                textFieldSelectedAll = false
                            }
                        }
                        .onSubmit {
                            // ⏎ 엔터 입력 시 URL 이동
                            if let url = fixedURL(from: inputURL) {
                                state.currentURL = url
                            }
                            isTextFieldFocused = false
                        }
                        .overlay(
                            // ❌ 텍스트 필드 오른쪽 클리어 버튼
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
                        get: { tabs[selectedTabIndex].playerURL },
                        set: { tabs[selectedTabIndex].playerURL = $0 }
                    ),
                    showAVPlayer: Binding(
                        get: { tabs[selectedTabIndex].showAVPlayer },
                        set: { tabs[selectedTabIndex].showAVPlayer = $0 }
                    )
                )

                // 🔧 하단 네비게이션 바 (뒤로, 앞으로, 새로고침 등)
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
                    Button(action: { showHistorySheet = true }) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    // 📑 탭 관리자 버튼
                    Button(action: { showTabManager = true }) {
                        Image(systemName: "square.on.square")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    // 🔄 PIP 토글 (숨김 상태)
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

            // ✅ 화면 진입 시 주소창 업데이트
            .onAppear {
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                }
            }

            // ✅ 탭 배열이 변경되면 자동 저장
            .onChange(of: tabs) { newTabs in
                let snapshots = newTabs.compactMap { $0.toSnapshot() }
                if let data = try? JSONEncoder().encode(snapshots) {
                    UserDefaults.standard.set(data, forKey: tabSnapshotKey)
                }
            }

            // ✅ URL 변경 시 주소창 동기화
            .onReceive(state.$currentURL) { url in
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

            // 🗂️ 탭 관리자 뷰
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
            // ❗예외 처리: 선택된 인덱스가 유효하지 않은 경우
            Text("탭 없음")
                .onAppear {
                    if !tabs.isEmpty {
                        selectedTabIndex = 0
                    }
                }
        }
    }

    /// 🔧 주소 또는 검색어를 URL로 변환
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 명시적인 http:// 또는 https:// 포함
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 2. example.com 형태의 도메인 자동 보정
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 3. 검색어는 구글 검색 URL로 변환
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}