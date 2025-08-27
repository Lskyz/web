import SwiftUI
import AVKit
import WebKit

// ============================================================
// ✨ 투명한 흰색 유리 효과 (Clean White Glass)
// ============================================================
struct WhiteGlassBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style
    var cornerRadius: CGFloat = 0
    var intensity: CGFloat = 1.0
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect = UIBlurEffect(style: blurStyle)
        let effectView = UIVisualEffectView(effect: effect)
        effectView.clipsToBounds = true
        effectView.layer.cornerRadius = cornerRadius
        effectView.backgroundColor = .clear
        setupWhiteGlassEffect(effectView)
        return effectView
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: blurStyle)
        uiView.layer.cornerRadius = cornerRadius
        uiView.backgroundColor = .clear
        uiView.alpha = intensity
    }
    
    private func setupWhiteGlassEffect(_ effectView: UIVisualEffectView) {
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            UIColor.white.withAlphaComponent(0.1).cgColor,
            UIColor.white.withAlphaComponent(0.05).cgColor,
            UIColor.clear.cgColor
        ]
        gradientLayer.locations = [0.0, 0.8, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint   = CGPoint(x: 1, y: 1)
        effectView.contentView.layer.addSublayer(gradientLayer)
        DispatchQueue.main.async { gradientLayer.frame = effectView.bounds }
    }
}

// MARK: - 🎬 PIP 보존용 웹뷰 컨테이너
class PIPWebViewContainer: ObservableObject {
    static let shared = PIPWebViewContainer()
    private var preservedWebViews: [UUID: AnyView] = [:]
    private init() { TabPersistenceManager.debugMessages.append("🎬 PIP 웹뷰 컨테이너 초기화") }
    func preserveWebView(for tabID: UUID, webView: AnyView) {
        preservedWebViews[tabID] = webView
        TabPersistenceManager.debugMessages.append("🎬 웹뷰 보존: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    func getPreservedWebView(for tabID: UUID) -> AnyView? { preservedWebViews[tabID] }
    func removePreservedWebView(for tabID: UUID) {
        preservedWebViews.removeValue(forKey: tabID)
        TabPersistenceManager.debugMessages.append("🎬 웹뷰 보존 해제: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    func isWebViewPreserved(for tabID: UUID) -> Bool { preservedWebViews.keys.contains(tabID) }
    func clearAll() {
        preservedWebViews.removeAll()
        TabPersistenceManager.debugMessages.append("🎬 모든 웹뷰 보존 해제")
    }
}

// MARK: - 메인 뷰
struct ContentView: View {
    @Binding var tabs: [WebTab]
    @Binding var selectedTabIndex: Int

    @State private var inputURL: String = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var textFieldSelectedAll = false
    @State private var showHistorySheet = false
    @State private var showTabManager = false
    @State private var showDebugView = false
    @State private var showAddressBar = false
    @State private var previousOffset: CGFloat = 0
    @State private var lastWebContentOffsetY: CGFloat = 0
    
    // 상태
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var errorTitle = ""
    @StateObject private var pipManager = PIPManager.shared
    @StateObject private var pipContainer = PIPWebViewContainer.shared
    @StateObject private var siteMenuManager = SiteMenuManager()

    @State private var isPuzzleButtonPressed = false
    @State private var puzzleButtonPressStartTime: Date? = nil

    // 스타일 수치
    private let outerHorizontalPadding: CGFloat = 22
    private let barCornerRadius: CGFloat = 20
    private let barVPadding: CGFloat = 10
    private let iconSize: CGFloat = 23
    private let textFont: Font = .system(size: 16, weight: .medium)
    private let toolbarSpacing: CGFloat = 40
    private let whiteGlassMaterial: UIBlurEffect.Style = .extraLight
    private let whiteGlassTintOpacity: CGFloat = 0.1
    private let whiteGlassIntensity: CGFloat = 0.80
    
    // ✅ 자동 키보드 인셋 처리로 단순화 (keyboardHeight 제거)
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 메인 웹 콘텐츠 (상단/좌우만 underlap)
                mainContentView

                // 하단 통합 UI 고정: 자동으로 키보드 위로 올라감
                VStack {
                    Spacer()
                    bottomUnifiedUIContent()
                }
            }
        }
        // 🔽 상단/좌우만 안전영역 무시, 하단은 유지로 키보드 인셋 자동 처리
        .ignoresSafeArea(.all, edges: [.top, .leading, .trailing])
        // 🔼 키보드 인셋은 자동으로 처리됨

        .onAppear(perform: onAppearHandler)
        .onReceive(currentState.$currentURL, perform: onURLChange)
        .onReceive(currentState.navigationDidFinish, perform: onNavigationFinish)
        .onReceive(errorNotificationPublisher, perform: onErrorReceived)
        .alert(errorTitle, isPresented: $showErrorAlert, actions: alertActions, message: alertMessage)
        .sheet(isPresented: $showHistorySheet, content: historySheet)
        .sheet(isPresented: $showTabManager, content: tabManagerView)
        .fullScreenCover(isPresented: avPlayerBinding, content: avPlayerView)
        .fullScreenCover(isPresented: $showDebugView) {
            debugView()
                .ignoresSafeArea(.keyboard, edges: .all)
        }

        // 🎬 PIP 상태 동기화
        .onChange(of: pipManager.isPIPActive) { handlePIPStateChange($0) }
        .onChange(of: pipManager.currentPIPTab) { handlePIPTabChange($0) }

        // 오버레이는 기본 키보드 인셋 처리 사용
        .siteMenuOverlay(
            manager: siteMenuManager,
            currentState: currentState,
            tabs: $tabs,
            selectedTabIndex: $selectedTabIndex,
            outerHorizontalPadding: outerHorizontalPadding,
            showAddressBar: showAddressBar,
            whiteGlassBackground: AnyView(whiteGlassBackground),
            whiteGlassOverlay: AnyView(whiteGlassOverlay)
        )
    }
    
    // MARK: - 현재 탭 상태
    private var currentState: WebViewStateModel {
        if tabs.indices.contains(selectedTabIndex) { return tabs[selectedTabIndex].stateModel }
        return WebViewStateModel()
    }
    
    // MARK: - 콘텐츠
    @ViewBuilder
    private var mainContentView: some View {
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel
            ZStack {
                if state.currentURL != nil {
                    if let preservedWebView = pipContainer.getPreservedWebView(for: tabs[selectedTabIndex].id) {
                        preservedWebView.onAppear {
                            TabPersistenceManager.debugMessages.append("🎬 보존된 PIP 웹뷰 사용: 탭 \(String(tabs[selectedTabIndex].id.uuidString.prefix(8)))")
                        }
                    } else {
                        webContentView(state: state)
                    }
                } else {
                    dashboardView
                }
                if pipManager.isPIPActive { pipStatusOverlay }
            }
        } else {
            dashboardView
        }
    }
    
