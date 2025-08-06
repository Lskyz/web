import SwiftUI
import AVKit
import WebKit

/// 웹 브라우저의 메인 콘텐츠 뷰
struct ContentView: View {
    // MARK: - 속성 정의
    /// 전체 탭 배열
    @Binding var tabs: [WebTab]
    /// 현재 선택된 탭 인덱스
    @Binding var selectedTabIndex: Int

    /// 주소창 입력 값
    @State private var inputURL: String = ""
    /// 주소창 포커스 상태
    @FocusState private var isTextFieldFocused: Bool
    /// 텍스트 전체 선택 여부
    @State private var textFieldSelectedAll = false
    /// 방문 기록 시트 표시 여부
    @State private var showHistorySheet = false
    /// 탭 관리자 표시 여부
    @State private var showTabManager = false
    /// PIP 기능 토글 상태 (숨김 처리)
    @State private var enablePIP: Bool = true
    /// 주소창 표시 여부 (터치 또는 스크롤에 따라 동작)
    @State private var showAddressBar = false
    /// 웹 콘텐츠의 스크롤 이벤트 추적
    @State private var scrollOffset: CGFloat = 0
    /// 이전 스크롤 오프셋 (스크롤 방향 감지용)
    @State private var previousOffset: CGFloat = 0

    var body: some View {
        // MARK: - 본문 뷰
        // 현재 선택된 탭이 유효한지 확인
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel // 현재 탭의 상태 모델

            ZStack {
                // MARK: 웹 콘텐츠 영역
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
                    .id(state.tabID) // 탭별 WKWebView 인스턴스 분리 보장
                    .overlay(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(key: ScrollOffsetPreferenceKey.self, value: geometry.frame(in: .global).origin.y)
                        }
                    )
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                        // 스크롤 방향 감지 및 주소창 숨김
                        if offset < previousOffset && showAddressBar {
                            withAnimation {
                                showAddressBar = false
                            }
                        }
                        previousOffset = offset
                    }
                } else {
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

                // MARK: 주소창 (하단 버튼 바 위에 표시)
                if showAddressBar {
                    VStack {
                        Spacer() // 콘텐츠 아래로 밀어냄
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
                                                    .font(.system(size: 14))
                                            }
                                            .padding(.trailing, 8)
                                        }
                                    }
                                )
                                .frame(maxWidth: 300)
                                .transition(.opacity)
                        }
                        .padding()
                        .background(Color(.systemGray4)) // 약간 연한 회색 배경
                        .cornerRadius(10)
                        .padding(.horizontal)
                        // 버튼 바와의 간격
                        Spacer().frame(height: 10)
                    }
                    .zIndex(1) // 주소창을 최상단에 표시
                }

                // MARK: 하단 통합 툴바 (버튼만)
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Button(action: { state.goBack() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18))
                                .foregroundColor(state.canGoBack ? .black : .gray)
                        }
                        .disabled(!state.canGoBack)
                        .padding(.horizontal, 4)

                        Button(action: { state.goForward() }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 18))
                                .foregroundColor(state.canGoForward ? .black : .gray)
                        }
                        .disabled(!state.canGoForward)
                        .padding(.horizontal, 4)

                        Button(action: { state.reload() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18))
                        }
                        .padding(.horizontal, 4)

                        Button(action: { showTabManager = true }) {
                            Image(systemName: "square.on.square")
                                .font(.system(size: 18))
                        }
                        .padding(.horizontal, 4)

                        Button(action: { showHistorySheet = true }) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 18))
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding()
                    .background(Color(.systemGray4)) // 약간 연한 회색 배경
                    .cornerRadius(10)
                    .padding(.horizontal)
                }
            }
            .ignoresSafeArea(.keyboard)
            .onTapGesture {
                // 화면 아무 곳이나 터치 시 주소창 표시
                withAnimation {
                    showAddressBar = true
                }
            }

            // MARK: - 뷰 생명주기 및 이벤트
            .onAppear {
                // 진입 시 현재 URL 주소창에 동기화
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
                }
                // 세션 복원은 CustomWebView.makeUIView()에서 처리됨 (pendingSession 유지)
                TabPersistenceManager.debugMessages.append("히스토리 복원은 WebView 생성 시 처리 (pendingSession 유지)")
            }

            // 주소창 동기화 전용 (저장하지 않음)
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }

            // 네비게이션 '실제 완료' 시점에만 스냅샷 저장 + 히스토리 로그
            .onReceive(state.navigationDidFinish) { _ in
                if let wv = state.webView {
                    let back = wv.backForwardList.backList.count
                    let fwd = wv.backForwardList.forwardList.count
                    let cur = wv.url?.absoluteString ?? "없음"
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
                            // 탭 전환 직후 히스토리 스냅샷 로그 (저장은 navDidFinish에서 통일)
                            if let wv = tabs[index].stateModel.webView {
                                let back = wv.backForwardList.backList.count
                                let fwd = wv.backForwardList.forwardList.count
                                let cur = wv.url?.absoluteString ?? "없음"
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

// MARK: - 스크롤 오프셋 추적을 위한 PreferenceKey
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}