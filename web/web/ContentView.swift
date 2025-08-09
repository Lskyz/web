import SwiftUI
import AVKit
import WebKit

// ============================================================
// UIKit의 UIVisualEffectView(블러)를 SwiftUI에서 쓰기 위한 래퍼
// - 사파리 같은 안정적인 반투명 블러
// - 내부/주변은 .clear 유지 → 흰 박스/여백 방지
// ============================================================
struct VisualEffectBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style
    var cornerRadius: CGFloat = 0

    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = UIBlurEffect(style: blurStyle)
        let v = UIVisualEffectView(effect: effect)
        v.clipsToBounds = true
        v.layer.cornerRadius = cornerRadius
        v.backgroundColor = .clear            // ✨ 변경: 흰 배경 방지
        return v
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: blurStyle)
        uiView.layer.cornerRadius = cornerRadius
        uiView.backgroundColor = .clear       // ✨ 변경: 안전하게 clear 유지
    }
}

/// 웹 브라우저의 메인 콘텐츠 뷰 - 단순화된 페이지 기록 시스템
struct ContentView: View {
    // MARK: - 속성 정의
    @Binding var tabs: [WebTab]
    @Binding var selectedTabIndex: Int

    @State private var inputURL: String = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var textFieldSelectedAll = false
    @State private var showHistorySheet = false
    @State private var showTabManager = false
    @State private var showDebugView = false
    @State private var showAddressBar = false
    @State private var scrollOffset: CGFloat = 0
    @State private var previousOffset: CGFloat = 0

    @State private var ignoreAutoHideUntil: Date = .distantPast
    private let focusDebounceSeconds: TimeInterval = 0.5

    @State private var lastWebContentOffsetY: CGFloat = 0