    @ViewBuilder
    private var pipStatusOverlay: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "pip.fill").font(.caption)
                    Text("PIP 활성").font(.caption2)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .foregroundColor(.green)
                .cornerRadius(16)
                .padding(.trailing).padding(.top, 60)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
    
    @ViewBuilder
    private func webContentView(state: WebViewStateModel) -> some View {
        createWebContentView(state: state)
            .overlay(scrollOffsetOverlay)
            .onPreferenceChange(ScrollOffsetPreferenceKey.self, perform: onScrollOffsetChange)
            .contentShape(Rectangle())
            .onTapGesture(perform: onContentTap)
    }
    
    @ViewBuilder
    private func createWebContentView(state: WebViewStateModel) -> some View {
        CustomWebView(
            stateModel: state,
            playerURL: Binding(
                get: {
                    if let index = tabs.firstIndex(where: { $0.id == state.tabID }) { return tabs[index].playerURL }
                    return nil
                },
                set: { newValue in
                    if let index = tabs.firstIndex(where: { $0.id == state.tabID }) {
                        tabs[index].playerURL = newValue
                        if let url = newValue, tabs[index].showAVPlayer { pipManager.pipPlayerURL = url }
                    }
                }
            ),
            showAVPlayer: Binding(
                get: { if let i = tabs.firstIndex(where: { $0.id == state.tabID }) { return tabs[i].showAVPlayer } ; return false },
                set: { newValue in
                    if let i = tabs.firstIndex(where: { $0.id == state.tabID }) {
                        tabs[i].showAVPlayer = newValue
                        if !newValue && pipManager.currentPIPTab == tabs[i].id { pipManager.stopPIP() }
                    }
                }
            ),
            onScroll: { y in handleWebViewScroll(yOffset: y) }
        )
        .id(state.tabID)
        // 웹뷰는 기본 키보드 인셋 처리 사용
    }
    
    private var dashboardView: some View {
        DashboardView(onNavigateToURL: handleDashboardNavigation(_:))
            .contentShape(Rectangle())
            .onTapGesture(perform: onContentTap)
            // 대시보드도 기본 키보드 인셋 처리 사용
    }
    
    private var scrollOffsetOverlay: some View {
        GeometryReader { g in
            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: g.frame(in: .global).origin.y)
        }
    }
    
    // MARK: - 🎯 통합된 하단 UI (사파리 스타일 - 배경 통합, 주소창만 테두리 구분)
    @ViewBuilder
    private func bottomUnifiedUIContent() -> some View {
        VStack(spacing: 0) {
            // 1️⃣ 주소창 관련 콘텐츠 (히스토리/자동완성)
            if showAddressBar && (isTextFieldFocused || inputURL.isEmpty) {
                addressBarHistoryContent
                    .padding(.horizontal, outerHorizontalPadding)
                    // 히스토리 콘텐츠도 기본 키보드 인셋 처리
            }
            
            // 2️⃣ 통합 툴바 (사파리 스타일 - 하나의 배경에 주소창만 구분)
            VStack(spacing: 12) {
                if showAddressBar {
                    // 주소창 영역 - 별도 테두리로 구분
                    HStack(spacing: 12) {
                        VStack(spacing: 0) {
                            addressBarMainContent
                            if currentState.isLoading { progressBarView }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: barCornerRadius)
                                .fill(Color(UIColor.systemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: barCornerRadius)
                                .strokeBorder(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5)
                        )
                        
                        if isTextFieldFocused {
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isTextFieldFocused = false
                                    siteMenuManager.closeSiteMenu()
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { showAddressBar = false }
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        Circle()
                                            .fill(Color(UIColor.systemBackground))
                                    )
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5)
                                    )
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            ))
                        }
                    }
                    .padding(.horizontal, outerHorizontalPadding)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isTextFieldFocused)
                }
                
                // 네비게이션 툴바 - 배경에 자연스럽게 통합
                HStack(spacing: 0) {
                    HStack(spacing: toolbarSpacing) {
                        toolbarButton("chevron.left", action: {
                            currentState.goBack(); TabPersistenceManager.debugMessages.append("🎯 뒤로가기 버튼 터치")
                        }, enabled: currentState.canGoBack)
                        toolbarButton("chevron.right", action: {
                            currentState.goForward(); TabPersistenceManager.debugMessages.append("🎯 앞으로가기 버튼 터치")
                        }, enabled: currentState.canGoForward)
                        toolbarButton("clock.arrow.circlepath", action: { showHistorySheet = true }, enabled: true)
                        toolbarButton("square.on.square", action: { showTabManager = true }, enabled: true)
                        if pipManager.isPIPActive {
                            toolbarButton("pip.fill", action: { pipManager.stopPIP() }, enabled: true, color: .green)
                        }
                        toolbarButton("ladybug", action: { showDebugView = true }, enabled: true, color: .orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToolbarTap)
            }
            .padding(.vertical, barVPadding)
            
            // 🎯 하단 안전영역 배경 연장 (키보드 상태 무관하게 일관성 유지)
            Spacer(minLength: 0)
                .frame(maxHeight: .infinity)
                .background(whiteGlassBackground)
                .overlay(whiteGlassOverlay)
        }
        // 전체를 하나의 배경으로 통합
        .background(
            GeometryReader { geometry in
                whiteGlassBackground
                    .frame(width: UIScreen.main.bounds.width)
                    .offset(x: -geometry.frame(in: .global).minX, y: 0)
                    .ignoresSafeArea(.all, edges: .bottom) // 하단까지 완전히 확장
            }
        )
        .overlay(
            GeometryReader { geometry in
                whiteGlassOverlay
                    .frame(width: UIScreen.main.bounds.width)
                    .offset(x: -geometry.frame(in: .global).minX, y: 0)
                    .ignoresSafeArea(.all, edges: .bottom) // 하단까지 완전히 확장
            }
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: barCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: barCornerRadius
            )
        )
        .background(Color.clear)
        // 하단 UI도 기본 키보드 인셋 처리 사용
    }
    
    // 방문기록/자동완성 (사파리 스타일 - 깔끔한 배경)
    @ViewBuilder
    private var addressBarHistoryContent: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color(UIColor.separator).opacity(0.3))
            
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if inputURL.isEmpty {
                        RecentVisitsView(
                            manager: siteMenuManager,
                            onURLSelected: { url in
                                inputURL = url.absoluteString
                                currentState.currentURL = url
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isTextFieldFocused = false }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { showAddressBar = false }
                                }
                            },
                            onManageHistory: { siteMenuManager.showHistoryFilterManager = true }
                        )
                        .padding(.vertical, 8)
                    } else {
                        AutocompleteView(
                            manager: siteMenuManager,
                            searchText: inputURL,
                            onURLSelected: { url in
                                inputURL = url.absoluteString
                                currentState.currentURL = url
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isTextFieldFocused = false }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { showAddressBar = false }
                                }
                            },
                            onManageHistory: { siteMenuManager.showHistoryFilterManager = true }
                        )
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            
            VStack(spacing: 8) {
                Divider()
                    .background(Color(UIColor.separator).opacity(0.3))
                
                HStack {
                    Button(action: { siteMenuManager.showHistoryFilterManager = true }) {
                        HStack(spacing: 4) { 
                            Image(systemName: "slider.horizontal.3")
                            Text("방문기록 관리") 
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }
                    Spacer()
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(UIColor.systemBackground).opacity(0.95))
        .cornerRadius(barCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: barCornerRadius)
                .strokeBorder(Color(UIColor.separator).opacity(0.2), lineWidth: 0.5)
        )
        .gesture(
            DragGesture().onEnded { value in
                if value.translation.height > 50 && value.velocity.height > 300 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isTextFieldFocused = false
                        siteMenuManager.closeSiteMenu()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { showAddressBar = false }
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        )
    }
    
    private var addressBarMainContent: some View {
        HStack(spacing: 8) {
            puzzleButton
            siteSecurityIcon
            urlTextField
            refreshButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, barVPadding)
    }
    
    private var puzzleButton: some View {
        Button(action: {
            siteMenuManager.setCurrentStateModel(currentState)
            siteMenuManager.toggleSiteMenu()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            TabPersistenceManager.debugMessages.append("🧩 퍼즐 버튼으로 사이트 메뉴 토글: \(siteMenuManager.showSiteMenu)")
        }) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isPuzzleButtonPressed ? Color.white.opacity(0.3) : Color.clear)
                        .animation(.easeInOut(duration: 0.1), value: isPuzzleButtonPressed)
                )
                .scaleEffect(isPuzzleButtonPressed ? 0.95 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isPuzzleButtonPressed)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPuzzleButtonPressed { isPuzzleButtonPressed = true; puzzleButtonPressStartTime = Date() }
                }
                .onEnded { _ in
                    isPuzzleButtonPressed = false
                    puzzleButtonPressStartTime = nil
                }
        )
        .zIndex(999)
    }
    
    private var siteSecurityIcon: some View {
        HStack(spacing: 4) {
            if currentState.isLoading {
                ProgressView().scaleEffect(0.6).frame(width: 20, height: 20)
            } else {
                Image(systemName: getSiteIcon())
                    .font(.system(size: 16))
                    .foregroundColor(getSiteIconColor())
                    .frame(width: 20, height: 20)
            }
        }
    }
    private func getSiteIcon() -> String {
        guard let url = currentState.currentURL else { return "globe" }
        if url.scheme == "https" { return "lock.fill" }
        if url.scheme == "http" { return "exclamationmark.triangle.fill" }
        return "globe"
    }
    private func getSiteIconColor() -> Color {
        guard let url = currentState.currentURL else { return .secondary }
        if url.scheme == "https" { return .green }
        if url.scheme == "http" { return .orange }
        return .secondary
    }
    
    private var urlTextField: some View {
        TextField("URL 또는 검색어", text: $inputURL)
            .textFieldStyle(.plain)
            .font(textFont)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .keyboardType(.URL)
            .focused($isTextFieldFocused)
            .onTapGesture(perform: onTextFieldTap)
            .onChange(of: isTextFieldFocused, perform: onTextFieldFocusChange)
            .onSubmit(onTextFieldSubmit)
            .overlay(textFieldClearButton)
    }
    @ViewBuilder
    private var textFieldClearButton: some View {
        HStack {
            Spacer()
            if !inputURL.isEmpty && !currentState.isLoading {
                Button(action: { inputURL = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .padding(.trailing, 8)
            }
        }
    }
    private var refreshButton: some View {
        Button(action: {
            if currentState.isLoading { currentState.stopLoading(); TabPersistenceManager.debugMessages.append("로딩 중지") }
            else { currentState.reload(); TabPersistenceManager.debugMessages.append("페이지 새로고침") }
        }) {
            Image(systemName: currentState.isLoading ? "xmark" : "arrow.clockwise")
                .font(.system(size: 16))
                .foregroundColor(.primary)
        }
        .frame(width: 24, height: 24)
    }
    private var progressBarView: some View {
        ProgressView(value: max(0.0, min(1.0, currentState.loadingProgress)))
            .progressViewStyle(LinearProgressViewStyle(tint: currentState.currentURL?.scheme == "https" ? .green : .secondary))
            .frame(height: 2)
            .padding(.horizontal, 14)
            .animation(.easeOut(duration: 0.3), value: currentState.loadingProgress)
            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }
    
    private func toolbarButton(_ systemName: String, action: @escaping () -> Void, enabled: Bool, color: Color = .primary) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize))
                .foregroundColor(enabled ? color : .secondary)
        }
        .disabled(!enabled)
    }
    private var whiteGlassBackground: some View {
        ZStack {
            WhiteGlassBlur(blurStyle: whiteGlassMaterial, cornerRadius: 0, intensity: whiteGlassIntensity)
            Rectangle().fill(Color.white.opacity(whiteGlassTintOpacity))
        }
    }
    private var whiteGlassOverlay: some View {
        Group {
            Rectangle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
            Rectangle().strokeBorder(.white.opacity(0.03), lineWidth: 0.5)
        }
    }
    
    // MARK: - 핸들러
    private func onAppearHandler() {
        if let url = currentState.currentURL { inputURL = url.absoluteString; TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)") }
        TabPersistenceManager.debugMessages.append("페이지 기록 시스템 준비")
        TabPersistenceManager.debugMessages.append("🎬 ContentView 초기화 - PIP 상태: \(pipManager.isPIPActive ? "활성" : "비활성")")
        siteMenuManager.setCurrentStateModel(currentState)
        siteMenuManager.refreshDownloads()
    }
    private func onURLChange(url: URL?) { if let url = url { inputURL = url.absoluteString } }
    private func onNavigationFinish(_: Void) {
        if let r = currentState.currentPageRecord {
            let back = currentState.canGoBack ? "가능" : "불가"
            let fwd = currentState.canGoForward ? "가능" : "불가"
            TabPersistenceManager.debugMessages.append("HIST ⏪\(back) ▶︎\(fwd) | '\(r.title)' [ID: \(r.id.uuidString.prefix(8)))")
        } else {
            TabPersistenceManager.debugMessages.append("HIST 페이지 기록 없음")
        }
        TabPersistenceManager.saveTabs(tabs)
        TabPersistenceManager.debugMessages.append("탭 스냅샷 저장(네비게이션 완료)")
        if !showAddressBar {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { showAddressBar = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if showAddressBar && !isTextFieldFocused {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { showAddressBar = false }
                }
            }
        }
    }
    private var errorNotificationPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: .webViewDidFailLoad)
    }
    private func onErrorReceived(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let tabIDString = userInfo["tabID"] as? String,
              tabIDString == currentState.tabID?.uuidString else { return }
        if let statusCode = userInfo["statusCode"] as? Int, let url = userInfo["url"] as? String {
            let e = getErrorMessage(for: statusCode, url: url)
            errorTitle = e.title; errorMessage = e.message; showErrorAlert = true
            TabPersistenceManager.debugMessages.append("❌ HTTP 오류 \(statusCode): \(e.title)")
        } else if let sslError = userInfo["sslError"] as? Bool, sslError,
                  let url = userInfo["url"] as? String {
            let domain = URL(string: url)?.host ?? "사이트"
            errorTitle = "보안 연결 취소됨"
            errorMessage = "\(domain)의 보안 인증서를 신뢰할 수 없어 연결이 취소되었습니다.\n\n다른 안전한 사이트를 이용하시거나, 해당 사이트가 신뢰할 수 있는 사이트라면 다시 방문을 시도해보세요."
            showErrorAlert = true
            TabPersistenceManager.debugMessages.append("🔒 SSL 인증서 거부: \(domain)")
        } else if let error = userInfo["error"] as? Error, let url = userInfo["url"] as? String {
            if let n = getNetworkErrorMessage(for: error, url: url) {
                errorTitle = n.title; errorMessage = n.message; showErrorAlert = true
                TabPersistenceManager.debugMessages.append("❌ 네트워크 오류: \(n.title)")
            }
        }
    }
    @ViewBuilder private func alertActions() -> some View {
        Button("확인") { }
        if !errorTitle.contains("보안 연결") { Button("다시 시도") { currentState.reload() } }
    }
    private func alertMessage() -> some View { Text(errorMessage) }
    @ViewBuilder private func historySheet() -> some View {
        NavigationView {
            WebViewDataModel.HistoryPage(
                dataModel: currentState.dataModel,
                onNavigateToPage: { record in
                    if let index = currentState.dataModel.findPageIndex(for: record.url),
                       let nav = currentState.dataModel.navigateToIndex(index) {
                        currentState.currentURL = nav.url
                        if let webView = currentState.webView { webView.load(URLRequest(url: nav.url)) }
                    }
                },
                onNavigateToURL: { url in currentState.currentURL = url }
            )
        }
        .ignoresSafeArea(.keyboard, edges: .all)
    }
    @ViewBuilder private func tabManagerView() -> some View {
        NavigationView {
            TabManager(
                tabs: $tabs,
                initialStateModel: currentState,
                onTabSelected: { index in
                    selectedTabIndex = index
                    let s = tabs[index].stateModel
                    if let r = s.currentPageRecord {
                        let back = s.canGoBack ? "가능" : "불가"
                        let fwd = s.canGoForward ? "가능" : "불가"
                        TabPersistenceManager.debugMessages.append("HIST(tab \(index)) ⏪\(back) ▶︎\(fwd) | '\(r.title)' [ID: \(r.id.uuidString.prefix(8)))")
                    } else {
                        TabPersistenceManager.debugMessages.append("HIST(tab \(index)) 준비중")
                    }
                }
            )
        }
        .ignoresSafeArea(.keyboard, edges: .all)
    }
    private var avPlayerBinding: Binding<Bool> {
        Binding(
            get: { tabs.indices.contains(selectedTabIndex) ? tabs[selectedTabIndex].showAVPlayer : false },
            set: { newValue in
                if tabs.indices.contains(selectedTabIndex) {
                    tabs[selectedTabIndex].showAVPlayer = newValue
                    if !newValue && pipManager.currentPIPTab == tabs[selectedTabIndex].id { pipManager.stopPIP() }
                }
            }
        )
    }
    @ViewBuilder private func avPlayerView() -> some View {
        if tabs.indices.contains(selectedTabIndex), let url = tabs[selectedTabIndex].playerURL { 
            AVPlayerView(url: url)
        }
    }
    @ViewBuilder private func debugView() -> some View { 
        DebugLogView()
            .ignoresSafeArea(.keyboard, edges: .all)
    }
    
    private func onScrollOffsetChange(offset: CGFloat) {
        if isTextFieldFocused || isPuzzleButtonPressed || siteMenuManager.showSiteMenu {
            previousOffset = offset; return
        }
        let delta = offset - previousOffset
        if delta < -30 && showAddressBar {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showAddressBar = false
                isTextFieldFocused = false
                siteMenuManager.closeSiteMenu()
            }
        }
        previousOffset = offset
    }
    private func onContentTap() {
        if isPuzzleButtonPressed { return }
        if let t = puzzleButtonPressStartTime, Date().timeIntervalSince(t) < 0.3 { puzzleButtonPressStartTime = nil; return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            if siteMenuManager.showSiteMenu { siteMenuManager.closeSiteMenu() }
            else if showAddressBar { showAddressBar = false; isTextFieldFocused = false }
            else { showAddressBar = true }
        }
        if siteMenuManager.showSiteMenu { siteMenuManager.closeSiteMenu() }
    }
    private func onTextFieldTap() {
        if !isTextFieldFocused { isTextFieldFocused = true }
        if !textFieldSelectedAll {
            DispatchQueue.main.async {
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                textFieldSelectedAll = true
                TabPersistenceManager.debugMessages.append("주소창 텍스트 전체 선택")
            }
        }
    }
    private func onTextFieldFocusChange(focused: Bool) {
        if !focused { textFieldSelectedAll = false; TabPersistenceManager.debugMessages.append("주소창 포커스 해제") }
    }
    private func onTextFieldSubmit() {
        if let url = fixedURL(from: inputURL) {
            currentState.currentURL = url
            TabPersistenceManager.debugMessages.append("주소창에서 URL 이동: \(url)")
        }
        isTextFieldFocused = false
    }
    private func onToolbarTap() {
        if !showAddressBar { withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { showAddressBar = true } }
    }
    private func handleDashboardNavigation(_ selectedURL: URL) {
        if tabs.indices.contains(selectedTabIndex) {
            tabs[selectedTabIndex].stateModel.currentURL = selectedURL
            tabs[selectedTabIndex].stateModel.loadURLIfReady()
            TabPersistenceManager.debugMessages.append("🌐 대시보드 네비게이션: \(selectedURL.absoluteString)")
        } else {
            let newTab = WebTab(url: selectedURL)
            tabs.append(newTab)
            selectedTabIndex = tabs.count - 1
            newTab.stateModel.loadURLIfReady()
            TabPersistenceManager.saveTabs(tabs)
            TabPersistenceManager.debugMessages.append("🌐 새 탭 네비게이션: \(selectedURL.absoluteString)")
        }
    }
    private func handleWebViewScroll(yOffset: CGFloat) {
        if isTextFieldFocused || isPuzzleButtonPressed || siteMenuManager.showSiteMenu { lastWebContentOffsetY = yOffset; return }
        let delta = yOffset - lastWebContentOffsetY
        if abs(delta) < 2 { lastWebContentOffsetY = yOffset; return }
        if delta > 4 && (showAddressBar || siteMenuManager.showSiteMenu) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showAddressBar = false
                siteMenuManager.closeSiteMenu()
                isTextFieldFocused = false
            }
        } else if delta < -12 && !showAddressBar {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { showAddressBar = true }
        }
        lastWebContentOffsetY = yOffset
    }

    // MARK: - 🎬 PIP 상태 변경 핸들러 (ContentView 내부 메서드)
    private func handlePIPStateChange(_ isPIPActive: Bool) {
        TabPersistenceManager.debugMessages.append("🎬 ContentView PIP 상태 변경: \(isPIPActive ? "활성" : "비활성")")
        if isPIPActive {
            if tabs.indices.contains(selectedTabIndex) {
                let currentTabID = tabs[selectedTabIndex].id
                WebViewPool.shared.protectWebViewForPIP(currentTabID)
                let currentWebView = createWebContentView(state: tabs[selectedTabIndex].stateModel)
                pipContainer.preserveWebView(for: currentTabID, webView: AnyView(currentWebView))
                TabPersistenceManager.debugMessages.append("🛡️ PIP 시작으로 웹뷰 보호+보존: 탭 \(String(currentTabID.uuidString.prefix(8)))")
            }
        } else {
            for tab in tabs {
                WebViewPool.shared.unprotectWebViewFromPIP(tab.id)
                pipContainer.removePreservedWebView(for: tab.id)
            }
            TabPersistenceManager.debugMessages.append("🔓 PIP 종료로 모든 웹뷰 보호+보존 해제")
        }
    }
    private func handlePIPTabChange(_ currentPIPTab: UUID?) {
        if let pipTab = currentPIPTab {
            TabPersistenceManager.debugMessages.append("🎬 PIP 탭 변경: 탭 \(String(pipTab.uuidString.prefix(8)))")
        } else {
            TabPersistenceManager.debugMessages.append("🎬 PIP 탭 해제")
        }
    }

    // MARK: - 로컬/사설 IP 판별
    private func isLocalOrPrivateIP(_ host: String) -> Bool {
        let ipPattern = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
        guard host.range(of: ipPattern, options: .regularExpression) != nil else {
            return host == "localhost" || host.hasSuffix(".local")
        }
        let comps = host.split(separator: ".").compactMap { Int($0) }
        guard comps.count == 4 else { return false }
        let (a, b, c, d) = (comps[0], comps[1], comps[2], comps[3])
        guard (0...255).contains(a) && (0...255).contains(b) && (0...255).contains(c) && (0...255).contains(d) else { return false }
        return (a == 192 && b == 168) || (a == 10) || (a == 172 && (16...31).contains(b)) || (a == 127) || (a == 169 && b == 254)
    }
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            if url.scheme == "http", let host = url.host, !isLocalOrPrivateIP(host) {
                var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comp?.scheme = "https"
                if let httpsURL = comp?.url {
                    TabPersistenceManager.debugMessages.append("🔒 HTTP → HTTPS 자동 전환: \(httpsURL.absoluteString)")
                    return httpsURL
                }
            }
            return url
        }
        if trimmed.contains(".") && !trimmed.contains(" ") {
            if isLocalOrPrivateIP(trimmed) {
                let httpURL = URL(string: "http://\(trimmed)")
                TabPersistenceManager.debugMessages.append("🏠 로컬 IP 감지, HTTP 적용: http://\(trimmed)")
                return httpURL
            } else {
                let httpsURL = URL(string: "https://\(trimmed)")
                TabPersistenceManager.debugMessages.append("🔗 도메인 감지, HTTPS 적용: https://\(trimmed)")
                return httpsURL
            }
        }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
    private func getErrorMessage(for statusCode: Int, url: String) -> (title: String, message: String) {
        let domain = URL(string: url)?.host ?? "사이트"
        switch statusCode {
        case 403: return ("\(statusCode)에러", "\(domain)에 접근할 권한이 없습니다.")
        case 404: return ("\(statusCode)에러", "페이지를 찾을 수 없습니다.")
        case 500: return ("\(statusCode)에러", "\(domain) 서버에 문제가 발생했습니다.")
        case 502: return ("\(statusCode)에러", "\(domain) 서버가 불안정합니다.")
        case 503: return ("\(statusCode)에러", "\(domain)이 점검 중이거나 과부하 상태입니다.")
        case 504: return ("\(statusCode)에러", "\(domain) 서버 응답이 늦습니다.")
        default:  return ("\(statusCode)에러", "페이지 오류가 발생했습니다.")
        }
    }
    private func getNetworkErrorMessage(for error: Error, url: String) -> (title: String, message: String)? {
        let domain = URL(string: url)?.host ?? "사이트"
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return nil }
        switch ns.code {
        case NSURLErrorCannotFindHost:        return ("주소를 찾을 수 없음 (\(ns.code))", "\(domain)을(를) 찾을 수 없습니다.")
        case NSURLErrorTimedOut:              return ("연결 시간 초과 (\(ns.code))", "\(domain) 서버 응답이 늦습니다.")
        case NSURLErrorNotConnectedToInternet:return ("인터넷 연결 없음 (\(ns.code))", "인터넷에 연결되어 있지 않습니다.")
        case NSURLErrorCannotConnectToHost:   return ("서버 연결 실패 (\(ns.code))", "\(domain) 서버에 연결할 수 없습니다.")
        case NSURLErrorNetworkConnectionLost: return ("네트워크 연결 끊김 (\(ns.code))", "네트워크 연결이 끊어졌습니다.")
        case NSURLErrorDNSLookupFailed:       return ("DNS 조회 실패 (\(ns.code))", "\(domain)의 DNS 조회에 실패했습니다.")
        case NSURLErrorBadURL:                return ("잘못된 주소 (\(ns.code))", "입력한 주소 형식이 올바르지 않습니다.")
        case NSURLErrorUnsupportedURL:        return ("지원하지 않는 주소 (\(ns.code))", "이 주소 형식은 지원하지 않습니다.")
        default: return nil
        }
    }
}

