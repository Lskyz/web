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

// MARK: - 💧 Liquid Glass 툴바 아이템 모델
private struct LiquidToolbarItem: Identifiable {
    let id: String
    let systemName: String
    let action: () -> Void
    let enabled: Bool
    let color: Color
}

// MARK: - 💧 iOS 26+ Liquid Glass 드래그 물방울 툴바
// 핵심 원리:
//  - GlassEffectContainer 안에서 .offset으로 버튼이 겹치면 실제 물방울 합체(lensing morphing) 발생
//  - 드래그 시 모든 버튼의 x offset이 같이 이동 → 겹치는 순간 합체 애니메이션
//  - 손 떼면 spring으로 스냅백 → 분리 애니메이션 (거울/물방울 분리)
//  - .clear glass: 실제 빛 굴절(lensing) 효과, .regular: 프로스트
@available(iOS 26.0, *)
private struct LiquidGlassToolbar: View {
    let items: [LiquidToolbarItem]

    // 드래그 상태: GestureState는 손 떼면 자동 0 복귀
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var isDragging: Bool = false

    // 고무줄 저항: 일정 이상 당기면 감쇠
    private func rubberBand(_ x: CGFloat, limit: CGFloat = 70) -> CGFloat {
        let sign: CGFloat = x >= 0 ? 1 : -1
        let abs = Swift.abs(x)
        guard abs > limit else { return x }
        return sign * (limit + (abs - limit) * 0.25)
    }

