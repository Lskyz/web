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
    @State private var allowTopOverlap: Bool = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var errorTitle = ""

    // ✨ 추가: 키보드 높이와 하단 UI 높이 관리
    @State private var keyboardHeight: CGFloat = 0
    @State private var bottomUIHeight: CGFloat = 0

    // 기존 속성들
    private let outerHorizontalPadding: CGFloat = 24
    private let barCornerRadius: CGFloat = 22
    private let barVPadding: CGFloat = 12
    private let iconSize: CGFloat = 23
    private let textFont: Font = .system(size: 18, weight: .semibold)
    private let toolbarSpacing: CGFloat = 22
    private let glassMaterial: UIBlurEffect.Style = .systemUltraThinMaterial
    private let glassTintOpacity: CGFloat = 0.25

    var body: some View {
        ZStack {
            mainContentView
                .onAppear(perform: onAppearHandler)
                .onReceive(currentState.$currentURL, perform: onURLChange)
                .onReceive(currentState.navigationDidFinish, perform: onNavigationFinish)
                .onReceive(errorNotificationPublisher, perform: onErrorReceived)
                .alert(errorTitle, isPresented: $showErrorAlert, actions: alertActions, message: alertMessage)
                .sheet(isPresented: $showHistorySheet, content: historySheet)
                .fullScreenCover(isPresented: $showTabManager, content: tabManagerView)
                .fullScreenCover(isPresented: avPlayerBinding, content: avPlayerView)
                .fullScreenCover(isPresented: $showDebugView, content: debugView)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomUIContent()
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { bottomUIHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { newHeight in
                                bottomUIHeight = newHeight
                            }
                    }
                )
                // 키보드 높이를 반영해 하단 UI가 밀리지 않도록 조정
                .offset(y: -keyboardHeight)
                .animation(.easeInOut(duration: 0.3), value: keyboardHeight)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
               let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
                withAnimation(.easeInOut(duration: duration)) {
                    keyboardHeight = keyboardFrame.height
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            if let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
                withAnimation(.easeInOut(duration: duration)) {
                    keyboardHeight = 0
                }
            }
        }
    }

    // MARK: - 컴포넌트 분해
    private var currentState: WebViewStateModel {
        if tabs.indices.contains(selectedTabIndex) {
            return tabs[selectedTabIndex].stateModel
        } else {
            return WebViewStateModel()
        }
    }

    @ViewBuilder
    private var mainContentView: some View {
        if tabs.indices.contains(selectedTabIndex) {
            let state = tabs[selectedTabIndex].stateModel
            
            ZStack {
                if state.currentURL != nil {
                    webContentView(state: state)
                } else {
                    dashboardView
                }
            }
        } else {
            dashboardView
        }
    }

    @ViewBuilder
    private func webContentView(state: WebViewStateModel) -> some View {
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
        .id(state.tabID)
        .ignoresSafeArea(.container, edges: allowTopOverlap ? [.top, .bottom] : [.bottom])
        // 하단 UI 높이만큼 패딩 추가
        .padding(.bottom, bottomUIHeight)
        .overlay(scrollOffsetOverlay)
        .onPreferenceChange(ScrollOffsetPreferenceKey.self, perform: onScrollOffsetChange)
        .contentShape(Rectangle())
        .onTapGesture(perform: onContentTap)
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

    @ViewBuilder
    private func bottomUIContent() -> some View {
        VStack(spacing: 10) {
            if showAddressBar {
                addressBarView
            }
            
            toolbarView
        }
        .background(Color.clear)
    }

    private var addressBarView: some View {
        VStack(spacing: 0) {
            addressBarMainContent
            
            if currentState.isLoading {
                progressBarView
            }
            
            if currentState.isDesktopMode {
                desktopModeControls
            }
        }
        .background(glassBackground)
        .overlay(glassOverlay)
        .padding(.horizontal, outerHorizontalPadding)