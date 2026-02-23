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

// MARK: - 🔵 Liquid Glass Lens 시스템

/// 툴바/주소창에서 사용할 버튼 항목 모델
struct LiquidGlassItem: Identifiable {
    let id: UUID = UUID()
    let systemImage: String
    let action: () -> Void
    var isEnabled: Bool = true
    var color: Color = .primary
}

/// Liquid Glass 렌즈 오버레이
/// - 버튼 위에 나타나는 슬라이딩 가능한 시스템 Material 기반 렌즈
/// - 즉시 탭 → 해당 액션 실행
/// - 드래그 → 인접 버튼으로 이동 후 손 뗄 때 액션 실행
@available(iOS 26, *)
struct LiquidGlassLensOverlay: View {
    /// 버튼 항목 목록 (순서대로 좌→우)
    let items: [LiquidGlassItem]
    /// 아이콘 크기 (ContentView.iconSize와 일치)
    var iconSize: CGFloat = 23
    /// 버튼 간격 (ContentView.toolbarSpacing과 일치)
    var itemSpacing: CGFloat = 40
    /// 렌즈 크기
    var lensSize: CGFloat = 52
    /// 현재 활성 인덱스
    @Binding var activeIndex: Int?
    /// 외부에서 렌즈 표시/숨김 제어
    @Binding var isVisible: Bool

    // 드래그 상태
    @State private var dragOffsetX: CGFloat = 0
    @GestureState private var isDragging: Bool = false

    @Namespace private var glassNamespace

    var body: some View {
        // 아무 항목도 없으면 렌더링 안 함
        if items.isEmpty { return AnyView(EmptyView()) }

        return AnyView(
            GeometryReader { geo in
                if isVisible, let idx = activeIndex {
                    let centerX = lensPositionX(for: idx, in: geo.size.width)
                    let lensX = centerX + dragOffsetX - lensSize / 2

                    GlassEffectContainer(spacing: 0) {
                        ZStack {
                            // 렌즈 배경 (Interactive Liquid Glass)
                            RoundedRectangle(cornerRadius: lensSize / 2)
                                .fill(Color.clear)
                                .frame(width: lensSize, height: lensSize)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .glassEffectID("lens", in: glassNamespace)

                            // 렌즈 안 아이콘
                            if let displayIdx = currentHoveredIndex(anchorIdx: idx, in: geo.size.width),
                               items.indices.contains(displayIdx) {
                                let item = items[displayIdx]
                                Image(systemName: item.systemImage)
                                    .font(.system(size: iconSize + 2, weight: .medium))
                                    .foregroundColor(item.isEnabled ? item.color : .secondary)
                                    .contentTransition(.symbolEffect(.replace))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(width: lensSize, height: lensSize)
                    .position(
                        x: clampedLensPositionX(lensX + lensSize / 2, in: geo.size.width),
                        y: geo.size.height / 2
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($isDragging) { _, state, _ in state = true }
                            .onChanged { value in
                                dragOffsetX = value.translation.width
                            }
                            .onEnded { value in
                                let finalX = lensPositionX(for: idx, in: geo.size.width) + value.translation.width
                                if let targetIdx = snapIndex(for: finalX, in: geo.size.width) {
                                    let item = items[targetIdx]
                                    if item.isEnabled {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        item.action()
                                    }
                                }
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    dragOffsetX = 0
                                    isVisible = false
                                    activeIndex = nil
                                }
                            }
                    )
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .animation(.spring(response: 0.38, dampingFraction: 0.72), value: activeIndex)
                    .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.85), value: dragOffsetX)
                }
            }
        )
    }

    // MARK: - 좌표 계산

    /// 인덱스에 대응하는 렌즈 중심 X (GeometryReader 내부 좌표)
    private func lensPositionX(for index: Int, in width: CGFloat) -> CGFloat {
        // 버튼들은 HStack spacing=toolbarSpacing으로 균등 배치, frame maxWidth=infinity 중앙 정렬
        // 전체 버튼 영역 너비 = (n-1)*spacing
        let n = items.count
        let totalSpan = CGFloat(n - 1) * itemSpacing
        let startX = (width - totalSpan) / 2
        return startX + CGFloat(index) * itemSpacing
    }