// MARK: - Recent / Autocomplete
struct RecentVisitsView: View {
    @ObservedObject var manager: SiteMenuManager
    let onURLSelected: (URL) -> Void
    let onManageHistory: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            if manager.recentVisits.isEmpty { emptyStateView } else { historyListView }
        }
    }
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundColor(.secondary)
            Text("최근 방문한 사이트가 없습니다").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }.padding(.vertical, 20)
    }
    private var historyListView: some View {
        VStack(spacing: 0) {
            ForEach(manager.recentVisits) { entry in
                historyRow(entry)
                if entry.id != manager.recentVisits.last?.id { Divider().padding(.horizontal, 14) }
            }
        }
    }
    private func historyRow(_ entry: HistoryEntry) -> some View {
        Button(action: { onURLSelected(entry.url) }) {
            HStack(spacing: 12) {
                Image(systemName: "clock").foregroundColor(.blue).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 16, weight: .medium)).foregroundColor(.primary).lineLimit(1)
                    Text(entry.url.absoluteString).font(.system(size: 14)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Text(RelativeDateTimeFormatter().localizedString(for: entry.date, relativeTo: Date()))
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct AutocompleteView: View {
    @ObservedObject var manager: SiteMenuManager
    let searchText: String
    let onURLSelected: (URL) -> Void
    let onManageHistory: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            if manager.getAutocompleteEntries(for: searchText).isEmpty { emptyStateView } else { autocompleteListView }
        }
    }
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundColor(.secondary)
            Text("'\(searchText)'에 대한 방문 기록이 없습니다").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }.padding(.vertical, 20)
    }
    private var autocompleteListView: some View {
        VStack(spacing: 0) {
            ForEach(manager.getAutocompleteEntries(for: searchText)) { entry in
                autocompleteRow(entry)
                if entry.id != manager.getAutocompleteEntries(for: searchText).last?.id { Divider().padding(.horizontal, 14) }
            }
        }
    }
    private func autocompleteRow(_ entry: HistoryEntry) -> some View {
        Button(action: { onURLSelected(entry.url) }) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundColor(.gray).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    highlightedText(entry.title, searchText: searchText).font(.system(size: 16, weight: .medium)).lineLimit(1)
                    highlightedText(entry.url.absoluteString, searchText: searchText).font(.system(size: 14)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.left").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func highlightedText(_ text: String, searchText: String) -> some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return AnyView(Text(text).foregroundColor(.primary)) }
        let parts = text.components(separatedBy: trimmed)
        if parts.count > 1 {
            return AnyView(HStack(spacing: 0) {
                ForEach(0..<parts.count, id: \.self) { i in
                    Text(parts[i]).foregroundColor(.primary)
                    if i < parts.count - 1 { Text(trimmed).foregroundColor(.blue).fontWeight(.semibold) }
                }
            })
        } else {
            return AnyView(Text(text).foregroundColor(.primary))
        }
    }
}

// MARK: - 스크롤 오프셋 PreferenceKey
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - 에러 노티
extension Notification.Name {
    static let webViewDidFailLoad = Notification.Name("webViewDidFailLoad")
}
