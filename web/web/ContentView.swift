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

// ✨ 에러 처리 및 로딩 상태
@State private var showErrorAlert = false
@State private var errorMessage = ""
@State private var errorTitle = ""

// ============================================================
// ✨ 변경: 가장 투명한 블러 + 흰색 틴트 (은은한 그라데이션 효과)
// ============================================================
private let outerHorizontalPadding: CGFloat = 24     // 주소창/툴바 외부 좌우 여백(=폭 제어)
private let barCornerRadius: CGFloat       = 22
private let barVPadding: CGFloat           = 12
private let iconSize: CGFloat              = 23
private let textFont: Font                 = .system(size: 18, weight: .semibold)
private let toolbarSpacing: CGFloat        = 22

// ✨ 핵심 수정: 가장 투명한 블러 + 흰색 틴트로 은은한 효과
private let glassMaterial: UIBlurEffect.Style = .systemUltraThinMaterial  // 가장 투명한 블러
private let glassTintOpacity: CGFloat = 0.25  // 흰색 틴트 25%

var body: some View {
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
        // ✅ 변경: safeAreaInset → overlay로 변경하여 키보드 여백 문제 해결
        .overlay(alignment: .bottom) {
            bottomUIContent()
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
    // ✅ 추가: 하단 UI 높이만큼 패딩 추가하여 콘텐츠가 UI에 가려지지 않도록 함
    .padding(.bottom, 100)
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
    .transition(.opacity)
}

private var addressBarMainContent: some View {
    HStack {
        desktopModeButton
        loadingOrSecurityIcon
        urlTextField
        refreshButton
    }
    .padding(.horizontal, 14)
    .padding(.vertical, barVPadding)
}

private var desktopModeButton: some View {
    Button(action: {
        currentState.toggleDesktopMode()
        TabPersistenceManager.debugMessages.append("🖥️ 강화된 데스크탑 모드: \(currentState.isDesktopMode ? "ON (Windows)" : "OFF")")
    }) {
        HStack(spacing: 4) {
            Image(systemName: currentState.isDesktopMode ? "display" : "iphone")
                .font(.system(size: 14))
                .foregroundColor(currentState.isDesktopMode ? .blue : .primary)
            
            if currentState.isDesktopMode {
                Text("PC")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.blue)
            }
        }
        .frame(width: 26, height: 20)
    }
    .scaleEffect(currentState.isDesktopMode ? 1.1 : 1.0)
    .animation(.easeInOut(duration: 0.2), value: currentState.isDesktopMode)
}

