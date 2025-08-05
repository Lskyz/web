import SwiftUI
import AVKit

/// 웹 브라우저의 메인 콘텐츠 뷰
struct ContentView: View {
    @Binding var tabs: [WebTab]                 // 전체 탭 배열
    @Binding var selectedTabIndex: Int          // 현재 선택된 탭 인덱스

    @State private var inputURL: String = ""    // 주소창 입력 값
    @FocusState private var isTextFieldFocused: Bool
    @State private var textFieldSelectedAll = false   // 텍스트 전체 선택 여부
    @State private var showHistorySheet = false       // 방문 기록 시트 표시 여부
    @State private var showTabManager = false         // 탭 관리자 표시 여부
    @State private var enablePIP: Bool = true         // PIP 기능 토글 상태

    var body: some View {
        // 현재 선택된 탭이 유효한지 확인
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel // 현재 탭의 상태 모델

            VStack(spacing: 0) {
                // MARK: 주소 입력창
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            // 전체 텍스트 선택
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
                            // 포커스 해제 시 플래그 리셋
                            if !focused {
                                textFieldSelectedAll = false
                                TabPersistenceManager.debugMessages.append("주소창 포커스 해제")
                            }
                        }
                        .onSubmit {
                            // 엔터 입력 시 URL 이동
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

                // MARK: 웹 콘텐츠 영역
                if state.currentURL != nil {
                    // 실제 웹 페이지를 렌더링하는 WebView
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
                    // URL이 없으면 대시보드(홈) 화면 표시
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

                // MARK: 브라우저 컨트롤 바
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

            // MARK: 뷰 생명주기 & 이벤트
            .onAppear {
                // 진입 시 현재 URL 주소창에 동기화
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
                }
                // 세션 복원은 CustomWebView.makeUIView()에서 처리됨 (pendingSession 유지)
                TabPersistenceManager.debugMessages.append("히스토리 복원은 WebView 생성 시 처리 (pendingSession 유지)")
            }

            // ✅ 주소창 동기화 전용 (여기선 저장하지 않음)
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }

            // ✅ 네비게이션 실제 완료 시점에만 스냅샷 저장 + 히스토리 로그
            .onReceive(state.navigationDidFinish) { _ in
                if let wv = state.webView {
                    let back = wv.backForwardList.backList.count
                    let fwd  = wv.backForwardList.forwardList.count
                    let cur  = wv.url?.absoluteString ?? "없음"
                    TabPersistenceManager.debugMessages.append("HIST ⏪\(back) ▶︎\(fwd) | \(cur)")
                } else {
                    TabPersistenceManager.debugMessages.append("HIST 웹뷰 미연결")
                }
                // 통일된 저장 타이밍
                TabPersistenceManager.saveTabs(tabs)
                TabPersistenceManager.debugMessages.append("탭 스냅샷 저장(네비게이션 완료)")
            }

            .sheet(isPresented: $showHistorySheet) {
                // 방문 기록 시트
                NavigationView {
                    WebViewStateModel.HistoryPage(state: state)
                }
            }

            .fullScreenCover(isPresented: $showTabManager) {
                // TabManager: onTabSelected는 인덱스를 직접 전달
                NavigationView {
                    TabManager(
                        tabs: $tabs,
                        initialStateModel: state,
                        onTabSelected: { index in
                            selectedTabIndex = index
                            // 탭 전환 직후 히스토리 스냅샷 로그(저장은 navDidFinish에서 통일)
                            if let wv = tabs[index].stateModel.webView {
                                let back = wv.backForwardList.backList.count
                                let fwd  = wv.backForwardList.forwardList.count
                                let cur  = wv.url?.absoluteString ?? "없음"
                                TabPersistenceManager.debugMessages.append("HIST(tab \(index)) ⏪\(back) ▶︎\(fwd) | \(cur)")
                            } else {
                                TabPersistenceManager.debugMessages.append("HIST(tab \(index)) 준비중")
                            }
                        }
                    )
                }
            }

            .fullScreenCover(isPresented: Binding(
                get: { tabs[selectedTabIndex].showAVPlayer },
                set: { tabs[selectedTabIndex].showAVPlayer = $0 }
            )) {
                // PIP 전체 화면
                if let url = tabs[selectedTabIndex].playerURL {
                    AVPlayerView(url: url)
                }
            }

        } else {
            // 탭이 비어있을 때 대시보드로 시작
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

    /// 사용자가 입력한 텍스트를 올바른 URL로 변환
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