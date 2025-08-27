import SwiftUI
import AVKit
import WebKit

// ============================================================
// ✨ 투명한 흰색 유리 효과 (Clean White Glass)
// - 매우 투명한 블러와 미세한 흰색 틴트
// - 부드러운 테두리와 깔끔한 투명도
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
        
        // ✨ 투명한 흰색 유리 효과
        setupWhiteGlassEffect(effectView)
        
        return effectView
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        let effect = UIBlurEffect(style: blurStyle)
        uiView.effect = effect
        uiView.layer.cornerRadius = cornerRadius
        uiView.backgroundColor = .clear
        uiView.alpha = intensity
    }
    
    private func setupWhiteGlassEffect(_ effectView: UIVisualEffectView) {
        // ✨ 미세한 흰색 그라데이션 레이어
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            UIColor.white.withAlphaComponent(0.1).cgColor,
            UIColor.white.withAlphaComponent(0.05).cgColor,
            UIColor.clear.cgColor
        ]
        gradientLayer.locations = [0.0, 0.8, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        
        effectView.contentView.layer.addSublayer(gradientLayer)
        
        // 레이어 크기 자동 조정
        DispatchQueue.main.async {
            gradientLayer.frame = effectView.bounds
        }
    }
}

// MARK: - 🎬 **PIP 보존용 웹뷰 컨테이너**
class PIPWebViewContainer: ObservableObject {
    static let shared = PIPWebViewContainer()
    
    // PIP 중인 웹뷰들을 보존 (탭 ID별로)
    private var preservedWebViews: [UUID: AnyView] = [:]
    
    private init() {
        TabPersistenceManager.debugMessages.append("🎬 PIP 웹뷰 컨테이너 초기화")
    }
    
    // PIP 시작 시 웹뷰 보존
    func preserveWebView(for tabID: UUID, webView: AnyView) {
        preservedWebViews[tabID] = webView
        TabPersistenceManager.debugMessages.append("🎬 웹뷰 보존: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 보존된 웹뷰 가져오기
    func getPreservedWebView(for tabID: UUID) -> AnyView? {
        return preservedWebViews[tabID]
    }
    
    // PIP 종료 시 웹뷰 보존 해제
    func removePreservedWebView(for tabID: UUID) {
        preservedWebViews.removeValue(forKey: tabID)
        TabPersistenceManager.debugMessages.append("🎬 웹뷰 보존 해제: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 특정 탭이 PIP 보존 중인지 확인
    func isWebViewPreserved(for tabID: UUID) -> Bool {
        return preservedWebViews.keys.contains(tabID)
    }
    
    // 모든 보존 해제
    func clearAll() {
        preservedWebViews.removeAll()
        TabPersistenceManager.debugMessages.append("🎬 모든 웹뷰 보존 해제")
    }
}

/// 웹 브라우저의 메인 콘텐츠 뷰 - 🎯 사파리 스타일 드롭업 메뉴 + 팝업 차단 통합 + 주소창 기록 표시
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
    
    // ✨ 에러 처리 및 로딩 상태
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var errorTitle = ""
    
    // 🎬 **PIP 관리자 상태 감지 추가**
    @StateObject private var pipManager = PIPManager.shared
    
    // 🎬 **PIP 웹뷰 보존 컨테이너**
    @StateObject private var pipContainer = PIPWebViewContainer.shared
    
    // 🧩 **핵심 추가: 통합 사이트 메뉴 매니저**
    @StateObject private var siteMenuManager = SiteMenuManager()

    // 🧩 퍼즐 버튼 터치 상태 관리
    @State private var isPuzzleButtonPressed = false
    @State private var puzzleButtonPressStartTime: Date? = nil

    // ============================================================
    // ✨ 투명한 흰색 유리 효과 설정
    // ============================================================
    private let outerHorizontalPadding: CGFloat = 22
    private let barCornerRadius: CGFloat       = 20
    private let barVPadding: CGFloat           = 10
    private let iconSize: CGFloat              = 23
    private let textFont: Font                 = .system(size: 16, weight: .medium)
    private let toolbarSpacing: CGFloat        = 40

    // ✨ 투명한 흰색 유리 효과 설정
    private let whiteGlassMaterial: UIBlurEffect.Style = .extraLight
    private let whiteGlassTintOpacity: CGFloat = 0.1
    private let whiteGlassIntensity: CGFloat = 0.80
    
    @State private var keyboardHeight: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 메인 콘텐츠 (웹뷰 또는 대시보드)
                mainContentView
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                
                // 하단 UI (주소창 + 툴바) - VStack으로 하단에 고정
                VStack {
                    Spacer()
                    bottomUIContent()
                        .offset(y: -keyboardHeight)
                        .animation(.easeInOut(duration: 0.25), value: keyboardHeight)
                }
            }
        }
        .onAppear(perform: onAppearHandler)
        .onReceive(currentState.$currentURL, perform: onURLChange)
        .onReceive(currentState.navigationDidFinish, perform: onNavigationFinish)
        .onReceive(errorNotificationPublisher, perform: onErrorReceived)
        .alert(errorTitle, isPresented: $showErrorAlert, actions: alertActions, message: alertMessage)
        .sheet(isPresented: $showHistorySheet, content: historySheet)
        .sheet(isPresented: $showTabManager, content: tabManagerView)
        .fullScreenCover(isPresented: avPlayerBinding, content: avPlayerView)
        .fullScreenCover(isPresented: $showDebugView, content: debugView)
        
        // 🎬 **PIP 상태 변경 감지 및 탭 동기화**
        .onChange(of: pipManager.isPIPActive) { isPIPActive in
            handlePIPStateChange(isPIPActive)
        }
        .onChange(of: pipManager.currentPIPTab) { currentPIPTab in
            handlePIPTabChange(currentPIPTab)
        }

        // ✅ SwiftUI의 키보드 자동 인셋 무시(웹뷰에 빈공간 방지)
       // .ignoresSafeArea(.keyboard, edges: .all)

        // ✅ 키보드 프레임 변경에 맞춰 실제 겹침 높이(Intersection)로 계산
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard
                let endFrame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                let duration = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
            else { return }

            // 현재 키 윈도우
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }

