import SwiftUI
import AVKit

// ✅ ContentView: 메인 웹 브라우저 화면을 구성
struct ContentView: View {

    // 🗂️ 탭 목록 상태 (앱 시작 시 저장된 탭 복원 시도)
    @State private var tabs: [WebTab] = {
        // UserDefaults에서 저장된 탭 스냅샷 복원
        if let data = UserDefaults.standard.data(forKey: "savedTabSnapshots"),
           let snapshots = try? JSONDecoder().decode([WebTabSnapshot].self, from: data) {
            let restoredTabs = snapshots.map { WebTab.fromSnapshot($0) }
            // 복원된 탭이 없으면 기본 구글 탭 하나 생성
            return restoredTabs.isEmpty ? [WebTab(url: URL(string: "https://www.google.com")!)] : restoredTabs
        } else {
            return [WebTab(url: URL(string: "https://www.google.com")!)]
        }
    }()

    // 🌐 현재 선택된 탭 ID (앱 시작 시 첫 번째 탭의 ID 복원)
    @State private var selectedTabID: UUID = {
        if let data = UserDefaults.standard.data(forKey: "savedTabSnapshots"),
           let snapshots = try? JSONDecoder().decode([WebTabSnapshot].self, from: data),
           let first = snapshots.first {
            return WebTab.fromSnapshot(first).id
        } else {
            return UUID()
        }
    }()

    // 🔠 주소창 텍스트 상태
    @State private var inputURL = "https://www.google.com"

    // 🔍 주소창 포커스 여부
    @FocusState private var isTextFieldFocused: Bool

    // ✅ 전체 선택 중복 방지용 플래그
    @State private var textFieldSelectedAll = false

    // 🖼️ PIP (Picture in Picture) 기능 토글 상태
    @State private var enablePIP: Bool = true

    // 📜 방문기록 시트 표시 여부
    @State private var showHistorySheet = false

    // 🗂️ 탭 관리자 화면 표시 여부
    @State private var showTabManager = false

    // ✅ UserDefaults 키 (탭 저장용)
    let tabSnapshotKey = "savedTabSnapshots"

    var body: some View {
        // ✅ 현재 선택된 탭의 인덱스 찾기
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            let selected = tabs[index]
            let state = selected.stateModel

            VStack(spacing: 0) {
                // 🔗 주소창 및 이동 버튼
                HStack {
                    TextField("URL 또는 검색어", text: $inputURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($isTextFieldFocused)
                        .onTapGesture {
                            // 전체 선택 한번만
                            if !textFieldSelectedAll {
                                DispatchQueue.main.async {
                                    UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                    textFieldSelectedAll = true
                                }
                            }
                        }
                        .onChange(of: isTextFieldFocused) { focused in
                            if !focused {
                                textFieldSelectedAll = false
                            }
                        }
                        .onSubmit {
                            // 엔터 시 입력값을 URL로 이동
                            if let url = fixedURL(from: inputURL) {
                                state.currentURL = url
                            }
                            isTextFieldFocused = false
                        }
                        .overlay(
                            HStack {
                                Spacer()
                                if !inputURL.isEmpty {
                                    Button(action: { inputURL = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                    .padding(.trailing, 8)
                                }
                            }
                        )

                    // "이동" 버튼
                    Button("이동") {
                        if let url = fixedURL(from: inputURL) {
                            state.currentURL = url
                        }
                        isTextFieldFocused = false
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // 🌐 웹 콘텐츠 뷰
                CustomWebView(
                    stateModel: state,
                    playerURL: Binding(
                        get: { tabs[index].playerURL },
                        set: { tabs[index].playerURL = $0 }
                    ),
                    showAVPlayer: Binding(
                        get: { tabs[index].showAVPlayer },
                        set: { tabs[index].showAVPlayer = $0 }
                    )
                )

                // ⬅️➡️🔄 하단 툴바
                HStack {
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                    .disabled(!state.canGoBack)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right").font(.title2)
                    }
                    .disabled(!state.canGoForward)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    Button(action: { state.reload() }) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)

                    // 🕒 방문기록
                    Button(action: {
                        showHistorySheet = true
                    }) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    // 📑 탭 관리자
                    Button(action: {
                        showTabManager = true
                    }) {
                        Image(systemName: "square.on.square")
                            .font(.title2)
                    }
                    .padding(.horizontal, 8)

                    // 🔄 PIP 토글 (숨김 처리됨)
                    Toggle(isOn: $enablePIP) {
                        Image(systemName: "pip.enter")
                    }
                    .labelsHidden()
                    .hidden()
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                .background(Color(UIColor.secondarySystemBackground))
            }
            .ignoresSafeArea(.keyboard)

            // ✅ 앱 화면 진입 시 URL 반영
            .onAppear {
                selectedTabID = selected.id
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                }
            }

            // ✅ 탭 변경 시 저장
            .onChange(of: tabs) { newTabs in
                let snapshots = newTabs.compactMap { $0.toSnapshot() }
                if let data = try? JSONEncoder().encode(snapshots) {
                    UserDefaults.standard.set(data, forKey: tabSnapshotKey)
                }
            }

            // ✅ 현재 URL 바뀔 때 주소창 반영
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }

            // 🎥 AVPlayer 전체화면 뷰
            .fullScreenCover(isPresented: Binding(
                get: { tabs[index].showAVPlayer },
                set: { tabs[index].showAVPlayer = $0 }
            )) {
                if let url = tabs[index].playerURL {
                    AVPlayerView(url: url)
                }
            }

            // 📜 방문기록 시트
            .sheet(isPresented: $showHistorySheet) {
                NavigationView {
                    WebViewStateModel.HistoryPage(state: state)
                }
            }

            // 🗂️ 탭 관리자 화면
            .fullScreenCover(isPresented: $showTabManager) {
                NavigationView {
                    TabManager(
                        tabs: $tabs,
                        initialStateModel: state,
                        onTabSelected: { selectedState in
                            if let selectedTab = tabs.first(where: { $0.stateModel === selectedState }) {
                                selectedTabID = selectedTab.id
                            }
                        }
                    )
                }
            }

        } else {
            // ❗탭이 비어있는 경우 복구
            Text("탭 없음")
                .onAppear {
                    if let first = tabs.first {
                        selectedTabID = first.id
                    }
                }
        }
    }

    // 🔧 문자열을 URL로 변환 또는 검색어로 처리
    private func fixedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // 명확한 http(s) URL인 경우
        if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
            return url
        }

        // 도메인 형식인 경우 자동 보정
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }

        // 일반 검색어 → 구글 검색 쿼리
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}