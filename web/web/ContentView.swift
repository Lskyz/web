import SwiftUI
import AVKit
import WebKit
import UIKit

/// 웹 브라우저의 메인 콘텐츠 뷰
struct ContentView: View {
    // MARK: - 속성 정의
    /// 전체 탭 배열
    @Binding var tabs: [WebTab]
    /// 현재 선택된 탭 인덱스
    @Binding var selectedTabIndex: Int

    /// 주소창 입력 값
    @State private var inputURL: String = ""
    /// 주소창 포커스 상태
    @FocusState private var isTextFieldFocused: Bool
    /// 텍스트 전체 선택 여부(중복 실행 방지)
    @State private var textFieldSelectedAll = false
    /// 방문 기록 시트 표시 여부
    @State private var showHistorySheet = false
    /// 탭 관리자 표시 여부
    @State private var showTabManager = false
    /// PIP 기능 토글 상태 (숨김 처리)
    @State private var enablePIP: Bool = true
    /// 주소창 표시 여부 (터치 또는 스크롤에 따라 동작)
    @State private var showAddressBar = false

    /// GeometryReader 보조값(레이아웃 변화 감지용)
    @State private var previousOffset: CGFloat = 0

    /// 서드파티 키보드 대응: 포커스 직후 일정 시간 동안 자동숨김 무시
    @State private var ignoreAutoHideUntil: Date = .distantPast
    private let focusDebounceSeconds: TimeInterval = 0.5

    /// 실제 웹 콘텐츠 스크롤 추적값
    @State private var lastWebContentOffsetY: CGFloat = 0

    var body: some View {
        // 현재 선택된 탭이 유효한지 확인
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
                        // ✅ 실제 스크롤 오프셋 콜백
                        onScroll: { y in
                            handleWebViewScroll(yOffset: y)
                        }
                    )
                    .id(state.tabID) // 탭별 WKWebView 인스턴스 분리 보장