    var body: some View {
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel

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
                        ),
                        onScroll: { y in
                            handleWebViewScroll(yOffset: y)
                        }
                    )
                    .id(state.tabID) // 탭별 WKWebView 인스턴스 분리 보장
                    .ignoresSafeArea(.container, edges: [.top, .bottom]) // ✨ 추가: 웹콘텐츠를 상/하단까지 확장해 하단바 뒤로 "겹치게"

                    .overlay(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: ScrollOffsetPreferenceKey.self,
                                    value: geometry.frame(in: .global).origin.y
                                )
                        }
                    )
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                        if isTextFieldFocused || Date() < ignoreAutoHideUntil {
                            previousOffset = offset
                            return
                        }
                        let delta = offset - previousOffset
                        if delta < -30 && showAddressBar {
                            withAnimation {
                                showAddressBar = false
                                isTextFieldFocused = false
                            }
                        }
                        previousOffset = offset
                    }

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
                                    ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
                                }
                            }
                        }
                    }

                } else {
                    DashboardView(
                        onSelectURL: { selectedURL in
                            // 단순화된 시스템: currentURL 설정으로 자동 기록
                            tabs[selectedTabIndex].stateModel.currentURL = selectedURL
                            TabPersistenceManager.debugMessages.append("대시보드에서 URL 선택: \(selectedURL)")
                        },
                        triggerLoad: {
                            tabs[selectedTabIndex].stateModel.loadURLIfReady()
                            TabPersistenceManager.debugMessages.append("대시보드 URL 로드 트리거")
                        }
                    )
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
                                    ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
                                }
                            }
                        }
                    }
                }
            }

            // MARK: - 뷰 생명주기 및 이벤트
            .onAppear {
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
                }
                TabPersistenceManager.debugMessages.append("페이지 기록 시스템 준비")
            }

            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }

            .onReceive(state.navigationDidFinish) { _ in
                // 단순화된 로그
                if let currentRecord = state.currentPageRecord {
                    let back = state.canGoBack ? "가능" : "불가"
                    let fwd = state.canGoForward ? "가능" : "불가"
                    let title = currentRecord.title
                    let pageId = currentRecord.id.uuidString.prefix(8)
                    TabPersistenceManager.debugMessages.append("HIST ⏪\(back) ▶︎\(fwd) | '\(title)' [ID: \(pageId)]")
                } else {
                    TabPersistenceManager.debugMessages.append("HIST 페이지 기록 없음")
                }
                
                TabPersistenceManager.saveTabs(tabs)
                TabPersistenceManager.debugMessages.append("탭 스냅샷 저장(네비게이션 완료)")
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
                        onTabSelected: { index in
                            selectedTabIndex = index
                            
                            // 탭 전환 시 히스토리 상태 로그
                            let switchedState = tabs[index].stateModel
                            if let currentRecord = switchedState.currentPageRecord {
                                let back = switchedState.canGoBack ? "가능" : "불가"
                                let fwd = switchedState.canGoForward ? "가능" : "불가"
                                let title = currentRecord.title
                                let pageId = currentRecord.id.uuidString.prefix(8)
                                TabPersistenceManager.debugMessages.append("HIST(tab \(index)) ⏪\(back) ▶︎\(fwd) | '\(title)' [ID: \(pageId)]")
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
                if let url = tabs[selectedTabIndex].playerURL {
                    AVPlayerView(url: url)
                }
            }
            
            .fullScreenCover(isPresented: $showDebugView) {
                DebugLogView()
            }

            // MARK: - 하단 UI (Safari 스타일 투명 블러)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    // 주소창
                    if showAddressBar {
                        HStack {
                            TextField("URL 또는 검색어", text: $inputURL)
                                // ✨ 변경: 기본 둥근 텍스트필드(흰 내부 채움) 제거
                                .textFieldStyle(.plain)
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
                                    if focused {
                                        ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
                                    } else {
                                        textFieldSelectedAll = false
                                        TabPersistenceManager.debugMessages.append("주소창 포커스 해제")
                                    }
                                }
                                .onSubmit {
                                    if let url = fixedURL(from: inputURL) {
                                        // 단순화: currentURL 설정으로 자동 기록
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
                                                    .foregroundColor(.secondary)
                                                    .font(.system(size: 14))
                                            }
                                            .padding(.trailing, 8)
                                        }
                                    }
                                )
                                .frame(maxWidth: 300)
                                // ✨ 변경: 텍스트필드 자체 배경을 투명으로
                                .background(Color.clear)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        // ✨ 변경: 주소창 컨테이너 배경을 UIKit 블러로 교체
                        .background(
                            VisualEffectBlur(blurStyle: .systemThinMaterial, cornerRadius: 10)
                        )
                        .padding(.horizontal, 8)
                        .transition(.opacity)
                        .gesture(
                            DragGesture(minimumDistance: 10).onEnded { value in
                                if value.translation.height > 20 {
                                    withAnimation {
                                        showAddressBar = false
                                        isTextFieldFocused = false
                                    }
                                } else if value.translation.height < -20 {
                                    withAnimation { showAddressBar = true }
                                    DispatchQueue.main.async {
                                        isTextFieldFocused = true
                                        ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
                                    }
                                }
                            }
                        )
                    }

                    // 하단 통합 툴바
                    HStack(spacing: 8) {
                        Button(action: { state.goBack() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18))
                                .foregroundColor(state.canGoBack ? .primary : .secondary)
                        }
                        .disabled(!state.canGoBack)
                        .padding(.horizontal, 4)

                        Button(action: { state.goForward() }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 18))
                                .foregroundColor(state.canGoForward ? .primary : .secondary)
                        }
                        .disabled(!state.canGoForward)
                        .padding(.horizontal, 4)

                        Button(action: { state.reload() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 4)

                        Button(action: { showTabManager = true }) {
                            Image(systemName: "square.on.square")
                                .font(.system(size: 18))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 4)

                        Button(action: { showHistorySheet = true }) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 18))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 4)
                        
                        Button(action: { showDebugView = true }) {
                            Image(systemName: "ladybug")
                                .font(.system(size: 18))
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 4)
                        
                        // 페이지 개수 표시
                        if state.historyURLs.count > 0 {
                            Text("\(state.historyURLs.count)")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    // ✨ 변경: 툴바 배경을 UIKit 블러로 교체 (흰 박스 방지)
                    .background(
                        VisualEffectBlur(blurStyle: .systemThinMaterial, cornerRadius: 10)
                    )
                    .padding(.horizontal, 8)
                    .gesture(
                        DragGesture(minimumDistance: 10).onEnded { value in
                            if value.translation.height > 20 {
                                withAnimation {
                                    showAddressBar = false
                                    isTextFieldFocused = false
                                }
                            } else if value.translation.height < -20 {
                                withAnimation { showAddressBar = true }
                            }
                        }
                    )
                }
                // ✨ 변경: 인셋 컨테이너 자체는 완전 투명
                .background(Color.clear)
            }

        } else {
            // 탭이 비어있을 때 대시보드
            DashboardView(
                onSelectURL: { url in
                    let newTab = WebTab(url: url)
                    tabs.append(newTab)
                    selectedTabIndex = tabs.count - 1
                    
                    TabPersistenceManager.saveTabs(tabs)
                    TabPersistenceManager.debugMessages.append("새 탭 생성 (대시보드): \(url)")
                },
                triggerLoad: {
                    if tabs.indices.contains(selectedTabIndex) {
                        tabs[selectedTabIndex].stateModel.loadURLIfReady()
                    }
                    TabPersistenceManager.debugMessages.append("대시보드 fallback 트리거")
                }
            )
        }
    }

    // MARK: - WKWebView 스크롤 콜백 처리
    private func handleWebViewScroll(yOffset: CGFloat) {
        if isTextFieldFocused || Date() < ignoreAutoHideUntil {
            lastWebContentOffsetY = yOffset
            return
        }

        let delta = yOffset - lastWebContentOffsetY
        if abs(delta) < 2 {
            lastWebContentOffsetY = yOffset
            return
        }

        if delta > 4 && showAddressBar {
            withAnimation {
                showAddressBar = false
                isTextFieldFocused = false
            }
        } else if delta < -12 && !showAddressBar {
            withAnimation { showAddressBar = true }
        }

        lastWebContentOffsetY = yOffset
    }

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