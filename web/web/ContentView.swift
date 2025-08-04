import SwiftUI
import AVKit

// MARK: - 메인 브라우저 인터페이스 뷰
struct ContentView: View {
    @Binding var tabs: [WebTab] // 탭 목록
    @Binding var selectedTabIndex: Int // 현재 선택된 탭 인덱스
    @State private var inputURL: String = "" // 주소창 입력값
    @FocusState private var isTextFieldFocused: Bool // 주소창 포커스 상태
    @State private var textFieldSelectedAll = false // 텍스트 전체 선택 여부
    @State private var showHistorySheet = false // 방문 기록 시트 표시 여부
    @State private var showTabManager = false // 탭 관리자 시트 표시 여부
    @State private var enablePIP: Bool = true // PiP 모드 (숨김)
    let tabSnapshotKey = "savedTabSnapshots" // 탭 스냅샷 저장 키

    var body: some View {
        // 현재 선택된 탭이 유효한 경우
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel

            VStack(spacing: 0) {
                // 주소 입력 필드와 이동 버튼
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            // 최초 클릭 시 텍스트 전체 선택
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
                            // 포커스 해제 시 선택 상태 초기화
                            if !focused {
                                textFieldSelectedAll = false
                            }
                        }
                        .onSubmit {
                            // Enter 키 입력 시 URL 이동
                            if let url = fixedURL(from: inputURL) {
                                state.currentURL = url
                                TabPersistenceManager.debugMessages.append("주소창에서 URL 이동: \(url)")
                            }
                            isTextFieldFocused = false
                        }
                        .overlay(
                            HStack {
                                Spacer()
                                // 입력 지우기 버튼
                                if !inputURL.isEmpty {
                                    Button(action: { inputURL = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                    .padding(.trailing, 8)
                                }
                            }
                        )

                    // 이동 버튼
                    Button("이동") {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                            TabPersistenceManager.debugMessages.append("이동 버튼으로 URL 이동: \(url)")
                        }
                        isTextFieldFocused = false
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // 현재 URL이 있으면 WebView, 없으면 대시보드
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
                    DashboardView { selectedURL in
                        tabs[selectedTabIndex].stateModel.currentURL = selectedURL
                        TabPersistenceManager.debugMessages.append("대시보드에서 URL 선택: \(selectedURL)")
                    }
                }

                // 하단 도구 버튼
                HStack {
                    // 뒤로가기
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                    .disabled(!state.canGoBack)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 앞으로가기
                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right").font(.title2)
                    }
                    .disabled(!state.canGoForward)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 새로고침
                    Button(action: { state.reload() }) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 방문 기록 보기
                    Button(action: { showHistorySheet = true }) {
                        Image(systemName: "clock.arrow.circlepath").font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    // 탭 관리자
                    Button(action: { showTabManager = true }) {
                        Image(systemName: "square.on.square").font(.title2)
                    }
                    .padding(.horizontal, 8)

                    // PiP 토글 (숨김)
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
                // 탭 진입 시 주소창 동기화
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                }
                // pendingSession 복원
                if let session = state.pendingSession {
                    state.restoreSession(session)
                    tabs[selectedTabIndex].stateModel.pendingSession = nil
                    TabPersistenceManager.debugMessages.append("pendingSession 복원: 탭 \(state.tabID?.uuidString ?? "없음")")
                }
            }
            .onChange(of: tabs) { newTabs in
                // 탭 배열 변경 시 스냅샷 저장
                TabPersistenceManager.saveTabs(newTabs)
            }
            .onReceive(state.$currentURL) { url in
                // URL 변경 시 주소창 업데이트
                if let url = url {
                    inputURL = url.absoluteString
                }
            }
            // 전체화면 AVPlayer
            .fullScreenCover(isPresented: Binding(
                get: { tabs[selectedTabIndex].showAVPlayer },
                set: { tabs[selectedTabIndex].showAVPlayer = $0 }
            )) {
                if let url = tabs[selectedTabIndex].playerURL {
                    AVPlayerView(url: url)
                }
            }
            // 방문 기록 시트
            .sheet(isPresented: $showHistorySheet) {
                NavigationView {
                    WebViewStateModel.HistoryPage(state: state)
                }
            }
            // 탭 관리자 시트
            .fullScreenCover(isPresented: $showTabManager) {
                NavigationView {
                    TabManager(
                        tabs: $tabs,
                        initialStateModel: state,
                        onTabSelected: { selectedState in
                            if let index = tabs.firstIndex(where: { $0.stateModel === selectedState }) {
                                selectedTabIndex = index
                                TabPersistenceManager.debugMessages.append("탭 선택: 인덱스 \(index)")
                            }
                        }
                    )
                }
            }
        } else {
            // 탭이 없는 경우 대시보드 표시
            DashboardView { url in
                let newTab = WebTab(url: url)
                tabs.append(newTab)
                selectedTabIndex = tabs.count - 1
                TabPersistenceManager.debugMessages.append("새 탭 생성 (대시보드): \(url)")
                TabPersistenceManager.saveTabs(tabs)
            }
        }
    }

    // 입력값을 URL로 변환
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
