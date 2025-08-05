import SwiftUI
import AVKit

/// 웹 브라우저의 메인 콘텐츠 뷰
struct ContentView: View {
    @Binding var tabs: [WebTab] // 전체 탭 배열
    @Binding var selectedTabIndex: Int // 현재 선택된 탭 인덱스

    @State private var inputURL: String = "" // 주소창 입력 값
    @FocusState private var isTextFieldFocused: Bool // 주소창 포커스 상태
    @State private var textFieldSelectedAll = false // 텍스트 전체 선택 여부
    @State private var showHistorySheet = false // 방문 기록 시트 표시 여부
    @State private var showTabManager = false // 탭 관리자 표시 여부
    @State private var enablePIP: Bool = true // PIP 기능 (화면 속 화면) 토글 상태

    var body: some View {
        // 현재 인덱스가 유효한 경우
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel // 현재 탭의 상태 모델

            VStack(spacing: 0) {
                // 주소 입력창 UI
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            // 텍스트 전체 선택
                            if !textFieldSelectedAll {
                                DispatchQueue.main.async {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.selectAll(_:)),
                                        to: nil, from: nil, for: nil
                                    )
                                    textFieldSelectedAll = true
                                    TabPersistenceManager.debugMessages.append("주소창 텍스트 전체 선택")
                                }
                            }
                        }
                        .onChange(of: isTextFieldFocused) { focused in
                            // 포커스 해제 시 상태 초기화
                            if !focused {
                                textFieldSelectedAll = false
                                TabPersistenceManager.debugMessages.append("주소창 포커스 해제")
                            }
                        }
                        .onSubmit {
                            // 주소창에서 엔터 입력 시 이동
                            if let url = fixedURL(from: inputURL) {
                                state.currentURL = url
                                TabPersistenceManager.debugMessages.append("주소창에서 URL 이동: \(url)")
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
                        // 이동 버튼 클릭 시 URL 이동
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

                // 웹 콘텐츠 영역
                if state.currentURL != nil {
                    // 웹 페이지를 보여주는 WebView
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
                    // 첫 로딩 시 대시보드 뷰 표시
                    DashboardView(
                        onSelectURL: { selectedURL in
                            tabs[selectedTabIndex].stateModel.currentURL = selectedURL
                            TabPersistenceManager.debugMessages.append("대시보드에서 URL 선택: \(selectedURL)")
                        },
                        triggerLoad: {
                            tabs[selectedTabIndex].stateModel.loadURLIfReady()
                            TabPersistenceManager.debugMessages.append("대시보드 URL 로드 트리거")
                        }
                    )
                }

                // 브라우저 컨트롤 바
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

                    Button(action: { showHistorySheet = true }) {
                        Image(systemName: "clock.arrow.circlepath").font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    Button(action: { showTabManager = true }) {
                        Image(systemName: "square.on.square").font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Toggle(isOn: $enablePIP) {
                        Image(systemName: "pip.enter")
                    }
                    .labelsHidden()
                    .hidden() // 기본적으로 숨김
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                .background(Color(UIColor.secondarySystemBackground))
            }
            .ignoresSafeArea(.keyboard)
            .onAppear {
                // 현재 URL을 주소창에 반영
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
                }

                // 복원할 세션이 있다면 복원
                if let session = state.pendingSession {
                    state.restoreSession(session)
                    tabs[selectedTabIndex].stateModel.pendingSession = nil
                    TabPersistenceManager.debugMessages.append("pendingSession 복원: 탭 \(state.tabID?.uuidString ?? "없음")")
                }
            }
            .onChange(of: tabs) { _ in
                TabPersistenceManager.saveTabs(tabs)
                TabPersistenceManager.debugMessages.append("탭 배열 변경, 저장됨")
            }
            .onReceive(state.$currentURL) { url in
                // URL 변경 감지하여 주소창 업데이트
                if let url = url {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("URL 변경, 주소창 업데이트: \(url)")
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { tabs[selectedTabIndex].showAVPlayer },
                set: { tabs[selectedTabIndex].showAVPlayer = $0 }
            )) {
                // AVPlayer 전체 화면 재생
                if let url = tabs[selectedTabIndex].playerURL {
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
                            // 탭 선택 시 해당 인덱스로 이동
                            if let index = tabs.firstIndex(where: { $0.stateModel === selectedState }) {
                                selectedTabIndex = index
                                TabPersistenceManager.debugMessages.append("탭 선택: 인덱스 \(index)")
                            }
                        }
                    )
                }
            }
        } else {
            // 탭이 비어있을 때 fallback 대시보드 뷰
            DashboardView(
                onSelectURL: { url in
                    let newTab = WebTab(url: url)
                    tabs.append(newTab)
                    selectedTabIndex = tabs.count - 1
                    TabPersistenceManager.saveTabs(tabs)
                    TabPersistenceManager.debugMessages.append("새 탭 생성 (대시보드): \(url)")
                },
                triggerLoad: {
                    tabs[selectedTabIndex].stateModel.loadURLIfReady()
                    TabPersistenceManager.debugMessages.append("대시보드 fallback 트리거")
                }
            )
        }
    }

    /// 사용자가 입력한 텍스트를 URL로 변환하는 함수
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 검색어인 경우 구글 검색 URL로 변환
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}