    var body: some View {
        // GlassEffectContainer: 내부 glass 뷰들이 겹치면 실제 물방울 합체 렌더링
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 0) {
                ForEach(items) { item in
                    // 버튼 label에 background 없이 Image만 + frame
                    // → glassEffect가 캡슐 모양으로 버튼 전체를 감쌈
                    Button {
                        guard item.enabled else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        item.action()
                    } label: {
                        Image(systemName: item.systemName)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(item.enabled ? item.color : Color.secondary)
                            .frame(width: 50, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                    // glassEffect를 Button 바깥(전체)에 적용
                    // .clear: 빛 굴절 lensing 효과 극대화
                    // .interactive(): 터치 시 반응형 하이라이트
                    .glassEffect(.clear.interactive(), in: .capsule)
                    // 드래그 offset은 glassEffect 밖에서 적용해야
                    // GlassEffectContainer가 실제 위치를 계산해 합체 처리
                    .offset(x: rubberBand(dragTranslation))
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                // @GestureState: 손 떼면 자동으로 0 → spring 스냅백 트리거
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation.width
                }
                .onChanged { _ in
                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.8)) {
                        isDragging = true
                    }
                }
                .onEnded { _ in
                    // GestureState가 0으로 복귀하면서 spring 분리 애니메이션 발생
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.65)) {
                        isDragging = false
                    }
                }
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 💧 iOS 25 이하 폴백 툴바 (기존 그대로)
private struct FallbackToolbar: View {
    let items: [LiquidToolbarItem]
    let spacing: CGFloat
    let iconSize: CGFloat

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(items) { item in
                Button(action: {
                    guard item.enabled else { return }
                    item.action()
                }) {
                    Image(systemName: item.systemName)
                        .font(.system(size: iconSize))
                        .foregroundColor(item.enabled ? item.color : .secondary)
                }
                .disabled(!item.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
    
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var errorTitle = ""
    @StateObject private var pipManager = PIPManager.shared
    @StateObject private var pipContainer = PIPWebViewContainer.shared
    @StateObject private var siteMenuManager = SiteMenuManager()

    @State private var isMenuButtonPressed = false
    @State private var menuButtonPressStartTime: Date? = nil

    private let outerHorizontalPadding: CGFloat = 22
    private let barCornerRadius: CGFloat = 20
    private let barVPadding: CGFloat = 10
    private let iconSize: CGFloat = 23
    private let textFont: Font = .system(size: 16, weight: .medium)
    private let toolbarSpacing: CGFloat = 40
    private let whiteGlassMaterial: UIBlurEffect.Style = .extraLight
    private let whiteGlassTintOpacity: CGFloat = 0.1
    private let whiteGlassIntensity: CGFloat = 0.80
    
    @State private var keyboardHeight: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                mainContentView
                VStack {
                    Spacer()
                    bottomUnifiedUIContent()
                        .padding(.bottom, keyboardHeight)
                        .animation(.easeInOut(duration: 0.25), value: keyboardHeight)
                }
            }
        }
        .ignoresSafeArea(.all, edges: [.leading, .trailing, .bottom])
        .ignoresSafeArea(.keyboard, edges: .all)
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
                .ignoresSafeArea(.all, edges: .all)
                .ignoresSafeArea(.keyboard, edges: .all)
        }
        .onChange(of: pipManager.isPIPActive) { handlePIPStateChange($0) }
        .onChange(of: pipManager.currentPIPTab) { handlePIPTabChange($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { n in
            updateKeyboard(from: n, animated: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            updateKeyboard(from: n, animated: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { keyboardHeight = 0 }
        }
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
        .ignoresSafeArea(.keyboard, edges: .all)
    }
    
    private func updateKeyboard(from n: Notification, animated: Bool) {
        guard let endFrame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) else { return }
        let screen = UIScreen.main.bounds
        let safeBottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 0
        let kh = max(0, screen.maxY - endFrame.minY)
        let adjusted = max(0, kh - safeBottom)
        if animated {
            let dur = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeInOut(duration: dur)) { keyboardHeight = adjusted }
        } else {
            keyboardHeight = adjusted
        }
    }

    private var currentState: WebViewStateModel {
        if tabs.indices.contains(selectedTabIndex) { return tabs[selectedTabIndex].stateModel }
        return WebViewStateModel()
    }
    
    // MARK: - 💧 툴바 아이템 목록
    private var liquidToolbarItems: [LiquidToolbarItem] {
        var items: [LiquidToolbarItem] = [
            .init(id: "back",    systemName: "chevron.left",
                  action: { currentState.goBack(); TabPersistenceManager.debugMessages.append("🎯 뒤로가기") },
                  enabled: currentState.canGoBack,    color: .primary),
            .init(id: "forward", systemName: "chevron.right",
                  action: { currentState.goForward(); TabPersistenceManager.debugMessages.append("🎯 앞으로가기") },
                  enabled: currentState.canGoForward, color: .primary),
            .init(id: "history", systemName: "clock.arrow.circlepath",
                  action: { showHistorySheet = true },
                  enabled: true, color: .primary),
            .init(id: "tabs",    systemName: "square.on.square",
                  action: { showTabManager = true },
                  enabled: true, color: .primary),
        ]
        if pipManager.isPIPActive {
            items.append(.init(id: "pip", systemName: "pip.fill",
                               action: { pipManager.stopPIP() },
                               enabled: true, color: .green))
        }
        items.append(.init(id: "debug", systemName: "ladybug",
                           action: { showDebugView = true },
                           enabled: true, color: .orange))
        return items
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
                    if let i = tabs.firstIndex(where: { $0.id == state.tabID }) { return tabs[i].playerURL }
                    return nil
                },
                set: { nv in
                    if let i = tabs.firstIndex(where: { $0.id == state.tabID }) {
                        tabs[i].playerURL = nv
                        if let url = nv, tabs[i].showAVPlayer { pipManager.pipPlayerURL = url }
                    }
                }
            ),
            showAVPlayer: Binding(
                get: { if let i = tabs.firstIndex(where: { $0.id == state.tabID }) { return tabs[i].showAVPlayer }; return false },
                set: { nv in
                    if let i = tabs.firstIndex(where: { $0.id == state.tabID }) {
                        tabs[i].showAVPlayer = nv
                        if !nv && pipManager.currentPIPTab == tabs[i].id { pipManager.stopPIP() }
                    }
                }
            ),
            onScroll: { y in handleWebViewScroll(yOffset: y) }
        )
        .id(state.tabID)
        .ignoresSafeArea(.keyboard, edges: .all)
    }
    
    private var dashboardView: some View {
        DashboardView(onNavigateToURL: handleDashboardNavigation(_:))
            .contentShape(Rectangle())
            .onTapGesture(perform: onContentTap)
            .ignoresSafeArea(.keyboard, edges: .all)
    }
    
    private var scrollOffsetOverlay: some View {
        GeometryReader { g in
            Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: g.frame(in: .global).origin.y)
        }
    }
    
    // MARK: - 🎯 통합된 하단 UI
    @ViewBuilder
    private func bottomUnifiedUIContent() -> some View {
        VStack(spacing: 0) {
            // 1️⃣ 주소창 관련 콘텐츠
            if showAddressBar && (isTextFieldFocused || inputURL.isEmpty) {
                addressBarHistoryContent
                    .padding(.horizontal, outerHorizontalPadding)
                    .ignoresSafeArea(.keyboard, edges: .all)
            }
            
            // 2️⃣ 통합 툴바
            VStack(spacing: 12) {
                if showAddressBar {
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
                                    .background(Circle().fill(Color(UIColor.systemBackground)))
                                    .overlay(Circle().strokeBorder(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5))
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
                
                // 💧 네비게이션 툴바 — iOS 26 분기
                if #available(iOS 26.0, *) {
                    LiquidGlassToolbar(items: liquidToolbarItems)
                        .padding(.horizontal, outerHorizontalPadding)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onToolbarTap)
                } else {
                    FallbackToolbar(
                        items: liquidToolbarItems,
                        spacing: toolbarSpacing,
                        iconSize: iconSize
                    )
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToolbarTap)
                }
            }
            .padding(.vertical, barVPadding)
            .padding(.bottom, max(20, UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?.safeAreaInsets.bottom ?? 0))
        }
        .background(
            GeometryReader { geometry in
                whiteGlassBackground
                    .frame(width: UIScreen.main.bounds.width,
                           height: UIScreen.main.bounds.height - geometry.safeAreaInsets.top)
                    .offset(x: -geometry.frame(in: .global).minX,
                            y: max(0, geometry.safeAreaInsets.top - geometry.frame(in: .global).minY))
            }
        )
        .overlay(
            GeometryReader { geometry in
                whiteGlassOverlay
                    .frame(width: UIScreen.main.bounds.width,
                           height: UIScreen.main.bounds.height - geometry.safeAreaInsets.top)
                    .offset(x: -geometry.frame(in: .global).minX,
                            y: max(0, geometry.safeAreaInsets.top - geometry.frame(in: .global).minY))
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
        .ignoresSafeArea(.keyboard, edges: .all)
    }
    
    // MARK: - 방문기록/자동완성
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
                Divider().background(Color(UIColor.separator).opacity(0.3))
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
    
    // MARK: - 주소창 메인
    private var addressBarMainContent: some View {
        HStack(spacing: 8) {
            if !isTextFieldFocused {
                menuButton
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            if !isTextFieldFocused {
                siteSecurityIcon
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            urlTextField
            if isTextFieldFocused {
                clearButton
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                refreshButton
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, barVPadding)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isTextFieldFocused)
    }
    
    private var menuButton: some View {
        Button(action: {
            siteMenuManager.setCurrentStateModel(currentState)
            siteMenuManager.toggleSiteMenu()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            TabPersistenceManager.debugMessages.append("🍔 메뉴 버튼으로 사이트 메뉴 토글: \(siteMenuManager.showSiteMenu)")
        }) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.black)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isMenuButtonPressed ? Color.black.opacity(0.1) : Color.clear)
                        .animation(.easeInOut(duration: 0.1), value: isMenuButtonPressed)
                )
                .scaleEffect(isMenuButtonPressed ? 0.95 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isMenuButtonPressed)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isMenuButtonPressed { isMenuButtonPressed = true; menuButtonPressStartTime = Date() }
                }
                .onEnded { _ in
                    isMenuButtonPressed = false
                    menuButtonPressStartTime = nil
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
        if url.scheme == "http"  { return "exclamationmark.triangle.fill" }
        return "globe"
    }
    private func getSiteIconColor() -> Color {
        guard let url = currentState.currentURL else { return .secondary }
        if url.scheme == "https" { return .green }
        if url.scheme == "http"  { return .orange }
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
    }
    
    private var clearButton: some View {
        Button(action: {
            inputURL = ""
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(width: 32, height: 32)
        .opacity(!inputURL.isEmpty ? 1.0 : 0.3)
        .disabled(inputURL.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: inputURL.isEmpty)
    }
    
    private var refreshButton: some View {
        Button(action: {
            if currentState.isLoading {
                currentState.stopLoading()
                TabPersistenceManager.debugMessages.append("로딩 중지")
            } else {
                currentState.reload()
                TabPersistenceManager.debugMessages.append("페이지 새로고침")
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        if let url = currentState.currentURL { inputURL = url.absoluteString }
        siteMenuManager.setCurrentStateModel(currentState)
        siteMenuManager.refreshDownloads()
    }
    private func onURLChange(url: URL?) { if let url = url { inputURL = url.absoluteString } }
    private func onNavigationFinish(_: Void) {
        if let r = currentState.currentPageRecord {
            let back = currentState.canGoBack ? "가능" : "불가"
            let fwd  = currentState.canGoForward ? "가능" : "불가"
            TabPersistenceManager.debugMessages.append("HIST ⏪\(back) ▶︎\(fwd) | '\(r.title)' [ID: \(r.id.uuidString.prefix(8)))")
        } else {
            TabPersistenceManager.debugMessages.append("HIST 페이지 기록 없음")
        }
        TabPersistenceManager.saveTabs(tabs)
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
                        let fwd  = s.canGoForward ? "가능" : "불가"
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
            set: { nv in
                if tabs.indices.contains(selectedTabIndex) {
                    tabs[selectedTabIndex].showAVPlayer = nv
                    if !nv && pipManager.currentPIPTab == tabs[selectedTabIndex].id { pipManager.stopPIP() }
                }
            }
        )
    }
    @ViewBuilder private func avPlayerView() -> some View {
        if tabs.indices.contains(selectedTabIndex), let url = tabs[selectedTabIndex].playerURL {
            AVPlayerView(url: url).ignoresSafeArea(.keyboard, edges: .all)
        }
    }
    @ViewBuilder private func debugView() -> some View {
        GeometryReader { geometry in
            DebugLogView().frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.all, edges: .all)
        .ignoresSafeArea(.keyboard, edges: .all)
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            TabPersistenceManager.debugMessages.append("🛡️ DebugView 완전 격리 모드 - 키보드 리셋")
        }
    }
    
    private func onScrollOffsetChange(offset: CGFloat) {
        if isTextFieldFocused || isMenuButtonPressed || siteMenuManager.showSiteMenu {
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
        if isMenuButtonPressed { return }
        if let t = menuButtonPressStartTime, Date().timeIntervalSince(t) < 0.3 { menuButtonPressStartTime = nil; return }
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
            }
        }
    }
    private func onTextFieldFocusChange(focused: Bool) {
        if !focused { textFieldSelectedAll = false }
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
        if isTextFieldFocused || isMenuButtonPressed || siteMenuManager.showSiteMenu { lastWebContentOffsetY = yOffset; return }
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
    private func handlePIPStateChange(_ isPIPActive: Bool) {
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
                TabPersistenceManager.debugMessages.append("🏠 로컬 IP 감지, HTTP 적용: http://\(trimmed)")
                return URL(string: "http://\(trimmed)")
            } else {
                TabPersistenceManager.debugMessages.append("🔗 도메인 감지, HTTPS 적용: https://\(trimmed)")
                return URL(string: "https://\(trimmed)")
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
        case NSURLErrorCannotFindHost:         return ("주소를 찾을 수 없음 (\(ns.code))", "\(domain)을(를) 찾을 수 없습니다.")
        case NSURLErrorTimedOut:               return ("연결 시간 초과 (\(ns.code))", "\(domain) 서버 응답이 늦습니다.")
        case NSURLErrorNotConnectedToInternet: return ("인터넷 연결 없음 (\(ns.code))", "인터넷에 연결되어 있지 않습니다.")
        case NSURLErrorCannotConnectToHost:    return ("서버 연결 실패 (\(ns.code))", "\(domain) 서버에 연결할 수 없습니다.")
        case NSURLErrorNetworkConnectionLost:  return ("네트워크 연결 끊김 (\(ns.code))", "네트워크 연결이 끊어졌습니다.")
        case NSURLErrorDNSLookupFailed:        return ("DNS 조회 실패 (\(ns.code))", "\(domain)의 DNS 조회에 실패했습니다.")
        case NSURLErrorBadURL:                 return ("잘못된 주소 (\(ns.code))", "입력한 주소 형식이 올바르지 않습니다.")
        case NSURLErrorUnsupportedURL:         return ("지원하지 않는 주소 (\(ns.code))", "이 주소 형식은 지원하지 않습니다.")
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