            let bounds   = window?.bounds ?? UIScreen.main.bounds
            // 좌표계를 윈도우 기준으로 변환
            let kbFrame  = window?.convert(endFrame, from: nil) ?? endFrame
            // 화면과 키보드의 실제 겹치는 높이
            let overlap  = max(0, bounds.intersection(kbFrame).height)
            let bottomSA = window?.safeAreaInsets.bottom ?? 0

            // 키보드가 사실상 내려간 상태인지 보정(부동소수 및 오차 보정)
            let hidden = overlap <= bottomSA + 0.5 || kbFrame.minY >= bounds.maxY - 0.5

            withAnimation(.easeInOut(duration: duration)) {
                keyboardHeight = hidden ? 0 : max(0, overlap - bottomSA)
            }
        }

        // ✅ 완전 숨김 이벤트에서 확정적으로 0
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardHeight = 0
        }
        
        // 🧩 **핵심 추가: 통합 사이트 메뉴 오버레이**
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
    
    // MARK: - 🎬 **PIP 상태 변경 핸들러들 수정**
    
    private func handlePIPStateChange(_ isPIPActive: Bool) {
        TabPersistenceManager.debugMessages.append("🎬 ContentView PIP 상태 변경: \(isPIPActive ? "활성" : "비활성")")
        
        if isPIPActive {
            // PIP 시작됨 - 현재 탭의 웹뷰 보호 및 보존
            if tabs.indices.contains(selectedTabIndex) {
                let currentTabID = tabs[selectedTabIndex].id
                WebViewPool.shared.protectWebViewForPIP(currentTabID)
                
                // 🎬 **핵심**: 현재 웹뷰를 보존
                let currentWebView = createWebContentView(state: tabs[selectedTabIndex].stateModel)
                pipContainer.preserveWebView(for: currentTabID, webView: AnyView(currentWebView))
                
                TabPersistenceManager.debugMessages.append("🛡️ PIP 시작으로 웹뷰 보호+보존: 탭 \(String(currentTabID.uuidString.prefix(8)))")
            }
        } else {
            // PIP 종료됨 - 모든 웹뷰 보호 해제 및 보존 해제
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
    
    // MARK: - 컴포넌트 분해
    
    private var currentState: WebViewStateModel {
        if tabs.indices.contains(selectedTabIndex) {
            return tabs[selectedTabIndex].stateModel
        } else {
            // 빈 상태 반환
            return WebViewStateModel()
        }
    }
    
    @ViewBuilder
    private var mainContentView: some View {
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel
            
            ZStack {
                if state.currentURL != nil {
                    // 🎬 **핵심**: PIP 보존 웹뷰가 있으면 우선 사용
                    if let preservedWebView = pipContainer.getPreservedWebView(for: tabs[selectedTabIndex].id) {
                        preservedWebView
                            .onAppear {
                                TabPersistenceManager.debugMessages.append("🎬 보존된 PIP 웹뷰 사용: 탭 \(String(tabs[selectedTabIndex].id.uuidString.prefix(8)))")
                            }
                    } else {
                        webContentView(state: state)
                    }
                } else {
                    dashboardView
                }
                
                // 🎬 **PIP 상태 표시 오버레이 (선택사항)**
                if pipManager.isPIPActive {
                    pipStatusOverlay
                }
            }
        } else {
            dashboardView
        }
    }
    
    // 🎬 **PIP 상태 표시 오버레이**
    @ViewBuilder
    private var pipStatusOverlay: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "pip.fill")
                        .font(.caption)
                    Text("PIP 활성")
                        .font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .foregroundColor(.green)
                .cornerRadius(16)
                .padding(.trailing)
                .padding(.top, 60)
            }
            Spacer()
        }
        .allowsHitTesting(false) // 터치 이벤트 차단 방지
    }
    
    @ViewBuilder
    private func webContentView(state: WebViewStateModel) -> some View {
        createWebContentView(state: state)
            .overlay(scrollOffsetOverlay)
            .onPreferenceChange(ScrollOffsetPreferenceKey.self, perform: onScrollOffsetChange)
            .contentShape(Rectangle())
            .onTapGesture(perform: onContentTap)
    }
    
    // 🎬 **웹뷰 생성 함수 분리 (보존용)**
    @ViewBuilder
    private func createWebContentView(state: WebViewStateModel) -> some View {
        CustomWebView(
            stateModel: state,
            playerURL: Binding(
                get: { 
                    if let index = tabs.firstIndex(where: { $0.id == state.tabID }) {
                        return tabs[index].playerURL
                    }
                    return nil
                },
                set: { newValue in
                    if let index = tabs.firstIndex(where: { $0.id == state.tabID }) {
                        tabs[index].playerURL = newValue
                        
                        // 🎬 **PIP URL 동기화**
                        if let url = newValue, tabs[index].showAVPlayer {
                            pipManager.pipPlayerURL = url
                        }
                    }
                }
            ),
            showAVPlayer: Binding(
                get: { 
                    if let index = tabs.firstIndex(where: { $0.id == state.tabID }) {
                        return tabs[index].showAVPlayer
                    }
                    return false
                },
                set: { newValue in
                    if let index = tabs.firstIndex(where: { $0.id == state.tabID }) {
                        tabs[index].showAVPlayer = newValue
                        
                        // 🎬 **PIP 상태와 AVPlayer 표시 동기화**
                        if !newValue && pipManager.currentPIPTab == tabs[index].id {
                            // AVPlayer가 숨겨지고 현재 탭이 PIP 탭이면 PIP 중지
                            pipManager.stopPIP()
                        }
                    }
                }
            ),
            onScroll: { y in
                handleWebViewScroll(yOffset: y)
            }
        )
        .id(state.tabID)
        // 🛡️ 다이나믹 아일랜드 안전영역 보호: 상단 안전영역은 항상 유지하되 좌우는 정상 적용
        .ignoresSafeArea(.container, edges: [.bottom])
    }
    
    private var dashboardView: some View {
        DashboardView(
            onNavigateToURL: { selectedURL in
                handleDashboardNavigation(selectedURL)
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onContentTap)
    }
    
    private var scrollOffsetOverlay: some View {
        GeometryReader { geometry in
            Color.clear
                .preference(
                    key: ScrollOffsetPreferenceKey.self,
                    value: geometry.frame(in: .global).origin.y
                )
        }
    }
    
    // 🎯 하단 UI: 주소창 + 동적 X 버튼 + 툴바
    @ViewBuilder
    private func bottomUIContent() -> some View {
        VStack(spacing: 10) {
            if showAddressBar {
                VStack(spacing: 0) {
                    // 📋 방문기록 영역 (전체 화면 너비) - 이전 코드 구조 그대로
                    if isTextFieldFocused || inputURL.isEmpty {
                        addressBarHistoryContent
                    }
                    
                    // 🎯 주소창 + X 버튼 (HStack으로 나란히 배치) - 이전 코드 구조
                    HStack(spacing: 12) {
                        // 주소창
                        VStack(spacing: 0) {
                            addressBarMainContent
                            
                            // 진행률 표시줄
                            if currentState.isLoading {
                                progressBarView
                            }
                        }
                        .background(whiteGlassBackground)
                        .overlay(whiteGlassOverlay)
                        
                        // ❌ X 플로팅 버튼 (키보드 열릴 때만 표시) - 이전 코드 구조
                        if isTextFieldFocused {
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isTextFieldFocused = false
                                    siteMenuManager.closeSiteMenu()
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                        showAddressBar = false
                                    }
                                }
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                                    .frame(width: 44, height: 44)
                                    .background(whiteGlassBackground)
                                    .overlay(whiteGlassOverlay)
                                    .clipShape(Circle())
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
            }
            
            toolbarView
        }
        .background(Color.clear)
    }
    
    // 📋 방문기록 컨텐츠 (동적 크기 + 전체 너비) - 이전 코드 구조 그대로 이식
    @ViewBuilder
    private var addressBarHistoryContent: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, outerHorizontalPadding)
                
            // 스크롤 영역
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if inputURL.isEmpty {
                        // 🕒 최근방문 뷰 (SiteMenuManager로 변경)
                        RecentVisitsView(
                            manager: siteMenuManager,
                            onURLSelected: { url in
                                inputURL = url.absoluteString
                                currentState.currentURL = url
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isTextFieldFocused = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                        showAddressBar = false
                                    }
                                }
                            },
                            onManageHistory: {
                                siteMenuManager.showHistoryFilterManager = true
                            }
                        )
                        .padding(.horizontal, outerHorizontalPadding)
                        .padding(.vertical, 8)
                    } else {
                        // 🔍 자동완성 뷰 (SiteMenuManager로 변경)
                        AutocompleteView(
                            manager: siteMenuManager,
                            searchText: inputURL,
                            onURLSelected: { url in
                                inputURL = url.absoluteString
                                currentState.currentURL = url
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    isTextFieldFocused = false
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                        showAddressBar = false
                                    }
                                }
                            },
                            onManageHistory: {
                                siteMenuManager.showHistoryFilterManager = true
                            }
                        )
                        .padding(.horizontal, outerHorizontalPadding)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 300) // 다이나믹 아일랜드 넘지 않게 최대 높이만 제한
            .fixedSize(horizontal: false, vertical: true) // 내용에 맞게 동적 크기 조정
            
            // 방문기록 관리 버튼 (하단 고정) - 이전 코드 구조
            VStack(spacing: 8) {
                Divider()
                    .padding(.horizontal, outerHorizontalPadding)
                    
                HStack {
                    Button(action: {
                        siteMenuManager.showHistoryFilterManager = true
                    }) {
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
                .padding(.horizontal, outerHorizontalPadding)
                .padding(.bottom, 8)
            }
        }
        .background(whiteGlassBackground)
        .overlay(whiteGlassOverlay)
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height > 50 && value.velocity.height > 300 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isTextFieldFocused = false
                            siteMenuManager.closeSiteMenu()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                showAddressBar = false
                            }
                        }
                        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                        impactFeedback.impactOccurred()
                    }
                }
        )
    }
    
    private var addressBarMainContent: some View {
        HStack(spacing: 8) {
            // 🧩 **개선된 퍼즐 버튼** (크기 증가 + 터치 우선순위 강화)
            puzzleButton
            
            // 🔒 사이트 보안 상태 표시 아이콘 (순수 표시용)
            siteSecurityIcon
            
            urlTextField
            refreshButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, barVPadding)
    }
    
    // 🧩 **개선된 퍼즐 버튼** (크기 증가 + 터치 우선순위 강화)
    private var puzzleButton: some View {
        Button(action: {
            // 🎯 **터치 우선순위 강화**: 메뉴 토글 시 다른 제스처 무시
            siteMenuManager.setCurrentStateModel(currentState)
            siteMenuManager.toggleSiteMenu()
            
            // 햅틱 피드백 추가
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            TabPersistenceManager.debugMessages.append("🧩 퍼즐 버튼으로 사이트 메뉴 토글: \(siteMenuManager.showSiteMenu)")
            
            // 퍼즐 버튼 터치 시 주소창 숨기기 방지 플래그 설정
            if siteMenuManager.showSiteMenu {
                ignoreAutoHideUntil = Date().addingTimeInterval(0.5) // 0.5초 동안 자동 숨기기 방지
            }
        }) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 20, weight: .medium)) // 폰트 크기 증가
                .foregroundColor(.white)
                .frame(width: 36, height: 36) // 터치 영역 크게 증가 (20x20 → 36x36)
                .background(
                    Circle()
                        .fill(isPuzzleButtonPressed ? Color.white.opacity(0.3) : Color.clear)
                        .animation(.easeInOut(duration: 0.1), value: isPuzzleButtonPressed)
                )
                .scaleEffect(isPuzzleButtonPressed ? 0.95 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isPuzzleButtonPressed)
        }
        .buttonStyle(.plain) // 기본 버튼 스타일 제거
        .contentShape(Circle()) // 원형 터치 영역 명시
        .simultaneousGesture(
            // 🎯 **터치 상태 관리로 시각적 피드백 강화**
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPuzzleButtonPressed {
                        isPuzzleButtonPressed = true
                        puzzleButtonPressStartTime = Date() // 터치 시작 시간 기록
                    }
                }
                .onEnded { _ in
                    isPuzzleButtonPressed = false
                    puzzleButtonPressStartTime = nil // 터치 종료 시 초기화
                }
        )
        .zIndex(999) // 🎯 **최상위 우선순위로 다른 제스처보다 우선 처리**
    }
    
    // 🔒 사이트 보안 상태 표시 아이콘 (순수 표시용)
    private var siteSecurityIcon: some View {
        HStack(spacing: 4) {
            if currentState.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 20, height: 20)
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
        if url.scheme == "https" {
            return "lock.fill"
        } else if url.scheme == "http" {
            return "exclamationmark.triangle.fill"
        } else {
            return "globe"
        }
    }
    
    private func getSiteIconColor() -> Color {
        guard let url = currentState.currentURL else { return .secondary }
        if url.scheme == "https" {
            return .green
        } else if url.scheme == "http" {
            return .orange
        } else {
            return .secondary
        }
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
            if currentState.isLoading {
                currentState.stopLoading()
                TabPersistenceManager.debugMessages.append("로딩 중지")
            } else {
                currentState.reload()
                TabPersistenceManager.debugMessages.append("페이지 새로고침")
            }
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
    
    // MARK: - 툴바 (이전 코드의 간단한 방식 사용)
    private var toolbarView: some View {
        HStack(spacing: 0) {
            HStack(spacing: toolbarSpacing) {
                // 🎯 **하단 버튼들은 기존 크기 유지** (터치 영향 없음)
                toolbarButton("chevron.left", action: {
                    currentState.goBack()
                    TabPersistenceManager.debugMessages.append("🎯 뒤로가기 버튼 터치")
                }, enabled: currentState.canGoBack)
                
                toolbarButton("chevron.right", action: {
                    currentState.goForward()
                    TabPersistenceManager.debugMessages.append("🎯 앞으로가기 버튼 터치")
                }, enabled: currentState.canGoForward)
                
                toolbarButton("clock.arrow.circlepath", action: { showHistorySheet = true }, enabled: true)
                toolbarButton("square.on.square", action: { showTabManager = true }, enabled: true)
                
                // 🎬 **PIP 버튼 추가 (조건부 표시)**
                if pipManager.isPIPActive {
                    toolbarButton("pip.fill", action: { pipManager.stopPIP() }, enabled: true, color: .green)
                }
                
                toolbarButton("ladybug", action: { showDebugView = true }, enabled: true, color: .orange)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, barVPadding)
        .background(whiteGlassBackground)
        .overlay(whiteGlassOverlay)
        .padding(.horizontal, outerHorizontalPadding)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToolbarTap)
    }
    
    // 🎯 이전 코드의 단순하고 효과적인 툴바 버튼 방식 사용 (기존 크기 유지)
    private func toolbarButton(_ systemName: String, action: @escaping () -> Void, enabled: Bool, color: Color = .primary) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize))
                .foregroundColor(enabled ? color : .secondary)
        }
        .disabled(!enabled) // 이전 코드의 단순한 방식
    }
    
    // ✨ 투명한 흰색 유리 배경
    private var whiteGlassBackground: some View {
        ZStack {
            WhiteGlassBlur(
                blurStyle: whiteGlassMaterial,
                cornerRadius: barCornerRadius,
                intensity: whiteGlassIntensity
            )
            
            // 매우 미세한 흰색 틴트
            RoundedRectangle(cornerRadius: barCornerRadius)
                .fill(Color.white.opacity(whiteGlassTintOpacity))
        }
    }
    
    // ✨ 투명한 흰색 유리 테두리
    private var whiteGlassOverlay: some View {
        Group {
            // 외부 하이라이트 (매우 미세)
            RoundedRectangle(cornerRadius: barCornerRadius)
                .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
            
            // 내부 그림자 효과 (극미세)
            RoundedRectangle(cornerRadius: barCornerRadius)
                .strokeBorder(.white.opacity(0.03), lineWidth: 0.5)
        }
    }
    
    // MARK: - 이벤트 핸들러들
    
    private func onAppearHandler() {
        if let url = currentState.currentURL {
            inputURL = url.absoluteString
            TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
        }
        TabPersistenceManager.debugMessages.append("페이지 기록 시스템 준비")
        
        // 🎬 **PIP 상태 초기 동기화**
        TabPersistenceManager.debugMessages.append("🎬 ContentView 초기화 - PIP 상태: \(pipManager.isPIPActive ? "활성" : "비활성")")
        
        // 🧩 **SiteMenuManager 초기화**
        siteMenuManager.setCurrentStateModel(currentState)
        siteMenuManager.refreshDownloads()
    }
    
    private func onURLChange(url: URL?) {
        if let url = url { inputURL = url.absoluteString }
    }
    
    private func onNavigationFinish(_: Void) {
        if let currentRecord = currentState.currentPageRecord {
            let back = currentState.canGoBack ? "가능" : "불가"
            let fwd = currentState.canGoForward ? "가능" : "불가"
            let title = currentRecord.title
            let pageId = currentRecord.id.uuidString.prefix(8)
            TabPersistenceManager.debugMessages.append("HIST ⏪\(back) ▶︎\(fwd) | '\(title)' [ID: \(pageId)]")
        } else {
            TabPersistenceManager.debugMessages.append("HIST 페이지 기록 없음")
        }
        TabPersistenceManager.saveTabs(tabs)
        TabPersistenceManager.debugMessages.append("탭 스냅샷 저장(네비게이션 완료)")
        
        // ✅ 페이지 로드 완료 후 주소창 3초간 자동 표시
        if !showAddressBar {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                showAddressBar = true
            }
            // 3초 후 자동으로 숨기기
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if showAddressBar && !isTextFieldFocused { // 사용자가 사용 중이 아닐 때만
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                        showAddressBar = false
                    }
                }
            }
        }
    }
    
    private var errorNotificationPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: .webViewDidFailLoad)
    }
    
    private func onErrorReceived(notification: Notification) {
        guard let userInfo = notification.userInfo, let tabIDString = userInfo["tabID"] as? String, tabIDString == currentState.tabID?.uuidString else { return }
        
        if let statusCode = userInfo["statusCode"] as? Int, let url = userInfo["url"] as? String {
            let error = getErrorMessage(for: statusCode, url: url)
            errorTitle = error.title
            errorMessage = error.message
            showErrorAlert = true
            TabPersistenceManager.debugMessages.append("❌ HTTP 오류 \(statusCode): \(error.title)")
        } else if let sslError = userInfo["sslError"] as? Bool, sslError, let url = userInfo["url"] as? String {
            let domain = URL(string: url)?.host ?? "사이트"
            errorTitle = "보안 연결 취소됨"
            errorMessage = "\(domain)의 보안 인증서를 신뢰할 수 없어 연결이 취소되었습니다.\n\n다른 안전한 사이트를 이용하시거나, 해당 사이트가 신뢰할 수 있는 사이트라면 다시 방문을 시도해보세요."
            showErrorAlert = true
            TabPersistenceManager.debugMessages.append("❌ SSL/TLS 오류")
        } else if let nsError = userInfo["nsError"] as? NSError, let error = getErrorMessage(from: nsError) {
            errorTitle = error.title
            errorMessage = error.message
            showErrorAlert = true
            TabPersistenceManager.debugMessages.append("❌ NS 에러 \(nsError.code): \(error.title)")
        }
    }
    
    @ViewBuilder
    private func alertActions() -> some View {
        Button("확인") { }
        if !errorTitle.contains("보안 연결") {
            Button("다시 시도") {
                currentState.reload()
            }
        }
    }
    
    private func alertMessage() -> some View {
        Text(errorMessage)
    }
    
    @ViewBuilder
    private func historySheet() -> some View {
        NavigationView {
            WebViewDataModel.HistoryPage(
                dataModel: currentState.dataModel,
                onNavigateToPage: { record in
                    if let index = currentState.dataModel.findPageIndex(for: record.url) {
                        if let navigatedRecord = currentState.dataModel.navigateToIndex(index) {
                            currentState.currentURL = navigatedRecord.url
                            if let webView = currentState.webView {
                                webView.load(URLRequest(url: navigatedRecord.url))
                            }
                        }
                    }
                },
                onNavigateToURL: { url in
                    currentState.currentURL = url
                }
            )
        }
    }
    
    @ViewBuilder
    private func tabManagerView() -> some View {
        NavigationView {
            TabManager(
                tabs: $tabs,
                initialStateModel: currentState,
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
    
    private var avPlayerBinding: Binding<Bool> {
        Binding(
            get: { tabs.indices.contains(selectedTabIndex) ? tabs[selectedTabIndex].showAVPlayer : false },
            set: { newValue in
                if tabs.indices.contains(selectedTabIndex) {
                    tabs[selectedTabIndex].showAVPlayer = newValue
                    // 🎬 **핵심**: AVPlayer 숨김 시 PIP도 중지
                    if !newValue && pipManager.currentPIPTab == tabs[selectedTabIndex].id {
                        pipManager.stopPIP()
                    }
                }
            }
        )
    }
    
    @ViewBuilder
    private func avPlayerView() -> some View {
        if tabs.indices.contains(selectedTabIndex), let url = tabs[selectedTabIndex].playerURL {
            AVPlayerView(url: url)
        }
    }
    
    @ViewBuilder
    private func debugView() -> some View {
        DebugLogView()
    }
    
    private func onScrollOffsetChange(offset: CGFloat) {
        // 🎯 **퍼즐 버튼 터치 중에는 주소창 숨기기 방지**
        if isTextFieldFocused || Date() < ignoreAutoHideUntil || isPuzzleButtonPressed || siteMenuManager.showSiteMenu {
            previousOffset = offset
            return
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
        // 🎯 **퍼즐 버튼 터치 중에는 다른 동작 방지**
        if isPuzzleButtonPressed { return }
        
        // 퍼즐 버튼 터치 후 바로 콘텐츠를 탭한 경우 (드래그 제스처 방지)
        if let pressStartTime = puzzleButtonPressStartTime, Date().timeIntervalSince(pressStartTime) < 0.2 {
            return
        }
        
        if showAddressBar {
            // 주소창이 열려있으면 닫기
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showAddressBar = false
                isTextFieldFocused = false
            }
        } else {
            showAddressBar = true
        }
        
        // 🧩 **추가**: 콘텐츠 탭 시 사이트 메뉴 닫기
        if siteMenuManager.showSiteMenu {
            siteMenuManager.closeSiteMenu()
        }
    }
    
    private func onTextFieldTap() {
        if !isTextFieldFocused {
            isTextFieldFocused = true
            ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
        }
        
        if !textFieldSelectedAll {
            DispatchQueue.main.async {
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                textFieldSelectedAll = true
                TabPersistenceManager.debugMessages.append("주소창 텍스트 전체 선택")
            }
        }
    }
    
    private func onTextFieldFocusChange(focused: Bool) {
        if focused {
            ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
        } else {
            textFieldSelectedAll = false
            TabPersistenceManager.debugMessages.append("주소창 포커스 해제")
        }
    }
    
    private func onTextFieldSubmit() {
        if let url = fixedURL(from: inputURL) {
            currentState.currentURL = url
            TabPersistenceManager.debugMessages.append("주소창에서 URL 이동: \(url)")
        }
        isTextFieldFocused = false
    }
    
    private func onToolbarTap() {
        if !showAddressBar {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                showAddressBar = true
            }
        }
    }
    
    private func handleDashboardNavigation(_ selectedURL: URL) {
        if tabs.indices.contains(selectedTabIndex) {
            // 기존 탭에 URL 설정
            tabs[selectedTabIndex].stateModel.currentURL = selectedURL
            tabs[selectedTabIndex].stateModel.loadURLIfReady()
            TabPersistenceManager.debugMessages.append("🌐 대시보드 네비게이션: \(selectedURL.absoluteString)")
        } else {
            // 새 탭 생성
            let newTab = WebTab(url: selectedURL)
            tabs.append(newTab)
            selectedTabIndex = tabs.count - 1
            newTab.stateModel.loadURLIfReady()
            TabPersistenceManager.saveTabs(tabs)
            TabPersistenceManager.debugMessages.append("🌐 새 탭 네비게이션: \(selectedURL.absoluteString)")
        }
    }
    
    // MARK: - WKWebView 스크롤 콜백 처리 (기존)
    private func handleWebViewScroll(yOffset: CGFloat) {
        // 🎯 **퍼즐 버튼 터치 중에는 주소창 숨기기 방지**
        if isTextFieldFocused || Date() < ignoreAutoHideUntil || isPuzzleButtonPressed || siteMenuManager.showSiteMenu {
            lastWebContentOffsetY = yOffset
            return
        }
        
        let delta = yOffset - lastWebContentOffsetY
        
        if abs(delta) < 2 {
            lastWebContentOffsetY = yOffset
            return
        }
        
        if delta > 4 && (showAddressBar || siteMenuManager.showSiteMenu) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showAddressBar = false
                siteMenuManager.closeSiteMenu()
                isTextFieldFocused = false
            }
        } else if delta < -12 && !showAddressBar {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                showAddressBar = true
            }
        }
        lastWebContentOffsetY = yOffset
    }
    
    // MARK: - 로컬/사설 IP 주소 감지
    private func isLocalOrPrivateIP(_ host: String) -> Bool {
        // IPv4 패턴 체크
        let ipPattern = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
        guard host.range(of: ipPattern, options: .regularExpression) != nil else {
            return false
        }
        
        let components = host.split(separator: ".").compactMap { Int($0) }
        guard components.count == 4 else { return false }
        
        let a = components[0]
        let b = components[1]
        
        // 사설 IP 대역 체크
        return (a == 192 && b == 168) || // 192.168.x.x
               (a == 10) || // 10.x.x.x
               (a == 172 && (16...31).contains(b)) || // 172.16.x.x ~ 172.31.x.x
               (a == 127) || // 127.x.x.x (localhost)
               (a == 169 && b == 254) // 169.254.x.x (링크 로컬)
    }
    
    // MARK: - 입력 문자열을 URL로 정규화 + 스마트 HTTP/HTTPS 처리
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 이미 완전한 URL인 경우
        if let url = URL(string: trimmed), url.scheme != nil {
            // 로컬/사설 IP가 아닌 경우에만 HTTP → HTTPS 자동 전환
            if url.scheme == "http", let host = url.host, !isLocalOrPrivateIP(host) {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if let httpsURL = components?.url {
                    TabPersistenceManager.debugMessages.append("🔒 HTTP → HTTPS 자동 전환: \(httpsURL.absoluteString)")
                    return httpsURL
                }
            }
            return url
        }
        
        // 도메인처럼 보이는 경우 (점이 있고 공백이 없음)
        if trimmed.contains(".") && !trimmed.contains(" ") {
            // 로컬/사설 IP인지 확인
            if isLocalOrPrivateIP(trimmed) {
                // 로컬 주소는 HTTP 사용
                let httpURL = URL(string: "http://\(trimmed)")
                TabPersistenceManager.debugMessages.append("🏠 로컬 IP 감지, HTTP 적용: http://\(trimmed)")
                return httpURL
            } else {
                // 공인 도메인은 HTTPS 사용 (현대 웹 표준)
                let httpsURL = URL(string: "https://\(trimmed)")
                TabPersistenceManager.debugMessages.append("🔗 도메인 감지, HTTPS 적용: https://\(trimmed)")
                return httpsURL
            }
        }
        
        // 검색어로 처리
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
    
    // MARK: - ✨ HTTP 에러 코드를 사용자 친화적인 한글 메시지로 변환 (간단하게)
    private func getErrorMessage(for statusCode: Int, url: String) -> (title: String, message: String) {
        let domain = URL(string: url)?.host ?? "사이트"
        switch statusCode {
        case 403:
            return ("\(statusCode)에러", "\(domain)에 접근할 권한이 없습니다.")
        case 404:
            return ("\(statusCode)에러", "페이지를 찾을 수 없습니다.")
        case 500:
            return ("\(statusCode)에러", "\(domain) 서버에 문제가 발생했습니다.")
        case 502:
            return ("\(statusCode)에러", "\(domain) 서버가 불안정합니다.")
        case 503:
            return ("\(statusCode)에러", "\(domain)이 점검 중이거나 과부하 상태입니다.")
        case 504:
            return ("\(statusCode)에러", "서버 응답 시간 초과. 잠시 후 다시 시도해주세요.")
        default:
            return ("\(statusCode) 에러", "페이지를 불러오는 중 알 수 없는 오류가 발생했습니다.")
        }
    }
    
    // MARK: - NSError를 사용자 친화적인 한글 메시지로 변환
    private func getErrorMessage(from nsError: NSError) -> (title: String, message: String)? {
        guard nsError.domain == NSURLErrorDomain else { return nil }
        
        // ✅ 정의된 특정 에러만 처리, 나머지는 nil 반환
        switch nsError.code {
        case NSURLErrorCannotFindHost:
            return ("주소를 찾을 수 없음 (\(nsError.code))", "\(nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? "주소")을(를) 찾을 수 없습니다.")
        case NSURLErrorTimedOut:
            return ("연결 시간 초과 (\(nsError.code))", "서버 응답이 늦습니다.")
        case NSURLErrorNotConnectedToInternet:
            return ("인터넷 연결 없음 (\(nsError.code))", "인터넷에 연결되어 있지 않습니다.")
        case NSURLErrorCannotConnectToHost:
            return ("서버 연결 실패 (\(nsError.code))", "서버에 연결할 수 없습니다.")
        case NSURLErrorNetworkConnectionLost:
            return ("네트워크 연결 끊김 (\(nsError.code))", "네트워크 연결이 끊어졌습니다.")
        case NSURLErrorDNSLookupFailed:
            return ("DNS 조회 실패 (\(nsError.code))", "DNS 조회에 실패했습니다. 올바른 주소인지 확인해주세요.")
        case NSURLErrorBadURL:
            return ("잘못된 주소 (\(nsError.code))", "입력한 주소 형식이 올바르지 않습니다.")
        case NSURLErrorUnsupportedURL:
            return ("지원하지 않는 주소 (\(nsError.code))", "이 주소 형식은 지원하지 않습니다.")
        default:
            // ✅ default 케이스에서 nil 반환 - 알림 표시 안함, 기록도 안함
            return nil
        }
    }
}