@ViewBuilder
private var loadingOrSecurityIcon: some View {
    if currentState.isLoading {
        ProgressView()
            .scaleEffect(0.8)
            .frame(width: 20, height: 20)
    } else {
        Image(systemName: currentState.currentURL?.scheme == "https" ? "lock.fill" : "globe")
            .font(.system(size: 16))
            .foregroundColor(currentState.currentURL?.scheme == "https" ? .green : .secondary)
            .frame(width: 20, height: 20)
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

private var desktopModeControls: some View {
    VStack(spacing: 8) {
        zoomSlider
        zoomPresetButtons
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
    .animation(.easeInOut(duration: 0.3), value: currentState.isDesktopMode)
}

private var zoomSlider: some View {
    HStack {
        Image(systemName: "minus.magnifyingglass")
            .font(.system(size: 12))
            .foregroundColor(.blue)
        
        Slider(
            value: Binding(
                get: { currentState.currentZoomLevel },
                set: { newValue in
                    currentState.setZoomLevel(newValue)
                    TabPersistenceManager.debugMessages.append("🔍 줌 변경: \(String(format: "%.1f", newValue))x")
                }
            ),
            in: 0.3...3.0,
            step: 0.1
        )
        .accentColor(.blue)
        
        Image(systemName: "plus.magnifyingglass")
            .font(.system(size: 12))
            .foregroundColor(.blue)
        
        Text("\(String(format: "%.1f", currentState.currentZoomLevel))x")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.blue)
            .frame(width: 35)
    }
    .padding(.horizontal, 14)
}

private var zoomPresetButtons: some View {
    HStack(spacing: 12) {
        ForEach([0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { preset in
            Button(action: {
                currentState.setZoomLevel(preset)
                TabPersistenceManager.debugMessages.append("🎯 줌 프리셋: \(String(format: "%.1f", preset))x")
            }) {
                Text("\(String(format: "%.1f", preset))x")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(abs(currentState.currentZoomLevel - preset) < 0.05 ? .white : .blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(abs(currentState.currentZoomLevel - preset) < 0.05 ? Color.blue : Color.blue.opacity(0.1))
                    )
            }
        }
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 4)
}

private var toolbarView: some View {
    HStack(spacing: 0) {
        HStack(spacing: toolbarSpacing) {
            toolbarButton("chevron.left", action: { currentState.goBack() }, enabled: currentState.canGoBack)
            toolbarButton("chevron.right", action: { currentState.goForward() }, enabled: currentState.canGoForward)
            toolbarButton("arrow.clockwise", action: { currentState.reload() }, enabled: true)
            toolbarButton("clock.arrow.circlepath", action: { showHistorySheet = true }, enabled: true)
            toolbarButton("square.on.square", action: { showTabManager = true }, enabled: true)
            toolbarButton("ladybug", action: { showDebugView = true }, enabled: true, color: .orange)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, barVPadding)
    .background(glassBackground)
    .overlay(glassOverlay)
    .padding(.horizontal, outerHorizontalPadding)
    .contentShape(Rectangle())
    .onTapGesture(perform: onToolbarTap)
}

private func toolbarButton(_ systemName: String, action: @escaping () -> Void, enabled: Bool, color: Color = .primary) -> some View {
    Button(action: action) {
        Image(systemName: systemName)
            .font(.system(size: iconSize))
            .foregroundColor(enabled ? color : .secondary)
    }
    .disabled(!enabled)
}

private var glassBackground: some View {
    ZStack {
        VisualEffectBlur(blurStyle: glassMaterial, cornerRadius: barCornerRadius)
        RoundedRectangle(cornerRadius: barCornerRadius)
            .fill(Color.white.opacity(glassTintOpacity))
    }
}

private var glassOverlay: some View {
    Group {
        RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
        RoundedRectangle(cornerRadius: barCornerRadius).strokeBorder(.black.opacity(0.08), lineWidth: 0.25)
    }
}

// MARK: - 이벤트 핸들러들

private func onAppearHandler() {
    if let url = currentState.currentURL {
        inputURL = url.absoluteString
        TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
    }
    TabPersistenceManager.debugMessages.append("페이지 기록 시스템 준비")
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
        withAnimation {
            showAddressBar = true
            allowTopOverlap = false
        }
        
        // 3초 후 자동으로 숨기기
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if showAddressBar && !isTextFieldFocused {  // 사용자가 사용 중이 아닐 때만
                withAnimation {
                    showAddressBar = false
                    allowTopOverlap = true
                }
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
    
    if let statusCode = userInfo["statusCode"] as? Int,
       let url = userInfo["url"] as? String {
        let error = getErrorMessage(for: statusCode, url: url)
        errorTitle = error.title
        errorMessage = error.message
        showErrorAlert = true
        TabPersistenceManager.debugMessages.append("❌ HTTP 오류 \(statusCode): \(error.title)")
    } else if let sslError = userInfo["sslError"] as? Bool, sslError,
              let url = userInfo["url"] as? String {
        let domain = URL(string: url)?.host ?? "사이트"
        errorTitle = "보안 연결 취소됨"
        errorMessage = "\(domain)의 보안 인증서를 신뢰할 수 없어 연결이 취소되었습니다.\n\n다른 안전한 사이트를 이용하시거나, 해당 사이트가 신뢰할 수 있는 사이트라면 다시 방문을 시도해보세요."
        showErrorAlert = true
        TabPersistenceManager.debugMessages.append("🔒 SSL 인증서 거부: \(domain)")
    } else if let error = userInfo["error"] as? Error,
              let url = userInfo["url"] as? String {
        if let networkError = getNetworkErrorMessage(for: error, url: url) {
            errorTitle = networkError.title
            errorMessage = networkError.message
            showErrorAlert = true
            TabPersistenceManager.debugMessages.append("❌ 네트워크 오류: \(networkError.title)")
        } else {
            TabPersistenceManager.debugMessages.append("🔕 정의되지 않은 에러 무시")
        }
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
        set: { if tabs.indices.contains(selectedTabIndex) { tabs[selectedTabIndex].showAVPlayer = $0 } }
    )
}

@ViewBuilder
private func avPlayerView() -> some View {
    if tabs.indices.contains(selectedTabIndex),
       let url = tabs[selectedTabIndex].playerURL {
        AVPlayerView(url: url)
    }
}

@ViewBuilder
private func debugView() -> some View {
    DebugLogView()
}

private func onScrollOffsetChange(offset: CGFloat) {
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

private func onContentTap() {
    withAnimation {
        if showAddressBar {
            showAddressBar = false
            isTextFieldFocused = false
            allowTopOverlap = true
        } else {
            showAddressBar = true
            allowTopOverlap = false
        }
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
        withAnimation {
            showAddressBar = true
            allowTopOverlap = false
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

// MARK: - 로컬/사설 IP 주소 감지
private func isLocalOrPrivateIP(_ host: String) -> Bool {
    // IPv4 패턴 체크
    let ipPattern = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
    guard host.range(of: ipPattern, options: .regularExpression) != nil else {
        // localhost 도메인들
        return host == "localhost" || host.hasSuffix(".local")
    }
    
    let components = host.split(separator: ".").compactMap { Int($0) }
    guard components.count == 4 else { return false }
    
    let (a, b, c, d) = (components[0], components[1], components[2], components[3])
    
    // 유효한 IP 범위 체크
    guard (0...255).contains(a) && (0...255).contains(b) && 
          (0...255).contains(c) && (0...255).contains(d) else { return false }
    
    // 사설 IP 대역 체크
    return (a == 192 && b == 168) ||                    // 192.168.x.x
           (a == 10) ||                                 // 10.x.x.x
           (a == 172 && (16...31).contains(b)) ||       // 172.16.x.x ~ 172.31.x.x
           (a == 127) ||                                // 127.x.x.x (localhost)
           (a == 169 && b == 254)                       // 169.254.x.x (링크 로컬)
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
        return ("\(statusCode)에러", "\(domain) 서버 응답이 늦습니다.")
    default:
        return ("\(statusCode)에러", "페이지 오류가 발생했습니다.")
    }
}

// MARK: - ✨ 네트워크 오류 메시지 처리 (default 케이스 제거)
private func getNetworkErrorMessage(for error: Error, url: String) -> (title: String, message: String)? {
    let domain = URL(string: url)?.host ?? "사이트"
    let nsError = error as NSError
    
    // NSURLError가 아닌 경우 nil 반환 (알림 표시 안함)
    guard nsError.domain == NSURLErrorDomain else {
        return nil
    }
    
    // ✅ 정의된 특정 에러만 처리, 나머지는 nil 반환
    switch nsError.code {
    case NSURLErrorCannotFindHost:
        return ("주소를 찾을 수 없음 (\(nsError.code))", "\(domain)을(를) 찾을 수 없습니다.")
    case NSURLErrorTimedOut:
        return ("연결 시간 초과 (\(nsError.code))", "\(domain) 서버 응답이 늦습니다.")
    case NSURLErrorNotConnectedToInternet:
        return ("인터넷 연결 없음 (\(nsError.code))", "인터넷에 연결되어 있지 않습니다.")
    case NSURLErrorCannotConnectToHost:
        return ("서버 연결 실패 (\(nsError.code))", "\(domain) 서버에 연결할 수 없습니다.")
    case NSURLErrorNetworkConnectionLost:
        return ("네트워크 연결 끊김 (\(nsError.code))", "네트워크 연결이 끊어졌습니다.")
    case NSURLErrorDNSLookupFailed:
        return ("DNS 조회 실패 (\(nsError.code))", "\(domain)의 DNS 조회에 실패했습니다.")
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

// MARK: - 스크롤 오프셋 추적을 위한 PreferenceKey (기존)
private struct ScrollOffsetPreferenceKey: PreferenceKey {
static var defaultValue: CGFloat = 0
static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// ✨ WebView 에러 처리를 위한 NotificationCenter 확장 (이미 다른 파일에서 정의됨)
// extension Notification.Name {
//     static let webViewDidFailLoad = Notification.Name(“webViewDidFailLoad”)
// }