import SwiftUI
import AVKit

struct ContentView: View {
    @Binding var tabs: [WebTab] // 전체 탭 배열
    @Binding var selectedTabIndex: Int // 선택된 탭 인덱스
    @State private var inputURL: String = "" // 주소창 텍스트 입력값
    @FocusState private var isTextFieldFocused: Bool // 포커스 여부
    @State private var textFieldSelectedAll = false // 전체 선택 여부
    @State private var showHistorySheet = false // 방문기록 시트 표시 여부
    @State private var showTabManager = false // 탭 관리자 표시 여부
    @State private var enablePIP: Bool = true // PIP 토글 (숨김 상태)

    var body: some View {
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel

            VStack(spacing: 0) {
                // 주소창 입력 필드
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
                            if !focused {
                                textFieldSelectedAll = false
                                TabPersistenceManager.debugMessages.append("주소창 포커스 해제")
                            }
                        }
                        .onSubmit {
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

                // 웹뷰 or 대시보드
                if state.currentURL != nil {
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
                    // 🛠 수정됨: DashboardView에서 triggerLoad 추가
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

                // 컨트롤 바 (뒤로/앞으로/새로고침/기록/탭)
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
                    .hidden()
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                .background(Color(UIColor.secondarySystemBackground))
            }
            .ignoresSafeArea(.keyboard)
            .onAppear {
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
                }
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
                if let url = url {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("URL 변경, 주소창 업데이트: \(url)")
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { tabs[selectedTabIndex].showAVPlayer },
                set: { tabs[selectedTabIndex].showAVPlayer = $0 }
            )) {
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
                            if let index = tabs.firstIndex(where: { $0.stateModel === selectedState }) {
                                selectedTabIndex = index
                                TabPersistenceManager.debugMessages.append("탭 선택: 인덱스 \(index)")
                            }
                        }
                    )
                }
            }
        } else {
            // 🛠 수정됨: fallback DashboardView에도 triggerLoad 추가
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

    /// 입력값에서 유효한 URL로 변환
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