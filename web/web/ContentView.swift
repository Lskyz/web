import SwiftUI
import AVKit

// ✅ ContentView: 메인 웹 브라우저 화면을 구성
struct ContentView: View {

    // 🗂️ 탭 목록 상태 (앱 시작 시 저장된 탭 복원 시도)
    @State private var tabs: [WebTab] = {
        if let data = UserDefaults.standard.data(forKey: "savedTabSnapshots"),
           let snapshots = try? JSONDecoder().decode([WebTabSnapshot].self, from: data) {
            return snapshots.map { WebTab.fromSnapshot($0) }
        } else {
            return []
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

    @State private var inputURL = "https://www.google.com"
    @FocusState private var isTextFieldFocused: Bool
    @State private var textFieldSelectedAll = false
    @State private var enablePIP: Bool = true
    @State private var showHistorySheet = false
    @State private var showTabManager = false

    let tabSnapshotKey = "savedTabSnapshots"

    var body: some View {
        // ✅ 빈 탭 목록이면 초기 탭 하나 생성
        if tabs.isEmpty {
            VStack {
                Text("탭이 없습니다.")
                    .padding()
                Button("새 탭 열기") {
                    let newTab = WebTab(url: URL(string: "https://www.google.com")!)
                    tabs.append(newTab)
                    selectedTabID = newTab.id
                }
                .padding()
            }
        } else if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
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

                // 🌐 웹 콘텐츠
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

                // ⬅️➡️🔄 툴바
                HStack {
                    Button(action: { state.goBack() }) {
                        Image(systemName: "chevron.left").font(.title2)
                    }
                    .disabled(!state.canGoBack)
                    .padding(.horizontal, 8)

                    Button(action: { state.goForward() }) {
                        Image(systemName: "chevron.right").font(.title2)
                    }
                    .disabled(!state.canGoForward)
                    .padding(.horizontal, 8)

                    Button(action: { state.reload() }) {
                        Image(systemName: "arrow.clockwise").font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Button(action: { showHistorySheet = true }) {
                        Image(systemName: "clock.arrow.circlepath").font(.title2)
                    }
                    .padding(.horizontal, 8)

                    Spacer()

                    Button(action: { showTabManager = true }) {
                        Image(systemName: "square.on.square").font(.title2)
                    }
                    .padding(.horizontal, 8)

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
            .onAppear {
                selectedTabID = selected.id
                if let url = state.currentURL {
                    inputURL = url.absoluteString
                }
            }
            .onChange(of: tabs) { newTabs in
                let snapshots = newTabs.compactMap { $0.toSnapshot() }
                if let data = try? JSONEncoder().encode(snapshots) {
                    UserDefaults.standard.set(data, forKey: tabSnapshotKey)
                }
            }
            .onReceive(state.$currentURL) { url in
                if let url = url {
                    inputURL = url.absoluteString
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { tabs[index].showAVPlayer },
                set: { tabs[index].showAVPlayer = $0 }
            )) {
                if let url = tabs[index].playerURL {
                    AVPlayerView(url: url)
                }
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
                        onTabSelected: { selectedState in
                            if let selectedTab = tabs.first(where: { $0.stateModel === selectedState }) {
                                selectedTabID = selectedTab.id
                            }
                        }
                    )
                }
            }
        }
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