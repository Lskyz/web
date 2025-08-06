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
    /// 키보드 표시 여부(레이아웃 변화를 스크롤로 오인하지 않기 위함)
    @State private var isKeyboardVisible: Bool = false

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
                        // 글로벌 프레임 변화를 통한 간접 스크롤 감지 (기존 로직 유지)
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: ScrollOffsetPreferenceKey.self,
                                    value: geometry.frame(in: .global).origin.y
                                )
                        }
                    )
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                        // ⛳️ 키보드 보임/텍스트필드 포커스 중에는 자동 숨김 막기
                        if isKeyboardVisible || isTextFieldFocused {
                            previousOffset = offset
                            return
                        }
                        // 스크롤 방향 감지 및 주소창 자동 숨김
                        if offset < previousOffset && showAddressBar {
                            withAnimation {
                                showAddressBar = false
                                isTextFieldFocused = false // 숨김 시 키보드도 내림
                            }
                        }
                        previousOffset = offset
                    }
                    // 👉 콘텐츠 영역 탭 제스처: 주소창 토글(보이기/숨기기)
                    .contentShape(Rectangle()) // 빈 영역도 탭 인식
                    .onTapGesture {
                        withAnimation {
                            if showAddressBar {
                                // 이미 보이는 상태에서 다시 터치 → 숨김
                                showAddressBar = false
                                isTextFieldFocused = false
                            } else {
                                // 숨김 상태에서 터치 → 표시 + 포커스
                                showAddressBar = true
                                DispatchQueue.main.async {
                                    isTextFieldFocused = true
                                }
                            }
                        }
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
                    // 📌 대시보드 화면에서도 동일한 탭 동작 제공
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation {
                            if showAddressBar {
                                showAddressBar = false
                                isTextFieldFocused = false
                            } else {
                                showAddressBar = true
                                DispatchQueue.main.async {
                                    isTextFieldFocused = true
                                }
                            }
                        }
                    }
                }
            }
            // ⛔️ 키보드 세이프에어리어를 무시하지 않음: 아래 safeAreaInset 콘텐츠가 키보드 위로 자동 이동
            // (즉, .ignoresSafeArea(.keyboard) 사용하지 않음)

            // MARK: - 키보드 노티 구독 (보임/숨김)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
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

            // 💡 하단 UI를 safeAreaInset으로 구성 (배경 투명)
            // - 툴바가 가장 아래(버튼 바), 주소창은 "바로 위"
            // - 키보드가 나타나면 자동으로 키보드 위로 이동
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    // 주소창 (조건부 표시) — 툴바 "바로 위"
                    if showAddressBar {
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
                        }
                        // 내부 패딩을 작게 조정해 차지 면적 최소화
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        // 🎨 바 표면만 색상 적용 (#F8F9FA), 바깥은 완전 투명
                        .background(Color(red: 248/255, green: 249/255, blue: 250/255))
                        .cornerRadius(10)
                        // 바깥쪽 여백 최소화 (수평만 소폭)
                        .padding(.horizontal, 8)
                        .transition(.opacity)
                    }

                    // 하단 통합 툴바 (버튼만) — 항상 표시
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
                    // 내부 패딩 최소화
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    // 🎨 바 표면만 색상 적용 (#F8F9FA)
                    .background(Color(red: 248/255, green: 249/255, blue: 250/255))
                    .cornerRadius(10)
                    // 바깥쪽 여백 최소화
                    .padding(.horizontal, 8)
                }
                // 🔍 인셋 컨테이너 자체는 완전 투명 + 불필요한 추가 여백 없음
                .background(Color.clear)
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