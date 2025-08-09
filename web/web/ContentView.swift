import SwiftUI
import AVKit
import WebKit

// ============================================================
// UIKit의 UIVisualEffectView(블러)를 SwiftUI에서 쓰기 위한 래퍼
// - 배경은 .clear 유지 (흰 박스/여백 방지)
// - 재질(blurStyle)은 호출부에서 지정
// ============================================================
struct VisualEffectBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style
    var cornerRadius: CGFloat = 0

    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = UIBlurEffect(style: blurStyle)
        let v = UIVisualEffectView(effect: effect)
        v.clipsToBounds = true
        v.layer.cornerRadius = cornerRadius
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: blurStyle)
        uiView.layer.cornerRadius = cornerRadius
        uiView.backgroundColor = .clear
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

    // 상단(Dynamic Island) 기본 보호, 주소창 숨김 상태에서만 상단 겹치기 허용
    @State private var allowTopOverlap: Bool = false

    // ============================================================
    // ✨ 변경: UI 규격 + 재질/투명도 제어 상수 (여기만 만지면 전체가 같이 바뀜)
    // ============================================================
    private let outerHorizontalPadding: CGFloat = 22   // 주소창/툴바의 외부 좌우 여백(폭 조절)
    private let barCornerRadius: CGFloat       = 22    // 둥근 정도 (유리 캡슐 느낌)
    private let barVPadding: CGFloat           = 12    // 내부 상하 여백(높이)
    private let iconSize: CGFloat              = 22    // 툴바 아이콘 크기
    private let textFont: Font                 = .system(size: 18, weight: .semibold)
    private let toolbarSpacing: CGFloat        = 22    // 하단 버튼 간격
    private let glassTintOpacity: CGFloat      = 0.08  // ✨ 변경: '화이트 글라스' 흰 틴트 투명도 (0.08~0.20 사이 추천)

    // 재질: 더 하얗게 비치도록 Light 계열 사용
    private let glassMaterial: UIBlurEffect.Style = .systemUltraThinMaterialLight // ✨ 변경

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
                    .ignoresSafeArea(.container, edges: allowTopOverlap ? [.top, .bottom] : [.bottom]) // 하단 겹치기 + (주소창 숨김 시) 상단 겹치기

                    // 스크롤 오프셋 트래킹 (기존 로직)
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
                            allowTopOverlap = true
                        }
                        previousOffset = offset
                    }

                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation {
                            if showAddressBar {
                                showAddressBar = false
                                isTextFieldFocused = false
                                allowTopOverlap = true
                            } else {
                                showAddressBar = true
                                allowTopOverlap = false
                                DispatchQueue.main.async {
                                    isTextFieldFocused = true
                                    ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
                                }
                            }
                        }
                    }

                } else {
                    // 대시보드 (기존)
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation {
                            if showAddressBar {
                                showAddressBar = false
                                isTextFieldFocused = false
                                allowTopOverlap = true
                            } else {
                                showAddressBar = true
                                allowTopOverlap = false
                                DispatchQueue.main.async {
                                    isTextFieldFocused = true
                                    ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
                                }
                            }
                        }
                    }
                }
            }

            // MARK: - 뷰 생명주기/이벤트 (기존)
            .onAppear {
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
                }
                TabPersistenceManager.debugMessages.append("페이지 기록 시스템 준비")
            }
            .onReceive(state.$currentURL) { url in
                if let url = url { inputURL = url.absoluteString }
            }
            .onReceive(state.navigationDidFinish) { _ in
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
                NavigationView { WebViewStateModel.HistoryPage(state: state) }
            }
            .fullScreenCover(isPresented: $showTabManager) {
                NavigationView {
                    TabManager(
                        tabs: $tabs,
                        initialStateModel: state,
                        onTabSelected: { index in
                            selectedTabIndex = index
                            let switched = tabs[index].stateModel
                            if let r = switched.currentPageRecord {
                                let back = switched.canGoBack ? "가능" : "불가"
                                let fwd = switched.canGoForward ? "가능" : "불가"
                                let pageId = r.id.uuidString.prefix(8)
                                TabPersistenceManager.debugMessages.append("HIST(tab \(index)) ⏪\(back) ▶︎\(fwd) | '\(r.title)' [ID: \(pageId)]")
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
                if let url = tabs[selectedTabIndex].playerURL { AVPlayerView(url: url) }
            }
            .fullScreenCover(isPresented: $showDebugView) { DebugLogView() }

            // MARK: - 하단 UI (화이트 글라스: Light + White Tint + 더 투명 스트로크)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    // 주소창
                    if showAddressBar {
                        HStack {
                            TextField("URL 또는 검색어", text: $inputURL)
                                .textFieldStyle(.plain)
                                .font(textFont)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .keyboardType(.URL)
                                .focused($isTextFieldFocused)
                                .onTapGesture {
                                    if !textFieldSelectedAll {
                                        DispatchQueue.main.async {
                                            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
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
                                                    .font(.system(size: 16))
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.trailing, 8)
                                        }
                                    }
                                )
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, barVPadding)
                        // ✨ 변경: Light 재질 + White Tint(알파로 불투명도 낮춤 → 뒤가 더 비침)
                        .background(
                            ZStack {
                                VisualEffectBlur(blurStyle: glassMaterial, cornerRadius: barCornerRadius)
                                RoundedRectangle(cornerRadius: barCornerRadius)
                                    .fill(Color.white.opacity(glassTintOpacity))
                            }
                        )
                        // ✨ 변경: 스트로크 투명도 살짝 낮춰 더 투명한 글라스
                        .overlay(RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
                        .overlay(RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.black.opacity(0.08), lineWidth: 0.25))
                        .padding(.horizontal, outerHorizontalPadding)
                        .transition(.opacity)
                    }

                    // 하단 통합 툴바 (주소창과 폭 동일 + 같은 글라스)
                    HStack(spacing: 0) {
                        HStack(spacing: toolbarSpacing) {
                            Button(action: { state.goBack() }) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: iconSize))
                                    .foregroundColor(state.canGoBack ? .primary : .secondary)
                            }
                            .disabled(!state.canGoBack)

                            Button(action: { state.goForward() }) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: iconSize))
                                    .foregroundColor(state.canGoForward ? .primary : .secondary)
                            }
                            .disabled(!state.canGoForward)

                            Button(action: { state.reload() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: iconSize))
                                    .foregroundColor(.primary)
                            }

                            Button(action: { showHistorySheet = true }) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: iconSize))
                                    .foregroundColor(.primary)
                            }

                            Button(action: { showTabManager = true }) {
                                Image(systemName: "square.on.square")
                                    .font(.system(size: iconSize))
                                    .foregroundColor(.primary)
                            }

                            Button(action: { showDebugView = true }) {
                                Image(systemName: "ladybug")
                                    .font(.system(size: iconSize))
                                    .foregroundColor(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, barVPadding)
                    // ✨ 변경: 동일 재질 + White Tint
                    .background(
                        ZStack {
                            VisualEffectBlur(blurStyle: glassMaterial, cornerRadius: barCornerRadius)
                            RoundedRectangle(cornerRadius: barCornerRadius)
                                .fill(Color.white.opacity(glassTintOpacity))
                        }
                    )
                    // ✨ 변경: 투명한 글라스 스트로크
                    .overlay(RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
                    .overlay(RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.black.opacity(0.08), lineWidth: 0.25))
                    .padding(.horizontal, outerHorizontalPadding)
                }
                .background(Color.clear)
            }

        } else {
            // 탭이 비어있을 때 대시보드 (기존)
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

    // MARK: - WKWebView 스크롤 콜백 처리 (기존)
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
            withAnimation { showAddressBar = false; isTextFieldFocused = false }
            allowTopOverlap = true
        } else if delta < -12 && !showAddressBar {
            withAnimation { showAddressBar = true }
            allowTopOverlap = false
        }
        lastWebContentOffsetY = yOffset
    }

    // MARK: - 입력 문자열을 URL로 정규화 (기존)
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

// MARK: - 스크롤 오프셋 추적을 위한 PreferenceKey (기존)
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}