    /// 드래그 중 현재 호버 인덱스
    private func currentHoveredIndex(anchorIdx: Int, in width: CGFloat) -> Int? {
        let currentX = lensPositionX(for: anchorIdx, in: width) + dragOffsetX
        return snapIndex(for: currentX, in: width)
    }

    /// X 좌표에서 가장 가까운 버튼 인덱스
    private func snapIndex(for x: CGFloat, in width: CGFloat) -> Int? {
        guard !items.isEmpty else { return nil }
        var closest = 0
        var minDist = CGFloat.infinity
        for i in items.indices {
            let bx = lensPositionX(for: i, in: width)
            let d = abs(x - bx)
            if d < minDist { minDist = d; closest = i }
        }
        return closest
    }

    /// 렌즈가 화면 밖으로 나가지 않도록 클램프
    private func clampedLensPositionX(_ x: CGFloat, in width: CGFloat) -> CGFloat {
        let half = lensSize / 2
        return min(max(x, half + 8), width - half - 8)
    }
}

/// iOS 26 미만 폴백 — 렌즈 없음 (기존 버튼 그대로 동작)
struct LiquidGlassLensFallback: View {
    var body: some View { EmptyView() }
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

    @State private var isMenuButtonPressed = false
    @State private var menuButtonPressStartTime: Date? = nil

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

    // 🔵 Liquid Glass 렌즈 상태
    @State private var lensActiveIndex: Int? = nil
    @State private var lensVisible: Bool = false

    // ✅ 키보드 높이 추가 (수동 처리 필요)
    @State private var keyboardHeight: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 메인 웹 콘텐츠 (전체 underlap)
                mainContentView

