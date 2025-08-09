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

/// 웹 브라우저의 메인 콘텐츠 뷰 - 🛡️ 복원 상태 고려한 뷰 전환 로직
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
    
    // 🛡️ 새로 추가: 복원 상태 추적
    @State private var isSessionRestoring: Bool = false
    @State private var forceShowWebView: Bool = false

    // ============================================================
    // ✨ 변경: UI 규격 + 재질/투명도 제어 상수 (여기만 만지면 전체가 같이 바뀜)
    // 블러 약하게 = UltraThin 재질(가장 투명/블러 약함)
    // 화이트 글라스 = Light 계열 + 흰색 틴트 오버레이
    // ============================================================
    private let outerHorizontalPadding: CGFloat = 24     // 주소창/툴바 외부 좌우 여백(=폭 제어)
    private let barCornerRadius: CGFloat       = 22
    private let barVPadding: CGFloat           = 12
    private let iconSize: CGFloat              = 23
    private let textFont: Font                 = .system(size: 18, weight: .semibold)
    private let toolbarSpacing: CGFloat        = 22

    private let glassMaterial: UIBlurEffect.Style = .systemUltraThinMaterialLight // ✨ 변경: 가장 얇은(블러 약함) + 라이트
    private let glassTintOpacity: CGFloat      = 0.20  // ✨ 변경: 화이트 틴트 강도(사파리 느낌이면 0.14~0.20 권장)

    var body: some View {
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel

            ZStack {
                // MARK: 🛡️ 강화된 웹 콘텐츠 영역 조건 판단
                if shouldShowWebView(for: state) {
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
                            previousOffset = offset; return
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
                    // 🛡️ 대시보드 표시 (복원 상태 고려)
                    ZStack {
                        DashboardView(
                            onNavigateToURL: { selectedURL in
                                handleDashboardNavigation(selectedURL)
                            }
                        )
                        
                        // 🛡️ 복원 중일 때 로딩 인디케이터 표시
                        if isSessionRestoring {
                            VStack {
                                ProgressView()
                                    .scaleEffect(1.2)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                                
                                Text("페이지 복원 중...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 8)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                            )
                        }
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
                }
            }

            // MARK: - 🛡️ 강화된 뷰 생명주기/이벤트
            .onAppear {
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
                    
                    // 🛡️ 복원 상태 감지
                    if !state.pageHistory.isEmpty && state.currentPageRecord != nil {
                        isSessionRestoring = true
                        TabPersistenceManager.debugMessages.append("🔄 복원 상태 감지: 웹뷰 준비 대기")
                        
                        // 🛡️ 복원 타임아웃 (10초)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                            if isSessionRestoring {
                                TabPersistenceManager.debugMessages.append("⚠️ 복원 타임아웃: 강제 웹뷰 표시")
                                isSessionRestoring = false
                                forceShowWebView = true
                            }
                        }
                    }
                }
                TabPersistenceManager.debugMessages.append("페이지 기록 시스템 준비")
            }
            .onReceive(state.$currentURL) { url in
                if let url = url { 
                    inputURL = url.absoluteString 
                    
                    // 🛡️ URL 변경 시 복원 상태 체크
                    if isSessionRestoring {
                        TabPersistenceManager.debugMessages.append("🔄 복원 중 URL 변경: \(url.absoluteString)")
                    }
                }
            }
            .onReceive(state.navigationDidFinish) { _ in
                // 🛡️ 네비게이션 완료 시 복원 상태 해제
                if isSessionRestoring {
                    TabPersistenceManager.debugMessages.append("🔄 복원 완료: 네비게이션 성공")
                    isSessionRestoring = false
                    forceShowWebView = true
                }
                
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
                            
                            // 🛡️ 탭 전환 시 복원 상태 초기화
                            isSessionRestoring = false
                            forceShowWebView = false
                            
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

            // MARK: - 하단 UI (화이트 글라스 + 툴바 빈공간 탭 시 주소창 열기)
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
                                        handleAddressBarNavigation(url)
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
                        // ✨ 변경: UltraThin Light + 흰색 틴트(화이트 글라스)
                        .background(
                            ZStack {
                                VisualEffectBlur(blurStyle: glassMaterial, cornerRadius: barCornerRadius)
                                RoundedRectangle(cornerRadius: barCornerRadius)
                                    .fill(Color.white.opacity(glassTintOpacity))
                            }
                        )
                        // 테두리(하이라이트/섀도)는 낮은 불투명도로 유지
                        .overlay(RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
                        .overlay(RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.black.opacity(0.08), lineWidth: 0.25))
                        .padding(.horizontal, outerHorizontalPadding)
                        .transition(.opacity)
                    }

                    // 하단 통합 툴바
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
                    // ✨ 변경: UltraThin Light + 흰색 틴트(화이트 글라스)
                    .background(
                        ZStack {
                            VisualEffectBlur(blurStyle: glassMaterial, cornerRadius: barCornerRadius)
                            RoundedRectangle(cornerRadius: barCornerRadius)
                                .fill(Color.white.opacity(glassTintOpacity))
                        }
                    )
                    .overlay(RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
                    .overlay(RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.black.opacity(0.08), lineWidth: 0.25))
                    .padding(.horizontal, outerHorizontalPadding)
                    // ✨ 변경: "툴바의 빈공간"을 탭하면 주소창 열기 (버튼 영역 탭은 버튼이 소비하므로 충돌 X)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !showAddressBar {                  // 조건만 추가 (밖 말고 안에)
                            withAnimation {
                                showAddressBar = true
                                allowTopOverlap = false       // 주소창 보일 땐 상단 보호
                            }
                        }
                    }
                }
                .background(Color.clear)
            }

        } else {
            // ✅ 수정: 탭이 비어있을 때도 onNavigateToURL 단일 함수로 통합
            DashboardView(
                onNavigateToURL: { url in
                    handleEmptyTabNavigation(url)
                }
            )
        }
    }

    // MARK: - 🛡️ 웹뷰 표시 조건 판단 로직 (단순화)
    
    private func shouldShowWebView(for state: WebViewStateModel) -> Bool {
        // 1. currentURL이 없으면 대시보드
        guard state.currentURL != nil else {
            return false
        }
        
        // 2. 강제 표시 플래그가 있으면 웹뷰
        if forceShowWebView {
            return true
        }
        
        // 3. 복원 중이 아니면 웹뷰
        if !isSessionRestoring {
            return true
        }
        
        // 4. 복원 중이면서 히스토리가 비어있으면 웹뷰 (새 페이지)
        return state.pageHistory.isEmpty
    }
            TabPersistenceManager.debugMessages.append("🔍 웹뷰 표시: 빈 히스토리")
            return true
        }
        
        // 5. 복원 중이면서 페이지 히스토리가 있으면 대기
        TabPersistenceManager.debugMessages.append("🔍 웹뷰 표시 안함: 복원 중 + 히스토리 있음")
        return false
    }
    
    // MARK: - 🛡️ 네비게이션 처리 메서드들
    
    private func handleDashboardNavigation(_ selectedURL: URL) {
        let state = tabs[selectedTabIndex].stateModel
        
        // 복원 상태 초기화
        isSessionRestoring = false
        forceShowWebView = true
        
        // 원자적 처리: URL 설정 + 로딩을 한번에
        state.currentURL = selectedURL
        state.loadURLIfReady()
        TabPersistenceManager.debugMessages.append("🌐 대시보드 네비게이션: \(selectedURL.absoluteString)")
    }
    
    private func handleAddressBarNavigation(_ url: URL) {
        let state = tabs[selectedTabIndex].stateModel
        
        // 복원 상태 초기화
        isSessionRestoring = false
        forceShowWebView = true
        
        state.currentURL = url
        TabPersistenceManager.debugMessages.append("주소창에서 URL 이동: \(url)")
    }
    
    private func handleEmptyTabNavigation(_ url: URL) {
        // 복원 상태 초기화
        isSessionRestoring = false
        forceShowWebView = false
        
        // 원자적 처리: 새 탭 생성 + URL 설정 + 로딩을 한번에
        let newTab = WebTab(url: url)
        tabs.append(newTab)
        selectedTabIndex = tabs.count - 1
        newTab.stateModel.loadURLIfReady()
        TabPersistenceManager.saveTabs(tabs)
        TabPersistenceManager.debugMessages.append("🌐 새 탭 네비게이션: \(url.absoluteString)")
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