                    // (보조) 레이아웃 변화 감지. 실제 스크롤은 onScroll로 처리.
                    .overlay(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(key: ScrollOffsetPreferenceKey.self,
                                            value: geometry.frame(in: .global).origin.y)
                        }
                    )
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                        // 포커스 직후 딜레이 동안은 자동숨김 차단
                        if Date() < ignoreAutoHideUntil || isTextFieldFocused {
                            previousOffset = offset
                            return
                        }
                        // 임계치 크게(레이아웃 변화 오인 방지)
                        let delta = offset - previousOffset
                        if delta < -30 && showAddressBar {
                            withAnimation {
                                showAddressBar = false
                                isTextFieldFocused = false
                            }
                        }
                        previousOffset = offset
                    }

                    // 👉 콘텐츠 영역 탭 제스처: 보임/숨김 토글
                    .contentShape(Rectangle())
                    .onTapGesture { toggleAddressBarFromTap() }

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
                    .onTapGesture { toggleAddressBarFromTap() }
                }
            }
            // ⛔️ 키보드 세이프에어리어 무시하지 않음(키보드 위로 자동 올라오게)
            // .ignoresSafeArea(.keyboard) 사용하지 않음

            // MARK: - 페이지 진입/이동 이벤트
            .onAppear {
                // 초기 진입: 사파리처럼 주소창 보이기(키보드는 띄우지 않음)
                withAnimation { showAddressBar = true }
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                    TabPersistenceManager.debugMessages.append("탭 진입, 주소창 동기화: \(url)")
                }
                TabPersistenceManager.debugMessages.append("히스토리 복원은 WebView 생성 시 처리 (pendingSession 유지)")
            }

            // URL 변경(탭 내 이동 시작) 시점에도 주소창 보이기
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
                withAnimation { showAddressBar = true } // ✅ 이동 시작 시 보여줌
                // 처음엔 포커스는 주지 않음(사파리 동작)
                isTextFieldFocused = false
            }

            // 네비게이션 완료 시에도 주소창 보이기(사파리와 동일)
            .onReceive(state.navigationDidFinish) { _ in
                withAnimation { showAddressBar = true } // ✅ 완료 시 보여줌
                isTextFieldFocused = false
                // 스냅샷/로그
                if let wv = state.webView {
                    let back = wv.backForwardList.backList.count
                    let fwd = wv.backForwardList.forwardList.count
                    let cur = wv.url?.absoluteString ?? "없음"
                    TabPersistenceManager.debugMessages.append("HIST ⏪\(back) ▶︎\(fwd) | \(cur)")
                } else {
                    TabPersistenceManager.debugMessages.append("HIST 웹뷰 미연결")
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
                            if let wv = tabs[index].stateModel.webView {
                                let back = wv.backForwardList.backList.count
                                let fwd = wv.backForwardList.forwardList.count
                                let cur = wv.url?.absoluteString ?? "없음"
                                TabPersistenceManager.debugMessages.append("HIST(tab \(index)) ⏪\(back) ▶︎\(fwd) | \(cur)")
                            } else {
                                TabPersistenceManager.debugMessages.append("HIST(tab \(index)) 준비중")
                            }
                            // 탭 전환 시에도 주소창 보이기
                            withAnimation { showAddressBar = true }
                            isTextFieldFocused = false
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

            // MARK: - 하단 인셋 (투명 배경 + 바 표면만 색)
            .safeAreaInset(edge: .bottom) {
                ZStack {
                    // ✅ 툴바 "바깥" 투명 영역 탭 감지(인셋 전체). 바가 탭을 가로채는 영역은 자동 무시됨.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { toggleAddressBarFromTap() }

                    VStack(spacing: 8) {
                        // 주소창 — 툴바 바로 위
                        if showAddressBar {
                            HStack {
                                TextField("URL 또는 검색어", text: $inputURL)
                                    .textFieldStyle(.roundedBorder)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .keyboardType(.URL)
                                    .focused($isTextFieldFocused)
                                    .onChange(of: isTextFieldFocused) { focused in
                                        if focused {
                                            // 포커스 직후 자동숨김 무시 딜레이
                                            ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
                                            // ✅ 전체 선택 안정화: 딜레이 후 2회 시도
                                            if !textFieldSelectedAll {
                                                selectAllInFirstResponderTextField()
                                            }
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
                                                // ✅ 지우기 버튼: 더 크게 + 히트영역 확보
                                                Button(action: { inputURL = "" }) {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.system(size: 22)) // 아이콘 크게
                                                        .frame(width: 36, height: 36) // 히트영역 확장
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                                .padding(.trailing, 4)
                                            }
                                        }
                                    )
                                    .frame(maxWidth: 320)
                            }
                            // 크기 최소 패딩
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            // 바 표면 색(#F8F9FA)
                            .background(Color(red: 248/255, green: 249/255, blue: 250/255))
                            .cornerRadius(10)
                            .padding(.horizontal, 8)
                            .transition(.opacity)
                            // 바 자체 스와이프 제스처(선택): 아래로 숨김 / 위로 표시
                            .gesture(
                                DragGesture(minimumDistance: 10).onEnded { v in
                                    if v.translation.height > 20 {
                                        withAnimation {
                                            showAddressBar = false
                                            isTextFieldFocused = false
                                        }
                                    } else if v.translation.height < -20 {
                                        withAnimation { showAddressBar = true }
                                        DispatchQueue.main.async {
                                            isTextFieldFocused = true
                                            ignoreAutoHideUntil = Date().addingTimeInterval(focusDebounceSeconds)
                                        }
                                    }
                                }
                            )
                        }

                        // 하단 툴바 (항상 표시)
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

                            Button(action: {
                                state.reload()
                                // ✅ 새로고침 직후 주소창 보이기(사파리 스타일)
                                withAnimation { showAddressBar = true }
                                isTextFieldFocused = false
                            }) {
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
                        .background(Color(red: 248/255, green: 249/255, blue: 250/255)) // #F8F9FA
                        .cornerRadius(10)
                        .padding(.horizontal, 8)
                        .gesture(
                            DragGesture(minimumDistance: 10).onEnded { v in
                                if v.translation.height > 20 {
                                    withAnimation {
                                        showAddressBar = false
                                        isTextFieldFocused = false
                                    }
                                } else if v.translation.height < -20 {
                                    withAnimation { showAddressBar = true }
                                }
                            }
                        )
                    }
                }
                .background(Color.clear) // 인셋 배경은 완전 투명
            }

        } else {
            // 탭이 비어있을 때 대시보드로 시작
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

    // MARK: - 웹뷰 스크롤 처리
    private func handleWebViewScroll(yOffset: CGFloat) {
        // 포커스 중이거나 포커스 직후 딜레이 구간은 자동숨김 차단
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

    // MARK: - 탭 제스처 토글
    private func toggleAddressBarFromTap() {
        withAnimation {
            if showAddressBar {
                showAddressBar = false
                isTextFieldFocused = false
            } else {
                showAddressBar = true
                // 사파리는 탭으로 표시해도 키보드는 자동으로 안 띄움 → 포커스는 주지 않음
            }
        }
    }

    // MARK: - URL 정규화
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

// MARK: - 스크롤 오프셋 추적을 위한 PreferenceKey (보조)
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - UITextField 전체 선택 헬퍼 (서드파티 키보드 대응)
private final class FirstResponderHolder { static weak var current: UIResponder? }

private extension UIResponder {
    @objc func captureFirstResponder(_ sender: Any) { FirstResponderHolder.current = self }
}

/// 포커스 직후 약간의 딜레이를 두고 현재 퍼스트 리스폰더가 UITextField면 전체 선택 시도.
/// 딜레이 2회 재시도로 서드파티 키보드/애니메이션 타이밍 편차를 흡수.
private func selectAllInFirstResponderTextField() {
    func attempt(_ after: TimeInterval, markSelected: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            FirstResponderHolder.current = nil
            UIApplication.shared.sendAction(#selector(UIResponder.captureFirstResponder(_:)),
                                            to: nil, from: nil, for: nil)
            if let tf = FirstResponderHolder.current as? UITextField {
                tf.selectAll(nil)
                markSelected()
            }
        }
    }
    attempt(0.06) {
        // 첫 시도 성공
    }
    attempt(0.18) {
        // 두 번째 시도 성공 시 플래그 셋
    }
}