                // 하단 통합 UI 고정: 키보드만큼 상승
                VStack {
                    Spacer()
                    bottomUnifiedUIContent()
                        .padding(.bottom, keyboardHeight)
                        .animation(.easeInOut(duration: 0.25), value: keyboardHeight)
                }
            }
        }
        // 🔽 상단은 안전영역 유지 (다이나믹 아일랜드/노치), 하단만 무시
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

        // 🎬 PIP 상태 동기화
        .onChange(of: pipManager.isPIPActive) { handlePIPStateChange($0) }
        .onChange(of: pipManager.currentPIPTab) { handlePIPTabChange($0) }

        // ✅ 키보드 높이 수동 계산
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
    
    // MARK: - 키보드 높이 수동 계산
    private func updateKeyboard(from n: Notification, animated: Bool) {
        guard let endFrame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) else { return }
        let screen = UIScreen.main.bounds
        let safeBottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 0
        let keyboardHeight = max(0, screen.maxY - endFrame.minY)
        let adjustedHeight = max(0, keyboardHeight - safeBottom)
        if animated {
            let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeInOut(duration: duration)) { self.keyboardHeight = adjustedHeight }
        } else {
            self.keyboardHeight = adjustedHeight
        }
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
    
    // MARK: - 🔵 Liquid Glass 렌즈 버튼 항목 빌더
    private func buildToolbarLensItems() -> [LiquidGlassItem] {
        var items: [LiquidGlassItem] = [
            LiquidGlassItem(
                systemImage: "chevron.left",
                action: { currentState.goBack(); TabPersistenceManager.debugMessages.append("🔵 Lens: 뒤로가기") },
                isEnabled: currentState.canGoBack
            ),
            LiquidGlassItem(
                systemImage: "chevron.right",
                action: { currentState.goForward(); TabPersistenceManager.debugMessages.append("🔵 Lens: 앞으로가기") },
                isEnabled: currentState.canGoForward
            ),
            LiquidGlassItem(
                systemImage: "clock.arrow.circlepath",
                action: { showHistorySheet = true },
                isEnabled: true
            ),
            LiquidGlassItem(
                systemImage: "square.on.square",
                action: { showTabManager = true },
                isEnabled: true
            ),
        ]
        if pipManager.isPIPActive {
            items.append(LiquidGlassItem(
                systemImage: "pip.fill",
                action: { pipManager.stopPIP() },
                isEnabled: true,
                color: .green
            ))
        }
        items.append(LiquidGlassItem(
            systemImage: "ladybug",
            action: { showDebugView = true },
            isEnabled: true,
            color: .orange
        ))
        return items
    }

    // MARK: - 메뉴 버튼용 렌즈 항목 (단일)
    private func buildMenuLensItems() -> [LiquidGlassItem] {
        [LiquidGlassItem(
            systemImage: "line.3.horizontal",
            action: {
                siteMenuManager.setCurrentStateModel(currentState)
                siteMenuManager.toggleSiteMenu()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                TabPersistenceManager.debugMessages.append("🔵 Lens: 메뉴 토글")
            },
            isEnabled: true
        )]
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
                
                // 🔵 네비게이션 툴바 + Liquid Glass 렌즈 레이어
                toolbarWithLens
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

    // MARK: - 🔵 툴바 + 렌즈 레이어 통합 뷰
    @ViewBuilder
    private var toolbarWithLens: some View {
        let lensItems = buildToolbarLensItems()

        ZStack {
            // 기존 툴바 버튼들 (렌즈 활성 시 반투명)
            HStack(spacing: 0) {
                HStack(spacing: toolbarSpacing) {
                    // 각 버튼에 롱프레스/탭 제스처로 렌즈 활성화
                    ForEach(Array(lensItems.enumerated()), id: \.offset) { idx, item in
                        lensAwareToolbarButton(
                            systemImage: item.systemImage,
                            action: item.action,
                            enabled: item.isEnabled,
                            color: item.color,
                            index: idx,
                            totalItems: lensItems
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToolbarTap)
            // 렌즈 활성 시 배경 버튼 희미하게
            .opacity(lensVisible ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: lensVisible)

            // 🔵 Liquid Glass 렌즈 오버레이 (iOS 26+)
            if #available(iOS 26, *) {
                GeometryReader { geo in
                    // 렌즈가 차지할 영역: 버튼들이 중앙 정렬이므로 HStack 전체 너비 = geo.size.width - 32(패딩)
                    let toolbarWidth = geo.size.width - 32
                    let offsetX: CGFloat = 16 // 패딩

                    LiquidGlassLensOverlay(
                        items: lensItems,
                        iconSize: iconSize,
                        itemSpacing: toolbarSpacing,
                        lensSize: 52,
                        activeIndex: $lensActiveIndex,
                        isVisible: $lensVisible
                    )
                    .frame(width: toolbarWidth, height: geo.size.height)
                    .offset(x: offsetX)
                }
            }
        }
        .frame(height: 52)
    }

    /// 렌즈 인식 툴바 버튼 — 탭 즉시 액션, 롱프레스 시 렌즈 활성화
    @ViewBuilder
    private func lensAwareToolbarButton(
        systemImage: String,
        action: @escaping () -> Void,
        enabled: Bool,
        color: Color,
        index: Int,
        totalItems: [LiquidGlassItem]
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize))
            .foregroundColor(enabled ? color : .secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            // 즉시 탭 → 액션 실행
            .onTapGesture {
                guard enabled else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action()
            }
            // 롱프레스 → 렌즈 활성화
            .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                if pressing {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                        lensActiveIndex = index
                        lensVisible = true
                    }
                }
            }, perform: {})
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
    
    // MARK: - 주소창 내부
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
    
    // 🔵 메뉴 버튼도 렌즈 인식 적용
    private var menuButton: some View {
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
            .contentShape(Circle())
            // 즉시 탭
            .onTapGesture {
                siteMenuManager.setCurrentStateModel(currentState)
                siteMenuManager.toggleSiteMenu()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                TabPersistenceManager.debugMessages.append("🍔 메뉴 버튼 탭")
            }
            // 롱프레스 → 렌즈 (메뉴 버튼은 단독 아이템이므로 별도 렌즈)
            .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                isMenuButtonPressed = pressing
                if pressing {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                        lensActiveIndex = 0
                        lensVisible = true
                    }
                }
            }, perform: {})
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
        if let url = currentState.currentURL { inputURL = url.absoluteString; TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)") }
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
                .ignoresSafeArea(.keyboard, edges: .all)
        }
    }
    @ViewBuilder private func debugView() -> some View {
        GeometryReader { geometry in
            DebugLogView()
                .frame(width: geometry.size.width, height: geometry.size.height)
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

    // MARK: - 🎬 PIP 상태 변경 핸들러
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