// MARK: - 📋 최근방문 뷰 컴포넌트 (SiteMenuManager 사용)
struct RecentVisitsView: View {
    @ObservedObject var manager: SiteMenuManager
    let onURLSelected: (URL) -> Void
    let onManageHistory: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            if manager.recentVisits.isEmpty {
                emptyStateView
            } else {
                historyListView
            }
        }
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("최근 방문한 사이트가 없습니다")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
    }
    
    @ViewBuilder
    private var historyListView: some View {
        VStack(spacing: 0) {
            ForEach(manager.recentVisits) { entry in
                historyRow(entry)
                if entry.id != manager.recentVisits.last?.id {
                    Divider()
                        .padding(.horizontal, 14)
                }
            }
        }
    }
    
    @ViewBuilder
    private func historyRow(_ entry: HistoryEntry) -> some View {
        Button(action: {
            onURLSelected(entry.url)
        }) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .foregroundColor(.gray)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    Text(entry.url.absoluteString)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 🔍 자동완성 뷰 컴포넌트 (SiteMenuManager 사용)
struct AutocompleteView: View {
    @ObservedObject var manager: SiteMenuManager
    let searchText: String
    let onURLSelected: (URL) -> Void
    let onManageHistory: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            if manager.getAutocompleteEntries(for: searchText).isEmpty {
                emptyStateView
            } else {
                autocompleteListView
            }
        }
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("검색 기록이 없습니다")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
    }
    
    @ViewBuilder
    private var autocompleteListView: some View {
        VStack(spacing: 0) {
            ForEach(manager.getAutocompleteEntries(for: searchText)) { entry in
                autocompleteRow(entry)
                if entry.id != manager.getAutocompleteEntries(for: searchText).last?.id {
                    Divider()
                        .padding(.horizontal, 14)
                }
            }
        }
    }
    
    @ViewBuilder
    private func autocompleteRow(_ entry: HistoryEntry) -> some View {
        Button(action: {
            onURLSelected(entry.url)
        }) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    highlightedText(entry.title, searchText: searchText)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    highlightedText(entry.url.absoluteString, searchText: searchText)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func highlightedText(_ text: String, searchText: String) -> some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            Text(text)
                .foregroundColor(.primary)
        } else {
            let parts = text.components(separatedBy: trimmed)

            if parts.count > 1 {
                HStack(spacing: 0) {
                    ForEach(0..<parts.count, id: \.self) { index in
                        Text(parts[index])
                            .foregroundColor(.primary)

                        if index < parts.count - 1 {
                            Text(trimmed)
                                .foregroundColor(.blue)
                                .fontWeight(.semibold)
                        }
                    }
                }
            } else {
                Text(text)
                    .foregroundColor(.primary)
            }
        }
    }
}

// MARK: - 스크롤 오프셋 추적을 위한 PreferenceKey (기존)
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// ✨ WebView 에러 처리를 위한 NotificationCenter 확장
extension Notification.Name {
    static let webViewDidFailLoad = Notification.Name("webViewDidFailLoad")
}
