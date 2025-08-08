import SwiftUI
import AVKit
import WebKit

/// 웹 브라우저의 메인 콘텐츠 뷰
struct ContentView: View {
    @Binding var tabs: [WebTab]
    @Binding var selectedTabIndex: Int
    
    @State private var inputURL: String = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var textFieldSelectedAll = false
    @State private var showHistorySheet = false
    @State private var showTabManager = false
    @State private var enablePIP: Bool = true
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
                    .id(state.tabID)
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
            .onAppear {
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
                }
                TabPersistenceManager.debugMessages.append("히스토리 복원은 WebView 생성 시 처리 (pendingSession 유지)")
            }
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }
            .onReceive(state.navigationDidFinish) { _ in
                if let wv = state.webView, let current = wv.url?.absoluteString {
                    inputURL = current
                    TabPersistenceManager.debugMessages.append("주소창 업데이트: \(current)")
                }
                // virtualHistoryStack 기반 히스토리 로그
                let back = state.virtualCurrentIndex
                let fwd = state.virtualHistoryStack.count - state.virtualCurrentIndex - 1
                let cur = state.currentURL?.absoluteString ?? "없음"
                let urlList = state.virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
                TabPersistenceManager.debugMessages.append("HIST ⏪\(back) ▶︎\(fwd) | \(cur) | entries=[\(urlList)]")
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
                            let tabState = tabs[index].stateModel
                            let back = tabState.virtualCurrentIndex
                            let fwd = tabState.virtualHistoryStack.count - tabState.virtualCurrentIndex - 1
                            let cur = tabState.currentURL?.absoluteString ?? "없음"
                            let urlList = tabState.virtualHistoryStack.map { $0.debugDescription }.joined(separator: ", ")
                            TabPersistenceManager.debugMessages.append("HIST(tab \(index)) ⏪\(back) ▶︎\(fwd) | \(cur) | entries=[\(urlList)]")
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
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if showAddressBar {
                        HStack {
                            TextField("URL 또는 검색어", text: $inputURL)
                                .textFieldStyle(.roundedBorder)
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
                                        state.currentURL = url
                                        state.loadURLIfReady()
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
                                                    .font(.system(size: 14))
                                                    .foregroundColor(.gray)
                                            }
                                            .padding(.trailing, 8)
                                        }
                                    }
                                )
                                .frame(maxWidth: 300)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(red: 248/255, green: 249/255, blue: 250/255))
                        .cornerRadius(10)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(red: 248/255, green: 249/255, blue: 250/255))
                    .cornerRadius(10)
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
                .background(Color.clear)
            }
        } else {
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

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}