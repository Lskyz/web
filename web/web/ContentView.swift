import SwiftUI
import AVKit

/// 웹 브라우저의 메인 콘텐츠 뷰
struct ContentView: View {
    @Binding var tabs: [WebTab]                 // 전체 탭 배열
    @Binding var selectedTabIndex: Int          // 현재 선택된 탭 인덱스

    @State private var inputURL: String = ""    // 주소창 입력 값
    @FocusState private var isTextFieldFocused: Bool
    @State private var textFieldSelectedAll = false
    @State private var showHistorySheet = false
    @State private var showTabManager = false
    @State private var enablePIP: Bool = true

    // 🔎 디버깅용: 마지막 선택 인덱스를 기록해 전환 로그 남김
    @State private var lastSelectedTabIndex: Int? = nil

    var body: some View {
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel // 현재 탭 상태 모델

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

                // 웹 콘텐츠 영역
                if state.currentURL != nil {
                    // ✅ [수정 위치 #1] 탭별 WKWebView 분리를 위해 고유 id 부여
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
                    .id(tabs[selectedTabIndex].id) // ← 이 한 줄이 ‘다른 탭으로 URL 복제’ 현상 방지의 핵심
                    .onAppear {
                        TabPersistenceManager.debugMessages.append(
                            "CustomWebView 나타남: tabIndex=\(selectedTabIndex), tabID=\(tabs[selectedTabIndex].id.uuidString), currentURL=\(state.currentURL?.absoluteString ?? "nil")"
                        )
                    }
                } else {
                    // 첫 로딩 시 대시보드 뷰 표시
                    DashboardView(
                        onSelectURL: { selectedURL in
                            tabs[selectedTabIndex].stateModel.currentURL = selectedURL
                            TabPersistenceManager.debugMessages.append("대시보드에서 URL 선택: \(selectedURL) -> tabIndex=\(selectedTabIndex)")
                        },
                        triggerLoad: {
                            tabs[selectedTabIndex].stateModel.loadURLIfReady()
                            TabPersistenceManager.debugMessages.append("대시보드 URL 로드 트리거: tabIndex=\(selectedTabIndex)")
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

                    Button(action: {
                        TabPersistenceManager.debugMessages.append("탭 관리자 오픈")
                        showTabManager = true
                    }) {
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

                // 선택 전환 초기화
                if lastSelectedTabIndex == nil {
                    lastSelectedTabIndex = selectedTabIndex
                }
            }
            // 🔎 탭 배열이 바뀔 때 저장 + 탭 목록 로그
            .onChange(of: tabs) { _ in
                TabPersistenceManager.saveTabs(tabs)
                let ids = tabs.map { $0.id.uuidString }.joined(separator: ",")
                TabPersistenceManager.debugMessages.append("탭 배열 변경, 저장됨 | ids=[\(ids)] | selectedTabIndex=\(selectedTabIndex)")
            }
            // 🔎 현재 탭의 URL이 바뀌면 주소창도 동기화
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("URL 변경, 주소창 업데이트: \(url.absoluteString) | tabIndex=\(selectedTabIndex)")
                }
            }
            // 🔎 선택된 탭 인덱스 전환 로그
            .onChange(of: selectedTabIndex) { newIndex in
                let prev = lastSelectedTabIndex ?? -1
                let prevID = tabs.indices.contains(prev) ? tabs[prev].id.uuidString : "n/a"
                let newID = tabs.indices.contains(newIndex) ? tabs[newIndex].id.uuidString : "n/a"
                TabPersistenceManager.debugMessages.append("선택 탭 변경: \(prev) (\(prevID)) -> \(newIndex) (\(newID))")
                lastSelectedTabIndex = newIndex
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
                    // ✅ [수정 위치 #2] TabManager 콜백 시그니처: (Int) -> Void 유지
                    //   - 탭을 고를 때 stateModel 레퍼런스로 비교/공유하지 않고 ‘인덱스’만 넘겨서
                    //     다른 탭 URL이 덮이는 부작용 가능성을 낮춤.
                    TabManager(
                        tabs: $tabs,
                        initialStateModel: state,
                        onTabSelected: { index in
                            guard tabs.indices.contains(index) else {
                                TabPersistenceManager.debugMessages.append("탭 선택 실패: out-of-bounds \(index)")
                                return
                            }
                            selectedTabIndex = index
                            TabPersistenceManager.debugMessages.append("탭 선택 완료: index=\(index), tabID=\(tabs[index].id.uuidString)")
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
                    TabPersistenceManager.debugMessages.append("새 탭 생성 (대시보드): \(url) -> index=\(selectedTabIndex), id=\(newTab.id.uuidString)")
                },
                triggerLoad: {
                    // 주의: onSelectURL에서 탭 추가/선택 후이므로 인덱스 유효
                    if tabs.indices.contains(selectedTabIndex) {
                        tabs[selectedTabIndex].stateModel.loadURLIfReady()
                        TabPersistenceManager.debugMessages.append("대시보드 fallback 트리거: index=\(selectedTabIndex)")
                    } else {
                        TabPersistenceManager.debugMessages.append("대시보드 fallback 트리거 실패: invalid selectedTabIndex \(selectedTabIndex)")
                    }
                }
            )
        }
    }

    /// 사용자가 입력한 텍스트를 URL로 변환
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